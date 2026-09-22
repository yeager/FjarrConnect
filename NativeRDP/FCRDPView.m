// Copyright © 2026 FjärrConnect contributors. MIT license.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import "FCRDPView.h"
#include <freerdp/config.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/error.h>
#include <winpr/input.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <stdatomic.h>
#include <stdint.h>

@class FCRDPView;
typedef struct {
    rdpClientContext common;
    __unsafe_unretained FCRDPView *view; // Worker retains the view until context_free.
    CliprdrClientContext *clipboard;
    DispClientContext *display;
    _Atomic(BOOL) displayReady;
    _Atomic(BOOL) clipboardReady;
} FCContext;
typedef void (^FCInput)(FCContext *);
static FCRDPView *FCView(rdpContext *context) { return ((FCContext *)context)->view; }
static BOOL FCPreConnect(freerdp *instance);
static BOOL FCPostConnect(freerdp *instance);
static void FCPostDisconnect(freerdp *instance);
static DWORD FCCertificate(freerdp *, const char *, UINT16, const char *, const char *, const char *, const char *, DWORD);
static DWORD FCChangedCertificate(freerdp *, const char *, UINT16, const char *, const char *, const char *, const char *, const char *, const char *, const char *, DWORD);
static BOOL FCAuthenticate(freerdp *, char **, char **, char **, rdp_auth_reason);
static BOOL FCGatewayMessage(freerdp *, UINT32, BOOL, BOOL, size_t, const WCHAR *);
static SSIZE_T FCRetry(freerdp *instance, const char *what, size_t current, void *data);
static void FCAnnounceClipboard(FCContext *context);

// RDP transfers bitmap clipboard data as a DIB: a BMP file without its 14-byte
// file header. Keep this bounded because clipboard redirection is remote input.
static const NSUInteger FCClipboardImageMaximumBytes = 64 * 1024 * 1024;
static const uint64_t FCClipboardImageMaximumPixels = 32ULL * 1024 * 1024;

static uint16_t FCReadLE16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t FCReadLE32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static void FCWriteLE32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
    bytes[2] = (uint8_t)(value >> 16);
    bytes[3] = (uint8_t)(value >> 24);
}

static NSData *FCDIBFromPasteboard(NSPasteboard *pasteboard) {
    if (![pasteboard availableTypeFromArray:@[NSPasteboardTypeTIFF, NSPasteboardTypePNG]]) return nil;
    NSImage *image = [[NSImage alloc] initWithPasteboard:pasteboard];
    NSData *tiff = image.TIFFRepresentation;
    NSBitmapImageRep *bitmap = tiff ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
    NSData *bmp = [bitmap representationUsingType:NSBitmapImageFileTypeBMP properties:@{}];
    // AppKit produces a normal BMP file. The RDP CF_DIB format omits its header.
    if (bmp.length <= 14 || bmp.length - 14 > FCClipboardImageMaximumBytes) return nil;
    const uint8_t *bytes = bmp.bytes;
    if (bytes[0] != 'B' || bytes[1] != 'M') return nil;
    return [bmp subdataWithRange:NSMakeRange(14, bmp.length - 14)];
}

static NSData *FCBMPFromDIB(NSData *dib) {
    if (!dib || dib.length < 12 || dib.length > FCClipboardImageMaximumBytes) return nil;
    const uint8_t *bytes = dib.bytes;
    const uint32_t headerSize = FCReadLE32(bytes);
    uint64_t pixelOffset = 14;
    uint32_t width = 0, height = 0, bitsPerPixel = 0, compression = 0, colorsUsed = 0;
    if (headerSize == 12) { // BITMAPCOREHEADER
        if (dib.length < 12) return nil;
        width = FCReadLE16(bytes + 4); height = FCReadLE16(bytes + 6);
        bitsPerPixel = FCReadLE16(bytes + 10);
        if (!width || !height || !bitsPerPixel) return nil;
        pixelOffset += headerSize + ((bitsPerPixel <= 8 ? (1ULL << bitsPerPixel) : 0) * 3);
    } else {
        if (headerSize < 40 || headerSize > dib.length) return nil;
        const int32_t signedWidth = (int32_t)FCReadLE32(bytes + 4);
        const int32_t signedHeight = (int32_t)FCReadLE32(bytes + 8);
        if (signedWidth <= 0 || signedHeight == 0 || signedHeight == INT32_MIN) return nil;
        width = (uint32_t)signedWidth;
        height = (uint32_t)(signedHeight < 0 ? -signedHeight : signedHeight);
        bitsPerPixel = FCReadLE16(bytes + 14);
        compression = FCReadLE32(bytes + 16);
        colorsUsed = FCReadLE32(bytes + 32);
        if (!bitsPerPixel) return nil;
        pixelOffset += headerSize;
        // BITMAPINFOHEADER stores bitfield masks after the header; newer DIB
        // headers include them in the header itself.
        if (headerSize == 40 && (compression == 3 || compression == 6))
            pixelOffset += compression == 6 ? 16 : 12;
        const uint64_t paletteEntries = colorsUsed ? colorsUsed : (bitsPerPixel <= 8 ? (1ULL << bitsPerPixel) : 0);
        pixelOffset += paletteEntries * 4;
    }
    if (width > 16384 || height > 16384 || (uint64_t)width * height > FCClipboardImageMaximumPixels ||
        pixelOffset >= dib.length || pixelOffset > UINT32_MAX) return nil;
    const uint64_t fileSize = 14 + dib.length;
    if (fileSize > UINT32_MAX) return nil;
    uint8_t header[14] = { 'B', 'M' };
    FCWriteLE32(header + 2, (uint32_t)fileSize);
    FCWriteLE32(header + 10, (uint32_t)pixelOffset);
    NSMutableData *bmp = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [bmp appendData:dib];
    return bmp;
}

@interface FCRDPView : NSView <NSTextInputClient>
@property(nonatomic, readonly) NSDictionary<NSString *, NSString *> *translations;
@property(atomic) int connectionStatus;
@property(atomic) int connectionStage;
@property(atomic) uint32_t errorCode;
@property(atomic) BOOL cancelled;
@property(atomic) BOOL clipboardActive;
@property(atomic, copy) NSData *clipboardText;
@property(atomic, copy) NSData *clipboardImage;
@property(atomic) uint32_t clipboardRequestedFormat;
@property(atomic) BOOL needsClipboardAnnouncement;
@property(atomic) BOOL clipboardAllowed;
@property(atomic) BOOL unicodeSupported;
@property(atomic) uint32_t requestedWidth;
@property(atomic) uint32_t requestedHeight;
@property(nonatomic) NSCursor *remoteCursor;
- (instancetype)initWithArguments:(NSString *)arguments translations:(NSDictionary *)translations;
- (void)start;
- (void)stop;
- (void)setSessionActive:(BOOL)active;
- (void)enqueue:(FCInput)input;
- (void)publishFrame:(rdpGdi *)gdi;
- (NSData *)DIBFromPasteboard:(NSPasteboard *)pasteboard;
- (void)receiveClipboardDIB:(NSData *)dib;
- (void)writeClipboardDIB:(NSData *)dib;
- (NSString *)text:(NSString *)key;
- (DWORD)certificateForHost:(NSString *)host port:(UINT16)port commonName:(NSString *)name subject:(NSString *)subject issuer:(NSString *)issuer fingerprint:(NSString *)fingerprint oldFingerprint:(NSString *)oldFingerprint flags:(DWORD)flags;
@end

@implementation FCRDPView {
    FCContext *_context;
    NSLock *_lock;
    NSMutableArray<FCInput> *_input;
    NSString *_arguments;
    NSImage *_frame;
    NSImage *_pendingFrame;
    BOOL _frameScheduled;
    NSTrackingArea *_tracking;
    NSTimer *_clipboardTimer;
    NSInteger _clipboardChange;
    BOOL _sessionActive;
    NSMutableSet<NSNumber *> *_pressedKeys;
    NSMutableSet<NSNumber *> *_mouseButtons;
    NSMutableAttributedString *_markedText;
    NSTimeInterval _lastResize;
    uint32_t _lastRequestedWidth, _lastRequestedHeight;
    NSAlert *_certificateAlert;
}

- (instancetype)initWithArguments:(NSString *)arguments translations:(NSDictionary *)translations {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 1280, 800)])) {
        _arguments = [arguments copy];
        _translations = [translations copy];
        _lock = [NSLock new];
        _input = [NSMutableArray new];
        _pressedKeys = [NSMutableSet new];
        _mouseButtons = [NSMutableSet new];
        _markedText = [NSMutableAttributedString new];
        _remoteCursor = NSCursor.arrowCursor;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.requestedWidth = 1280;
        self.requestedHeight = 800;
        self.wantsLayer = YES;
    }
    return self;
}
- (NSString *)text:(NSString *)key { return self.translations[key] ?: key; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.blackColor setFill]; NSRectFill(dirtyRect);
    if (_frame) [_frame drawInRect:[self imageRect] fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
}
- (NSRect)imageRect {
    if (!_frame || _frame.size.width == 0 || _frame.size.height == 0) return self.bounds;
    CGFloat scale = MIN(self.bounds.size.width / _frame.size.width, self.bounds.size.height / _frame.size.height);
    NSSize size = NSMakeSize(_frame.size.width * scale, _frame.size.height * scale);
    return NSMakeRect((self.bounds.size.width - size.width) / 2, (self.bounds.size.height - size.height) / 2, size.width, size.height);
}
- (void)publishFrame:(rdpGdi *)gdi {
    if (!gdi || !gdi->primary_buffer || gdi->width <= 0 || gdi->height <= 0 ||
        gdi->width > 8192 || gdi->height > 8192 || (uint64_t)gdi->stride * gdi->height > 128 * 1024 * 1024) return;
    // Own the pixels before the decoder starts writing the next frame. Coalesce
    // queued frames so a slow main thread cannot accumulate desktop snapshots.
    NSData *pixels = [NSData dataWithBytes:gdi->primary_buffer length:(NSUInteger)gdi->stride * gdi->height];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(gdi->width, gdi->height, 8, 32, gdi->stride, colors,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, NULL, false, kCGRenderingIntentDefault);
    NSImage *frame = image ? [[NSImage alloc] initWithCGImage:image size:NSMakeSize(gdi->width, gdi->height)] : nil;
    if (image) CGImageRelease(image);
    CGColorSpaceRelease(colors); CGDataProviderRelease(provider);
    if (!frame) return;
    [_lock lock]; _pendingFrame = frame;
    BOOL schedule = !_frameScheduled; _frameScheduled = YES; [_lock unlock];
    if (schedule) dispatch_async(dispatch_get_main_queue(), ^{
        [self->_lock lock]; self->_frame = self->_pendingFrame; self->_pendingFrame = nil;
        self->_frameScheduled = NO; [self->_lock unlock]; self.needsDisplay = YES;
    });
}
- (void)start {
    if (self.connectionStatus != 0) return;
    self.connectionStatus = 1;
    _clipboardChange = NSPasteboard.generalPasteboard.changeCount;
    __weak FCRDPView *weakSelf = self;
    _clipboardTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *timer) { [weakSelf clipboardTick]; }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool { [self runConnection]; } });
}
- (void)stop {
    self.cancelled = YES;
    self.clipboardActive = NO;
    self.clipboardText = nil;
    self.clipboardImage = nil;
    [_clipboardTimer invalidate]; _clipboardTimer = nil;
    if (_certificateAlert) [NSApp abortModal];
    [_lock lock];
    if (_context) freerdp_abort_connect_context(&_context->common.context);
    [_lock unlock];
}
- (void)setSessionActive:(BOOL)active {
    if (_sessionActive && !active) [self releaseInput];
    _sessionActive = active;
    self.clipboardActive = active && NSApp.isActive && self.window.isKeyWindow && self.clipboardAllowed;
    // Changing tabs never uploads a clipboard copied in another session.
    _clipboardChange = NSPasteboard.generalPasteboard.changeCount;
    if (!active) { self.clipboardText = nil; self.clipboardImage = nil; }
}
- (void)clipboardTick {
    BOOL active = _sessionActive && NSApp.isActive && self.window.isKeyWindow && self.clipboardAllowed;
    if (self.clipboardActive != active) {
        self.clipboardActive = active;
        _clipboardChange = NSPasteboard.generalPasteboard.changeCount;
        if (!active) { self.clipboardText = nil; self.clipboardImage = nil; [self releaseInput]; }
    }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    if (!active || self.connectionStatus != 2 || pasteboard.changeCount == _clipboardChange) return;
    _clipboardChange = pasteboard.changeCount;
    NSData *image = [self DIBFromPasteboard:pasteboard];
    self.clipboardImage = image;
    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    if (text.length > 512 * 1024) { self.clipboardText = nil; self.needsClipboardAnnouncement = image != nil; return; }
    text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
    NSMutableData *data = [[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
    if (!data || data.length > 1024 * 1024) { self.clipboardText = nil; self.needsClipboardAnnouncement = image != nil; return; }
    const uint16_t nul = 0; [data appendBytes:&nul length:2];
    self.clipboardText = data;
    self.needsClipboardAnnouncement = YES;
}
- (void)receiveClipboard:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.clipboardActive || !self->_sessionActive || !NSApp.isActive || !self.window.isKeyWindow || self.cancelled) return;
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents]; [pasteboard setString:text forType:NSPasteboardTypeString];
        self->_clipboardChange = pasteboard.changeCount;
    });
}
- (void)receiveClipboardDIB:(NSData *)dib {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.clipboardActive || !self->_sessionActive || !NSApp.isActive || !self.window.isKeyWindow || self.cancelled) return;
        [self writeClipboardDIB:dib];
    });
}
- (NSData *)DIBFromPasteboard:(NSPasteboard *)pasteboard { return FCDIBFromPasteboard(pasteboard); }
- (void)writeClipboardDIB:(NSData *)dib {
    NSData *bmp = FCBMPFromDIB(dib);
    NSImage *image = bmp ? [[NSImage alloc] initWithData:bmp] : nil;
    NSData *tiff = image.TIFFRepresentation;
    if (!tiff.length || tiff.length > FCClipboardImageMaximumBytes) return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setData:tiff forType:NSPasteboardTypeTIFF];
    _clipboardChange = pasteboard.changeCount;
}
- (void)enqueue:(FCInput)input {
    if (self.cancelled || self.connectionStatus != 2) return;
    [_lock lock];
    // Inputs are local events. A bounded queue also protects a stalled connection.
    if (_input.count < 4096) [_input addObject:[input copy]];
    [_lock unlock];
}
- (void)runConnection {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ WLog_SetLogLevel(WLog_GetRoot(), WLOG_OFF); });
    RDP_CLIENT_ENTRY_POINTS entry = {0};
    entry.Version = RDP_CLIENT_INTERFACE_VERSION; entry.Size = sizeof(entry);
    entry.ContextSize = sizeof(FCContext);
    rdpContext *base = freerdp_client_context_new(&entry);
    if (!base) { self.errorCode = 0xFFFFFFFF; self.connectionStatus = 3; return; }
    FCContext *ctx = (FCContext *)base; ctx->view = self;
    freerdp *instance = base->instance;
    instance->PreConnect = FCPreConnect; instance->PostConnect = FCPostConnect; instance->PostDisconnect = FCPostDisconnect;
    instance->VerifyCertificateEx = FCCertificate; instance->VerifyChangedCertificateEx = FCChangedCertificate;
    instance->AuthenticateEx = FCAuthenticate; instance->PresentGatewayMessage = FCGatewayMessage; instance->RetryDialog = FCRetry;
    NSArray<NSString *> *lines = [_arguments componentsSeparatedByString:@"\n"];
    char **argv = calloc(lines.count + 2, sizeof(char *)); int argc = 0;
    argv[argc++] = strdup("FjarrConnect");
    for (NSString *line in lines) if (line.length) argv[argc++] = strdup(line.UTF8String);
    int parsed = freerdp_client_settings_parse_command_line(base->settings, argc, argv, FALSE);
    for (int i = 0; i < argc; i++) { if (argv[i]) { memset_s(argv[i], strlen(argv[i]), 0, strlen(argv[i])); free(argv[i]); } }
    free(argv); _arguments = nil;
    self.clipboardAllowed = freerdp_settings_get_bool(base->settings, FreeRDP_RedirectClipboard);
    // The callback receives a SHA-256 fingerprint; never show an untranslated CLI prompt.
    freerdp_settings_set_bool(base->settings, FreeRDP_CertificateCallbackPreferPEM, FALSE);
    freerdp_settings_set_bool(base->settings, FreeRDP_AutoReconnectionEnabled, FALSE);
    freerdp_settings_set_bool(base->settings, FreeRDP_UnicodeInput, TRUE);
    // Keep FreeRDP's network autodetection enabled: Windows sends RTT requests
    // during desktop activation and the core must be able to answer them.
    [_lock lock]; _context = ctx; BOOL cancelled = self.cancelled; [_lock unlock];
    BOOL connected = parsed == 0 && !cancelled && freerdp_connect(instance);
    if (connected) {
        self.connectionStatus = 2;
        while (!self.cancelled && !freerdp_shall_disconnect_context(base)) {
            @autoreleasepool {
                [_lock lock]; NSArray<FCInput> *inputs = [_input copy]; [_input removeAllObjects]; [_lock unlock];
                if (self.needsClipboardAnnouncement && ctx->clipboardReady) { self.needsClipboardAnnouncement = NO; FCAnnounceClipboard(ctx); }
                for (FCInput input in inputs) input(ctx);
                [self resizeRemote:ctx];
                HANDLE handles[MAXIMUM_WAIT_OBJECTS];
                DWORD count = freerdp_get_event_handles(base, handles, MAXIMUM_WAIT_OBJECTS);
                if (!count || WaitForMultipleObjects(count, handles, FALSE, 16) == WAIT_FAILED || !freerdp_check_event_handles(base)) break;
            }
        }
    }
    self.errorCode = self.cancelled ? 0 : (parsed == 0 ? freerdp_get_last_error(base) : 0xFFFFFFFF);
    if (!connected && !self.cancelled && self.errorCode == 0) self.errorCode = FREERDP_ERROR_CONNECT_FAILED;
    freerdp_disconnect(instance);
    [_lock lock]; _context = NULL; [_input removeAllObjects]; [_lock unlock];
    freerdp_client_context_free(base);
    self.clipboardText = nil; self.clipboardImage = nil; self.connectionStatus = 3;
    dispatch_async(dispatch_get_main_queue(), ^{ [self->_clipboardTimer invalidate]; self->_clipboardTimer = nil; });
}
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    self.requestedWidth = (uint32_t)MAX(200, MIN(4096, floor(newSize.width / 2) * 2));
    self.requestedHeight = (uint32_t)MAX(200, MIN(4096, floor(newSize.height)));
}
- (void)resizeRemote:(FCContext *)ctx {
    if (!ctx->display || !ctx->displayReady || CFAbsoluteTimeGetCurrent() - _lastResize < 0.3) return;
    uint32_t width = self.requestedWidth, height = self.requestedHeight;
    rdpSettings *settings = ctx->common.context.settings;
    if (width == _lastRequestedWidth && height == _lastRequestedHeight) return;
    if (width == freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth) && height == freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight)) return;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = {0};
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY; layout.Width = width; layout.Height = height;
    layout.PhysicalWidth = MAX(10, width * 254 / 960); layout.PhysicalHeight = MAX(10, height * 254 / 960);
    layout.DesktopScaleFactor = 100; layout.DeviceScaleFactor = 100;
    ctx->display->SendMonitorLayout(ctx->display, 1, &layout);
    _lastRequestedWidth = width; _lastRequestedHeight = height; _lastResize = CFAbsoluteTimeGetCurrent();
}
- (void)updateTrackingAreas {
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking]; [super updateTrackingAreas];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:self.remoteCursor ?: NSCursor.arrowCursor]; }
- (void)mouseEntered:(NSEvent *)event { [self.remoteCursor set]; }
- (void)mouseExited:(NSEvent *)event { [NSCursor.arrowCursor set]; }
- (void)mouse:(NSEvent *)event flags:(UINT16)flags {
    NSRect rect = [self imageRect]; NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (rect.size.width <= 0 || rect.size.height <= 0 || !_frame) return;
    UINT16 x = (UINT16)MAX(0, MIN(_frame.size.width - 1, (point.x - rect.origin.x) * _frame.size.width / rect.size.width));
    UINT16 y = (UINT16)MAX(0, MIN(_frame.size.height - 1, (point.y - rect.origin.y) * _frame.size.height / rect.size.height));
    [self enqueue:^(FCContext *ctx) { freerdp_input_send_mouse_event(ctx->common.context.input, flags, x, y); }];
}
- (void)mouseMoved:(NSEvent *)event { [self mouse:event flags:PTR_FLAGS_MOVE]; }
- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)otherMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)button:(NSEvent *)event down:(BOOL)down button:(UINT16)button {
    [self.window makeFirstResponder:self];
    if (down) [_mouseButtons addObject:@(button)]; else [_mouseButtons removeObject:@(button)];
    [self mouse:event flags:button | (down ? PTR_FLAGS_DOWN : 0)];
}
- (void)mouseDown:(NSEvent *)event { [self button:event down:YES button:PTR_FLAGS_BUTTON1]; }
- (void)mouseUp:(NSEvent *)event { [self button:event down:NO button:PTR_FLAGS_BUTTON1]; }
- (void)rightMouseDown:(NSEvent *)event { [self button:event down:YES button:PTR_FLAGS_BUTTON2]; }
- (void)rightMouseUp:(NSEvent *)event { [self button:event down:NO button:PTR_FLAGS_BUTTON2]; }
- (void)otherMouseDown:(NSEvent *)event { [self button:event down:YES button:PTR_FLAGS_BUTTON3]; }
- (void)otherMouseUp:(NSEvent *)event { [self button:event down:NO button:PTR_FLAGS_BUTTON3]; }
- (void)scrollWheel:(NSEvent *)event {
    for (int axis = 0; axis < 2; axis++) {
        CGFloat delta = axis ? event.scrollingDeltaX : event.scrollingDeltaY;
        if (delta == 0) continue;
        int rotation = MAX(-255, MIN(255, (int)(delta * (event.hasPreciseScrollingDeltas ? 4 : 120))));
        if (!rotation) rotation = delta > 0 ? 1 : -1;
        UINT16 flags = (axis ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL) | (rotation < 0 ? PTR_FLAGS_WHEEL_NEGATIVE : 0) | ((UINT16)rotation & 0x1FF);
        [self enqueue:^(FCContext *ctx) { freerdp_input_send_mouse_event(ctx->common.context.input, flags, 0, 0); }];
    }
}
- (DWORD)scancode:(unsigned short)key {
    DWORD vk = GetVirtualKeyCodeFromKeycode(key, WINPR_KEYCODE_TYPE_APPLE);
    return GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
}
- (void)sendKey:(unsigned short)key down:(BOOL)down {
    DWORD code = [self scancode:key]; if (!code) return;
    if (down) [_pressedKeys addObject:@(key)]; else [_pressedKeys removeObject:@(key)];
    [self enqueue:^(FCContext *ctx) { freerdp_input_send_keyboard_event_ex(ctx->common.context.input, down, FALSE, code); }];
}
- (void)keyDown:(NSEvent *)event {
    if (!self.unicodeSupported || (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand))) [self sendKey:event.keyCode down:YES];
    else [self interpretKeyEvents:@[event]];
}
- (void)keyUp:(NSEvent *)event { if ([_pressedKeys containsObject:@(event.keyCode)]) [self sendKey:event.keyCode down:NO]; }
- (void)sendControlShortcut:(unsigned short)key {
    [self releaseInput];
    DWORD code = [self scancode:key], control = [self scancode:59];
    [self enqueue:^(FCContext *ctx) {
        rdpInput *input = ctx->common.context.input;
        freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, control);
        freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, code);
        freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, code);
        freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, control);
    }];
}
// Standard macOS Edit menu shortcuts operate on the remote application.
- (void)copy:(id)sender { [self sendControlShortcut:8]; }
- (void)cut:(id)sender { [self sendControlShortcut:7]; }
- (void)paste:(id)sender { [self clipboardTick]; [self sendControlShortcut:9]; }
- (void)selectAll:(id)sender { [self sendControlShortcut:0]; }
- (void)flagsChanged:(NSEvent *)event {
    NSEventModifierFlags mask = 0;
    switch (event.keyCode) {
        case 56: case 60: mask = NSEventModifierFlagShift; break;
        case 59: case 62: mask = NSEventModifierFlagControl; break;
        case 58: case 61: mask = NSEventModifierFlagOption; break;
        case 54: case 55: mask = NSEventModifierFlagCommand; break;
        case 57: { [self enqueue:^(FCContext *ctx) { freerdp_input_send_synchronize_event(ctx->common.context.input, (event.modifierFlags & NSEventModifierFlagCapsLock) ? KBD_SYNC_CAPS_LOCK : 0); }]; return; }
        default: return;
    }
    // Device-dependent bits distinguish releasing one of two held modifiers.
    BOOL down = (event.modifierFlags & mask) && ![_pressedKeys containsObject:@(event.keyCode)];
    [self sendKey:event.keyCode down:down];
}
- (void)releaseInput {
    for (NSNumber *key in [_pressedKeys copy]) [self sendKey:key.unsignedShortValue down:NO];
    for (NSNumber *button in _mouseButtons) [self enqueue:^(FCContext *ctx) { freerdp_input_send_mouse_event(ctx->common.context.input, button.unsignedShortValue, 0, 0); }];
    [_mouseButtons removeAllObjects];
}
- (BOOL)resignFirstResponder { [self releaseInput]; return [super resignFirstResponder]; }
- (void)insertText:(id)string replacementRange:(NSRange)range {
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    [self unmarkText];
    if (text.length > 1024 * 1024) return;
    [self enqueue:^(FCContext *ctx) {
        for (NSUInteger i = 0; i < text.length; i++) {
            unichar ch = [text characterAtIndex:i];
            freerdp_input_send_unicode_keyboard_event(ctx->common.context.input, KBD_FLAGS_DOWN, ch);
            freerdp_input_send_unicode_keyboard_event(ctx->common.context.input, KBD_FLAGS_RELEASE, ch);
        }
    }];
}
- (void)doCommandBySelector:(SEL)selector {
    NSEvent *event = NSApp.currentEvent;
    if (event.type == NSEventTypeKeyDown) [self sendKey:event.keyCode down:YES];
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selected replacementRange:(NSRange)replacement {
    _markedText = [string isKindOfClass:NSAttributedString.class] ? [string mutableCopy] : [[NSMutableAttributedString alloc] initWithString:string];
}
- (void)unmarkText { [_markedText.mutableString setString:@""]; }
- (BOOL)hasMarkedText { return _markedText.length > 0; }
- (NSRange)markedRange { return self.hasMarkedText ? NSMakeRange(0, _markedText.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(0, 0); }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual { if (actual) *actual = NSMakeRange(NSNotFound, 0); return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
    if (actual) *actual = range;
    return [self.window convertRectToScreen:[self convertRect:NSMakeRect(8, self.bounds.size.height - 24, 1, 20) toView:nil]];
}
- (DWORD)certificateForHost:(NSString *)host port:(UINT16)port commonName:(NSString *)name subject:(NSString *)subject issuer:(NSString *)issuer fingerprint:(NSString *)fingerprint oldFingerprint:(NSString *)oldFingerprint flags:(DWORD)flags {
    __block DWORD result = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        NSAlert *alert = [NSAlert new]; self->_certificateAlert = alert;
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = [self text:oldFingerprint ? @"rdp.cert.changed.title" : @"rdp.cert.title"];
        NSMutableArray *details = [NSMutableArray arrayWithObjects:
            [self text:oldFingerprint ? @"rdp.cert.changed.message" : @"rdp.cert.message"],
            [NSString stringWithFormat:@"%@: %@:%u", [self text:@"field.host"], host, port], nil];
        if (flags & VERIFY_CERT_FLAG_MISMATCH) [details addObject:[self text:@"rdp.cert.mismatch"]];
        [details addObjectsFromArray:@[
            [NSString stringWithFormat:@"%@: %@", [self text:@"rdp.cert.name"], name],
            [NSString stringWithFormat:@"%@: %@", [self text:@"rdp.cert.subject"], subject],
            [NSString stringWithFormat:@"%@: %@", [self text:@"rdp.cert.issuer"], issuer],
            [NSString stringWithFormat:@"%@: %@", [self text:@"rdp.cert.fingerprint"], fingerprint]]];
        if (oldFingerprint) [details addObject:[NSString stringWithFormat:@"%@: %@", [self text:@"rdp.cert.previous"], oldFingerprint]];
        alert.informativeText = [details componentsJoinedByString:@"\n\n"];
        [alert addButtonWithTitle:[self text:@"action.cancel"]];
        [alert addButtonWithTitle:[self text:@"rdp.cert.once"]];
        [alert addButtonWithTitle:[self text:@"rdp.cert.trust"]];
        NSModalResponse response = [alert runModal]; self->_certificateAlert = nil;
        if (!self.cancelled) result = response == NSAlertSecondButtonReturn ? 2 : (response == NSAlertThirdButtonReturn ? 1 : 0);
    });
    return result;
}
@end

static NSString *FCString(const char *text) {
    if (!text) return @"";
    // Certificate subject fields are untrusted server input, not a format string.
    NSString *value = [[NSString alloc] initWithBytes:text length:strnlen(text, 16384) encoding:NSUTF8StringEncoding] ?: @"";
    return [[value componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
}
static DWORD FCCertificate(freerdp *instance, const char *host, UINT16 port, const char *name, const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    if (flags & VERIFY_CERT_FLAG_FP_IS_PEM) return 0;
    return [FCView(instance->context) certificateForHost:FCString(host) port:port commonName:FCString(name) subject:FCString(subject) issuer:FCString(issuer) fingerprint:FCString(fingerprint) oldFingerprint:nil flags:flags];
}
static DWORD FCChangedCertificate(freerdp *instance, const char *host, UINT16 port, const char *name, const char *subject, const char *issuer, const char *fingerprint, const char *oldSubject, const char *oldIssuer, const char *oldFingerprint, DWORD flags) {
    if (flags & VERIFY_CERT_FLAG_FP_IS_PEM) return 0;
    return [FCView(instance->context) certificateForHost:FCString(host) port:port commonName:FCString(name) subject:FCString(subject) issuer:FCString(issuer) fingerprint:FCString(fingerprint) oldFingerprint:FCString(oldFingerprint) flags:flags];
}
static BOOL FCAuthenticate(freerdp *instance, char **username, char **password, char **domain, rdp_auth_reason reason) {
    // Credentials are collected by the app's localized SecureField before connecting.
    // Never fall back to stdin/English prompts or retry an incorrect password.
    return username && *username && password && *password && !FCView(instance->context).cancelled;
}
static SSIZE_T FCRetry(freerdp *instance, const char *what, size_t current, void *data) { return -1; }
static BOOL FCGatewayMessage(freerdp *instance, UINT32 type, BOOL mandatory, BOOL consent, size_t length, const WCHAR *message) {
    if (!message || length > 32768) return FALSE;
    FCRDPView *view = FCView(instance->context); __block BOOL accepted = NO;
    NSString *text = [[NSString alloc] initWithCharacters:(const unichar *)message length:length];
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (view.cancelled) return;
        NSAlert *alert = [NSAlert new]; alert.messageText = [view text:@"rdp.gateway.message"];
        alert.informativeText = text; [alert addButtonWithTitle:[view text:@"action.cancel"]];
        [alert addButtonWithTitle:[view text:@"action.connect"]]; accepted = [alert runModal] == NSAlertSecondButtonReturn;
    }); return accepted && !view.cancelled;
}
static BOOL FCBeginPaint(rdpContext *context) { context->gdi->primary->hdc->hwnd->invalid->null = TRUE; return TRUE; }
static BOOL FCEndPaint(rdpContext *context) {
    if (!context->gdi->primary->hdc->hwnd->invalid->null) [FCView(context) publishFrame:context->gdi]; return TRUE;
}
static BOOL FCResize(rdpContext *context) {
    UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!width || !height || width > 8192 || height > 8192 || (uint64_t)width * height > 32 * 1024 * 1024) return FALSE;
    return gdi_resize(context->gdi, width, height);
}
static BOOL FCPointerNew(rdpContext *context, rdpPointer *pointer) { return pointer->width <= 384 && pointer->height <= 384; }
static void FCPointerFree(rdpContext *context, rdpPointer *pointer) {}
static BOOL FCPointerSet(rdpContext *context, rdpPointer *pointer) {
    if (!pointer->width || !pointer->height || pointer->width > 384 || pointer->height > 384) return FALSE;
    NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)pointer->width * pointer->height * 4];
    if (!freerdp_image_copy_from_pointer_data(pixels.mutableBytes, PIXEL_FORMAT_BGRA32, pointer->width * 4, 0, 0, pointer->width, pointer->height,
        pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData, pointer->lengthAndMask, pointer->xorBpp, &context->gdi->palette)) return FALSE;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(pointer->width, pointer->height, 8, 32, pointer->width * 4, colors,
        kCGBitmapByteOrder32Little | kCGImageAlphaFirst, provider, NULL, false, kCGRenderingIntentDefault);
    NSImage *cursorImage = image ? [[NSImage alloc] initWithCGImage:image size:NSMakeSize(pointer->width, pointer->height)] : nil;
    if (image) CGImageRelease(image); CGColorSpaceRelease(colors); CGDataProviderRelease(provider);
    if (!cursorImage) return FALSE;
    NSPoint hotSpot = NSMakePoint(MIN(pointer->xPos, pointer->width - 1), MIN(pointer->yPos, pointer->height - 1));
    FCRDPView *view = FCView(context);
    dispatch_async(dispatch_get_main_queue(), ^{ view.remoteCursor = [[NSCursor alloc] initWithImage:cursorImage hotSpot:hotSpot]; [view.window invalidateCursorRectsForView:view]; });
    return TRUE;
}
static BOOL FCPointerDefault(rdpContext *context) {
    FCRDPView *view = FCView(context); dispatch_async(dispatch_get_main_queue(), ^{ view.remoteCursor = NSCursor.arrowCursor; [view.window invalidateCursorRectsForView:view]; }); return TRUE;
}
static BOOL FCPointerNull(rdpContext *context) {
    FCRDPView *view = FCView(context); dispatch_async(dispatch_get_main_queue(), ^{ view.remoteCursor = [[NSCursor alloc] initWithImage:[[NSImage alloc] initWithSize:NSMakeSize(1,1)] hotSpot:NSZeroPoint]; [view.window invalidateCursorRectsForView:view]; }); return TRUE;
}
static UINT FCClipCapabilities(CliprdrClientContext *clip, const CLIPRDR_CAPABILITIES *caps) { return CHANNEL_RC_OK; }
static UINT FCClipReady(CliprdrClientContext *clip, const CLIPRDR_MONITOR_READY *ready) {
    FCContext *ctx = clip->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = {CB_CAPSTYPE_GENERAL, CB_CAPSTYPE_GENERAL_LEN, CB_CAPS_VERSION_2, CB_USE_LONG_FORMAT_NAMES};
    CLIPRDR_CAPABILITIES caps = {0}; caps.cCapabilitiesSets = 1; caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT result = clip->ClientCapabilities(clip, &caps); ctx->clipboardReady = TRUE;
    FCAnnounceClipboard(ctx); return result;
}
static void FCAnnounceClipboard(FCContext *ctx) {
    if (!ctx->clipboard) return;
    CLIPRDR_FORMAT formats[2] = { {CF_DIB, NULL}, {CF_UNICODETEXT, NULL} };
    CLIPRDR_FORMAT_LIST list = {0};
    if (ctx->view.clipboardActive) {
        // Keep DIB first when both formats are available, which lets Windows
        // paste a copied screenshot as an image instead of choosing its text.
        if (ctx->view.clipboardImage && ctx->view.clipboardText) {
            list.formats = formats;
            list.numFormats = 2;
        } else if (ctx->view.clipboardImage) {
            list.formats = &formats[0];
            list.numFormats = 1;
        } else if (ctx->view.clipboardText) {
            list.formats = &formats[1];
            list.numFormats = 1;
        }
    }
    ctx->clipboard->ClientFormatList(ctx->clipboard, &list);
}
static UINT FCClipList(CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST *list) {
    FCContext *ctx = clip->custom;
    CLIPRDR_FORMAT_LIST_RESPONSE response = {0}; response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = clip->ClientFormatListResponse(clip, &response);
    if (rc || !ctx->view.clipboardActive) return rc;
    UINT32 format = 0;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        const UINT32 candidate = list->formats[i].formatId;
        if (candidate == CF_DIBV5) { format = candidate; break; }
        if (candidate == CF_DIB) format = candidate;
        else if (!format && candidate == CF_UNICODETEXT) format = candidate;
    }
    if (format) {
        CLIPRDR_FORMAT_DATA_REQUEST request = {0}; request.requestedFormatId = format;
        ctx->view.clipboardRequestedFormat = format;
        return clip->ClientFormatDataRequest(clip, &request);
    }
    return CHANNEL_RC_OK;
}
static UINT FCClipListResponse(CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST_RESPONSE *response) { return CHANNEL_RC_OK; }
static UINT FCClipRequest(CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    FCContext *ctx = clip->custom;
    NSData *data = nil;
    if (ctx->view.clipboardActive) {
        if (request->requestedFormatId == CF_DIB) data = ctx->view.clipboardImage;
        else if (request->requestedFormatId == CF_UNICODETEXT) data = ctx->view.clipboardText;
    }
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0}; response.common.msgFlags = CB_RESPONSE_FAIL;
    const NSUInteger maximum = request->requestedFormatId == CF_DIB ? FCClipboardImageMaximumBytes : 1024 * 1024 + 2;
    if (data && data.length <= maximum) {
        response.common.msgFlags = CB_RESPONSE_OK; response.common.dataLen = (UINT32)data.length; response.requestedFormatData = data.bytes;
    }
    return clip->ClientFormatDataResponse(clip, &response);
}
static UINT FCClipResponse(CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    FCContext *ctx = clip->custom; UINT32 length = response->common.dataLen;
    if (!ctx->view.clipboardActive || !(response->common.msgFlags & CB_RESPONSE_OK) || !response->requestedFormatData) return CHANNEL_RC_OK;
    const UINT32 format = ctx->view.clipboardRequestedFormat;
    if ((format == CF_DIB || format == CF_DIBV5) && length && length <= FCClipboardImageMaximumBytes) {
        [ctx->view receiveClipboardDIB:[NSData dataWithBytes:response->requestedFormatData length:length]];
        return CHANNEL_RC_OK;
    }
    if (format != CF_UNICODETEXT || length < 2 || length > 1024 * 1024 + 2 || length % 2) return CHANNEL_RC_OK;
    const BYTE *bytes = response->requestedFormatData;
    if (bytes[length-1] != 0 || bytes[length-2] != 0) return CHANNEL_RC_OK;
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length-2 encoding:NSUTF16LittleEndianStringEncoding];
    if (text) [ctx->view receiveClipboard:[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]];
    return CHANNEL_RC_OK;
}
static UINT FCDisplayCaps(DispClientContext *disp, UINT32 count, UINT32 a, UINT32 b) { ((FCContext *)disp->custom)->displayReady = count > 0; return CHANNEL_RC_OK; }
static void FCChannelConnected(void *context, const ChannelConnectedEventArgs *event) {
    FCContext *ctx = context;
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *clip = event->pInterface; ctx->clipboard = clip; clip->custom = ctx;
        clip->ServerCapabilities = FCClipCapabilities; clip->MonitorReady = FCClipReady;
        clip->ServerFormatList = FCClipList; clip->ServerFormatListResponse = FCClipListResponse;
        clip->ServerFormatDataRequest = FCClipRequest; clip->ServerFormatDataResponse = FCClipResponse;
    } else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        ctx->display = event->pInterface; ctx->display->custom = ctx; ctx->display->DisplayControlCaps = FCDisplayCaps;
    } else freerdp_client_OnChannelConnectedEventHandler(&ctx->common, event);
}
static void FCChannelDisconnected(void *context, const ChannelDisconnectedEventArgs *event) {
    FCContext *ctx = context;
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) { ctx->clipboard = NULL; ctx->clipboardReady = FALSE; }
    else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) { ctx->display = NULL; ctx->displayReady = FALSE; }
    else freerdp_client_OnChannelDisconnectedEventHandler(&ctx->common, event);
}
static void FCStateChanged(void *context, const StateChangedEventArgs *event) {
    FCRDPView *view = FCView(context);
    view.connectionStage = MAX(view.connectionStage, event->newState);
}
static BOOL FCPreConnect(freerdp *instance) {
    if (PubSub_SubscribeStateChanged(instance->context->pubSub, FCStateChanged) < 0) return FALSE;
    return PubSub_SubscribeChannelConnected(instance->context->pubSub, FCChannelConnected) >= 0 &&
           PubSub_SubscribeChannelDisconnected(instance->context->pubSub, FCChannelDisconnected) >= 0;
}
static BOOL FCPostConnect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;
    rdpContext *ctx = instance->context;
    FCView(ctx).unicodeSupported = freerdp_settings_get_bool(ctx->settings, FreeRDP_UnicodeInput);
    ctx->update->BeginPaint = FCBeginPaint; ctx->update->EndPaint = FCEndPaint; ctx->update->DesktopResize = FCResize;
    rdpPointer pointer = {0}; pointer.size = sizeof(pointer); pointer.New = FCPointerNew; pointer.Free = FCPointerFree;
    pointer.Set = FCPointerSet; pointer.SetNull = FCPointerNull; pointer.SetDefault = FCPointerDefault;
    graphics_register_pointer(ctx->graphics, &pointer); return TRUE;
}
static void FCPostDisconnect(freerdp *instance) {
    PubSub_UnsubscribeStateChanged(instance->context->pubSub, FCStateChanged);
    PubSub_UnsubscribeChannelConnected(instance->context->pubSub, FCChannelConnected);
    PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, FCChannelDisconnected);
    gdi_free(instance);
}
uint32_t fc_rdp_abi(void) { return 1; }
void *fc_rdp_create(const char *arguments, const char *translations) {
    if (!arguments || !translations || !NSThread.isMainThread) return NULL;
    NSData *json = [NSData dataWithBytes:translations length:strlen(translations)];
    id strings = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![strings isKindOfClass:NSDictionary.class]) return NULL;
    FCRDPView *view = [[FCRDPView alloc] initWithArguments:[NSString stringWithUTF8String:arguments] translations:strings];
    return (__bridge_retained void *)view;
}
void fc_rdp_start(void *view) { [(__bridge FCRDPView *)view start]; }
void fc_rdp_stop(void *view) { [(__bridge FCRDPView *)view stop]; }
void fc_rdp_set_active(void *view, int active) { [(__bridge FCRDPView *)view setSessionActive:active != 0]; }
int fc_rdp_status(void *view) { return ((__bridge FCRDPView *)view).connectionStatus; }
uint32_t fc_rdp_error(void *view) { return ((__bridge FCRDPView *)view).errorCode; }

int fc_rdp_failure(void *view) {
    switch (fc_rdp_error(view)) {
        case FREERDP_ERROR_DNS_ERROR: case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
        case FREERDP_ERROR_CONNECT_FAILED: case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED: return 1;
        case FREERDP_ERROR_TLS_CONNECT_FAILED: return 2;
        case FREERDP_ERROR_AUTHENTICATION_FAILED: case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD: case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS: return 3;
        case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED: case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
        case FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED: case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION: case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
        case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED: case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED: return 4;
        case FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT: return 5;
        default: return 0;
    }
}
