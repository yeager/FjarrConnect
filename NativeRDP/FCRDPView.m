// Copyright © 2026 FjärrConnect contributors. MIT license.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import "FCRDPView.h"
#import "FCKeyboardSequences.h"
#include <freerdp/config.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/error.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/clipboard.h>
#include <winpr/shell.h>
#include <winpr/input.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdint.h>

@class FCRDPView;
typedef struct {
    rdpClientContext common;
    __unsafe_unretained FCRDPView *view; // Worker retains the view until context_free.
    pRTTMeasureResponse originalRTTMeasureResponse;
    CliprdrClientContext *clipboard;
    wClipboard *fileClipboard;
    UINT32 fileGroupDescriptorFormat;
    _Atomic(UINT32) serverClipboardFlags;
    DispClientContext *display;
    _Atomic(BOOL) displayReady;
    _Atomic(BOOL) clipboardReady;
} FCContext;
typedef void (^FCInput)(FCContext *);
static FCRDPView *FCView(rdpContext *context) { return ((FCContext *)context)->view; }
static BOOL FCPreConnect(freerdp *instance);
static BOOL FCPostConnect(freerdp *instance);
static void FCPostDisconnect(freerdp *instance);
static BOOL FCRTTMeasureResponse(rdpAutoDetect *autodetect, RDP_TRANSPORT_TYPE transport,
                                 UINT16 sequenceNumber);
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
static const NSUInteger FCClipboardMaximumFiles = 32;
#define FCClipboardMaximumNameCharacters 259
static const UINT32 FCClipboardFileDescriptorBytes = 592;
static const uint64_t FCClipboardMaximumFileBytes = UINT32_MAX;
static const uint64_t FCClipboardMaximumIncomingTotalBytes = 256ULL * 1024 * 1024;
static const UINT32 FCClipboardMaximumFileReadBytes = 4 * 1024 * 1024;
static const UINT32 FCClipboardMaximumIncomingChunkBytes = 4 * 1024 * 1024;
#if !defined(NDEBUG)
#define FCClipboardLog(format, ...) NSLog((@"FCRDP clipboard " format), ##__VA_ARGS__)
#else
#define FCClipboardLog(format, ...) ((void)0)
#endif

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

static NSData *FCClipboardFileContents(NSURL *url, uint64_t expectedSize, UINT32 flags,
                                      uint64_t offset, UINT32 requestedLength) {
    if (!url.isFileURL || (flags != FILECONTENTS_SIZE && flags != FILECONTENTS_RANGE)) return nil;
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info = {0};
    if (fd < 0 || fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        (uint64_t)info.st_size != expectedSize) {
        if (fd >= 0) close(fd);
        return nil;
    }

    NSData *payload = nil;
    if (flags == FILECONTENTS_SIZE) {
        uint64_t littleEndianSize = CFSwapInt64HostToLittle(expectedSize);
        payload = [NSData dataWithBytes:&littleEndianSize length:sizeof(littleEndianSize)];
    } else if (requestedLength <= FCClipboardMaximumFileReadBytes && offset <= expectedSize) {
        if (requestedLength == 0 && expectedSize == 0) { close(fd); return [NSData data]; }
        if (requestedLength == 0) { close(fd); return nil; }
        const uint32_t length = (uint32_t)MIN((uint64_t)requestedLength, expectedSize - offset);
        if (length == 0) { close(fd); return [NSData data]; }
        NSMutableData *data = [NSMutableData dataWithLength:length];
        size_t received = 0;
        while (received < length) {
            ssize_t count = pread(fd, (uint8_t *)data.mutableBytes + received,
                                  length - received, (off_t)(offset + received));
            if (count <= 0) break;
            received += (size_t)count;
        }
        if (received == length) payload = data;
    }
    close(fd);
    return payload;
}

/// The list advertised to Windows and the files that service its later range
/// requests must always belong to the same clipboard generation.
@interface FCClipboardFileSnapshot : NSObject
@property(nonatomic, readonly, copy) NSArray<NSURL *> *files;
@property(nonatomic, readonly, copy) NSData *descriptors;
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *sizes;
- (instancetype)initWithFiles:(NSArray<NSURL *> *)files
                   descriptors:(NSData *)descriptors
                         sizes:(NSArray<NSNumber *> *)sizes;
@end

@implementation FCClipboardFileSnapshot
- (instancetype)initWithFiles:(NSArray<NSURL *> *)files
                   descriptors:(NSData *)descriptors
                         sizes:(NSArray<NSNumber *> *)sizes {
    if ((self = [super init])) {
        _files = [files copy];
        _descriptors = [descriptors copy];
        _sizes = [sizes copy];
    }
    return self;
}
@end

@interface FCRemoteClipboardFile : NSObject
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, strong) NSURL *url;
@property(nonatomic, readonly) uint64_t size;
- (instancetype)initWithName:(NSString *)name url:(NSURL *)url size:(uint64_t)size;
@end

@implementation FCRemoteClipboardFile
- (instancetype)initWithName:(NSString *)name url:(NSURL *)url size:(uint64_t)size {
    if ((self = [super init])) { _name = [name copy]; _url = url; _size = size; }
    return self;
}
@end

@interface FCRemoteClipboardTransfer : NSObject
@property(nonatomic, readonly, copy) NSString *directory;
@property(nonatomic, readonly, copy) NSArray<FCRemoteClipboardFile *> *files;
@property(nonatomic) NSUInteger fileIndex;
@property(nonatomic) uint64_t fileOffset;
@property(nonatomic) UINT32 streamID;
@property(nonatomic) UINT32 pendingLength;
@property(nonatomic) BOOL awaitingResponse;
@property(atomic) BOOL cancelled;
@property(nonatomic) NSInteger pasteboardChangeCount;
- (instancetype)initWithDirectory:(NSString *)directory files:(NSArray<FCRemoteClipboardFile *> *)files;
@end

@implementation FCRemoteClipboardTransfer
- (instancetype)initWithDirectory:(NSString *)directory files:(NSArray<FCRemoteClipboardFile *> *)files {
    if ((self = [super init])) { _directory = [directory copy]; _files = [files copy]; }
    return self;
}
@end

static void FCCleanupStaleRemoteClipboardFiles(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *temporaryDirectory = NSTemporaryDirectory();
    NSArray<NSString *> *entries = [files contentsOfDirectoryAtPath:temporaryDirectory error:nil];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-24 * 60 * 60];
    for (NSString *entry in entries) {
        if (![entry hasPrefix:@"FjarrConnectClipboard."]) continue;
        NSString *path = [temporaryDirectory stringByAppendingPathComponent:entry];
        NSDate *modified = [files attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (modified && [modified compare:cutoff] == NSOrderedAscending)
            [files removeItemAtPath:path error:nil];
    }
}

@interface FCRDPView : NSView <NSTextInputClient>
@property(nonatomic, readonly) NSDictionary<NSString *, NSString *> *translations;
@property(atomic) int connectionStatus;
@property(atomic) int connectionStage;
@property(atomic) uint32_t requestedProtocols;
@property(atomic) uint32_t selectedProtocol;
@property(atomic) uint32_t inputState;
@property(atomic) BOOL hasReceivedFrame;
@property(atomic) uint32_t errorCode;
@property(atomic) BOOL cancelled;
@property(atomic) BOOL clipboardActive;
@property(atomic, copy) NSData *clipboardText;
@property(atomic, copy) NSData *clipboardImage;
@property(atomic, strong) FCClipboardFileSnapshot *clipboardFileSnapshot;
@property(atomic, strong) FCClipboardFileSnapshot *clipboardFileTransferSnapshot;
@property(atomic, strong) FCRemoteClipboardTransfer *remoteClipboardTransfer;
@property(atomic, copy) NSString *remoteClipboardOutputDirectory;
@property(atomic) uint32_t clipboardRequestedFormat;
@property(atomic) BOOL needsClipboardAnnouncement;
@property(atomic) BOOL clipboardAllowed;
@property(atomic) BOOL clipboardFileTransferRequested;
@property(atomic) BOOL clipboardFileTransferAllowed;
@property(atomic) BOOL unicodeSupported;
@property(atomic) uint32_t requestedWidth;
@property(atomic) uint32_t requestedHeight;
@property(atomic) int negotiatedCodec;
@property(atomic) uint32_t roundTripMilliseconds;
@property(nonatomic) NSCursor *remoteCursor;
@property(nonatomic, strong) id windowResignKeyObserver;
@property(nonatomic, strong) id applicationResignActiveObserver;
- (instancetype)initWithArguments:(NSString *)arguments translations:(NSDictionary *)translations;
- (void)start;
- (void)stop;
- (void)setSessionActive:(BOOL)active;
- (void)sendSecureAttentionSequence;
- (void)releaseInput;
- (void)setSessionActive:(BOOL)active pasteboard:(NSPasteboard *)pasteboard;
- (void)setClipboardActive:(BOOL)active pasteboard:(NSPasteboard *)pasteboard;
- (void)captureClipboardFromPasteboard:(NSPasteboard *)pasteboard;
- (void)enqueue:(FCInput)input;
- (void)enqueue:(FCInput)input release:(BOOL)isRelease;
- (void)enqueueKeyRepeat:(unsigned short)key code:(DWORD)code;
- (void)publishFrame:(rdpGdi *)gdi;
- (NSData *)DIBFromPasteboard:(NSPasteboard *)pasteboard;
- (NSArray<NSURL *> *)clipboardFileURLsFromPasteboard:(NSPasteboard *)pasteboard;
- (NSData *)fileDescriptorDataForURLs:(NSArray<NSURL *> *)urls;
- (NSData *)clipboardFileDescriptorsForRequestFormat:(UINT32)requestedFormat
                                      registeredFormat:(UINT32)registeredFormat
                                            serverFlags:(UINT32)serverFlags;
- (NSData *)clipboardFileContentsForURL:(NSURL *)url expectedSize:(uint64_t)expectedSize
                                  flags:(uint32_t)flags offset:(uint64_t)offset requestedLength:(uint32_t)requestedLength;
- (NSData *)clipboardFileContentsForRequest:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request
                               serverFlags:(UINT32)serverFlags;
- (BOOL)beginRemoteClipboardFileTransfer:(NSData *)data clip:(CliprdrClientContext *)clip;
- (UINT)receiveRemoteClipboardFileResponse:(CliprdrClientContext *)clip
                                  response:(const CLIPRDR_FILE_CONTENTS_RESPONSE *)response;
- (void)requestNextRemoteClipboardFileChunk:(CliprdrClientContext *)clip;
- (void)discardRemoteClipboardFileTransfer;
- (void)cleanupRemoteClipboardOutputFiles;
- (UINT32)clipboardFeatureMaskForFileTransfer:(BOOL)enabled;
- (NSData *)unicodeInputDataForText:(NSString *)text;
- (void)receiveClipboardDIB:(NSData *)dib;
- (void)writeClipboardDIB:(NSData *)dib;
- (NSString *)text:(NSString *)key;
- (DWORD)certificateForHost:(NSString *)host port:(UINT16)port commonName:(NSString *)name subject:(NSString *)subject issuer:(NSString *)issuer fingerprint:(NSString *)fingerprint oldFingerprint:(NSString *)oldFingerprint flags:(DWORD)flags;
@end

@implementation FCRDPView {
    FCContext *_context;
    NSLock *_lock;
    NSMutableArray<FCInput> *_input;
    NSMutableSet<NSNumber *> *_queuedKeyRepeats;
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
        NSMutableArray<NSString *> *freeRDPLines = [NSMutableArray new];
        for (NSString *line in [arguments componentsSeparatedByString:@"\n"]) {
            if ([line isEqualToString:@"/fc:clipboard-files"]) self.clipboardFileTransferRequested = YES;
            else if (line.length) [freeRDPLines addObject:line];
        }
        _arguments = [[freeRDPLines componentsJoinedByString:@"\n"] copy];
        _translations = [translations copy];
        _lock = [NSLock new];
        _input = [NSMutableArray new];
        _queuedKeyRepeats = [NSMutableSet new];
        _pressedKeys = [NSMutableSet new];
        _mouseButtons = [NSMutableSet new];
        _markedText = [NSMutableAttributedString new];
        static dispatch_once_t cleanupOnce;
        dispatch_once(&cleanupOnce, ^{ FCCleanupStaleRemoteClipboardFiles(); });
        _remoteCursor = NSCursor.arrowCursor;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.requestedWidth = 1280;
        self.requestedHeight = 800;
        self.wantsLayer = YES;
    }
    return self;
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    if (self.windowResignKeyObserver) {
        [notifications removeObserver:self.windowResignKeyObserver];
        self.windowResignKeyObserver = nil;
    }
    if (self.applicationResignActiveObserver) {
        [notifications removeObserver:self.applicationResignActiveObserver];
        self.applicationResignActiveObserver = nil;
    }
    NSWindow *window = self.window;
    if (!window) return;

    __weak FCRDPView *weakSelf = self;
    self.windowResignKeyObserver = [notifications addObserverForName:NSWindowDidResignKeyNotification
                                                               object:window
                                                                queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *notification) {
        [weakSelf releaseInput];
    }];
    self.applicationResignActiveObserver = [notifications addObserverForName:NSApplicationDidResignActiveNotification
                                                                       object:NSApp
                                                                        queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(NSNotification *notification) {
        [weakSelf releaseInput];
    }];
}
- (void)dealloc {
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    if (self.windowResignKeyObserver) [notifications removeObserver:self.windowResignKeyObserver];
    if (self.applicationResignActiveObserver) [notifications removeObserver:self.applicationResignActiveObserver];
}
- (NSString *)text:(NSString *)key { return self.translations[key] ?: key; }
- (UINT32)clipboardFeatureMaskForFileTransfer:(BOOL)enabled {
    UINT32 features = CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_REMOTE_TO_LOCAL;
    if (enabled) features |= CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES | CLIPRDR_FLAG_REMOTE_TO_LOCAL_FILES;
    return features;
}
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
    self.hasReceivedFrame = YES;
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { [self runConnection]; }
        // runConnection may release Objective-C state from FreeRDP callbacks.
        // Publish completion only after its autorelease pool has drained so a
        // caller observing status 3 can safely tear down the hosting view.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_clipboardTimer invalidate];
            self->_clipboardTimer = nil;
            self.connectionStatus = 3;
        });
    });
}
- (void)stop {
    self.cancelled = YES;
    self.clipboardActive = NO;
    self.clipboardText = nil;
    self.clipboardImage = nil;
    self.clipboardFileSnapshot = nil;
    self.clipboardFileTransferSnapshot = nil;
    [_clipboardTimer invalidate]; _clipboardTimer = nil;
    if (_certificateAlert) [NSApp abortModal];
    [_lock lock];
    if (_context) freerdp_abort_connect_context(&_context->common.context);
    [_lock unlock];
}
- (void)setSessionActive:(BOOL)active {
    [self setSessionActive:active pasteboard:NSPasteboard.generalPasteboard];
}
- (void)setSessionActive:(BOOL)active pasteboard:(NSPasteboard *)pasteboard {
    _sessionActive = active;
    [self setClipboardActive:active && NSApp.isActive && self.window.isKeyWindow && self.clipboardAllowed
                    pasteboard:pasteboard];
}
- (void)setClipboardActive:(BOOL)active pasteboard:(NSPasteboard *)pasteboard {
    BOOL wasClipboardActive = self.clipboardActive;
    self.clipboardActive = active;
    _clipboardChange = pasteboard.changeCount;
    if (!active) {
        self.remoteClipboardTransfer.cancelled = YES;
        self.clipboardText = nil; self.clipboardImage = nil;
        self.clipboardFileSnapshot = nil;
        self.clipboardFileTransferSnapshot = nil;
        if (wasClipboardActive) [self releaseInput];
    } else if (self.connectionStatus == 2) {
        // The selected session may consume the current local clipboard when
        // it becomes active. Inactive sessions still clear cached contents.
        [self captureClipboardFromPasteboard:pasteboard];
    }
}
- (void)clipboardTick {
    BOOL active = _sessionActive && NSApp.isActive && self.window.isKeyWindow && self.clipboardAllowed;
    if (self.clipboardActive != active) {
        [self setClipboardActive:active pasteboard:NSPasteboard.generalPasteboard];
    }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    if (!active || self.connectionStatus != 2 || pasteboard.changeCount == _clipboardChange) return;
    _clipboardChange = pasteboard.changeCount;
    self.remoteClipboardTransfer.cancelled = YES;
    [self cleanupRemoteClipboardOutputFiles];
    [self captureClipboardFromPasteboard:pasteboard];
}
- (void)captureClipboardFromPasteboard:(NSPasteboard *)pasteboard {
    NSArray<NSURL *> *fileURLs = [self clipboardFileURLsFromPasteboard:pasteboard];
    NSData *fileDescriptors = [self fileDescriptorDataForURLs:fileURLs];
    FCClipboardFileSnapshot *fileSnapshot = self.clipboardFileSnapshot;
    FCClipboardLog(@"local-files count=%lu descriptor-bytes=%lu active=%d",
                   (unsigned long)fileSnapshot.files.count, (unsigned long)fileDescriptors.length, self.clipboardActive);
    NSData *image = [self DIBFromPasteboard:pasteboard];
    self.clipboardImage = image;
    // Finder may expose a path as plain text as well as a file URL. Do not
    // accidentally copy a local path to Windows as ordinary clipboard text.
    NSString *text = fileURLs.count ? nil : [pasteboard stringForType:NSPasteboardTypeString];
    if (text.length > 512 * 1024) self.clipboardText = nil;
    else {
        text = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
        NSMutableData *data = [[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
        if (data && data.length <= 1024 * 1024) {
            const uint16_t nul = 0; [data appendBytes:&nul length:2];
            self.clipboardText = data;
        } else self.clipboardText = nil;
    }
    self.needsClipboardAnnouncement = YES;
}
- (NSArray<NSURL *> *)clipboardFileURLsFromPasteboard:(NSPasteboard *)pasteboard {
    // Finder's file-url objects can resolve to an internal /.file/id=… URL,
    // which is not a readable path. Prefer its filename list when available.
    NSArray *paths = [pasteboard propertyListForType:@"NSFilenamesPboardType"];
    NSMutableArray<NSURL *> *candidates = [NSMutableArray new];
    if ([paths isKindOfClass:NSArray.class]) {
        for (id path in paths) {
            if ([path isKindOfClass:NSString.class] && [path length] > 0)
                [candidates addObject:[NSURL fileURLWithPath:path]];
        }
    }
    if (candidates.count == 0) {
        NSArray *objects = [pasteboard readObjectsForClasses:@[NSURL.class]
                                                      options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
        if ([objects isKindOfClass:NSArray.class]) {
            for (id object in objects) if ([object isKindOfClass:NSURL.class]) [candidates addObject:object];
        }
    }
    if (candidates.count == 0) return @[];
    NSMutableArray<NSURL *> *files = [NSMutableArray arrayWithCapacity:MIN(candidates.count, FCClipboardMaximumFiles)];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    for (NSURL *candidate in candidates) {
        if (files.count >= FCClipboardMaximumFiles) break;
        NSURL *url = [candidate URLByStandardizingPath];
        if (!url.isFileURL || !url.path.length || [seen containsObject:url.path]) continue;
        struct stat info = {0};
        if (lstat(url.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
            info.st_size < 0 || (uint64_t)info.st_size > FCClipboardMaximumFileBytes) continue;
        [seen addObject:url.path];
        [files addObject:url];
    }
    return files.copy;
}
- (NSData *)fileDescriptorDataForURLs:(NSArray<NSURL *> *)urls {
    // Publish a new clipboard generation before validating it. An empty or
    // rejected file list must invalidate the current manifest. The in-flight
    // transfer snapshot is retired only when Windows requests the next list.
    self.clipboardFileSnapshot = nil;
    if (urls.count == 0 || urls.count > FCClipboardMaximumFiles) return nil;
    FILEDESCRIPTORW *descriptors = calloc(urls.count, sizeof(FILEDESCRIPTORW));
    if (!descriptors) return nil;
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray arrayWithCapacity:urls.count];
    BOOL valid = YES;
    for (NSUInteger index = 0; index < urls.count; index++) {
        NSURL *url = urls[index];
        struct stat info = {0};
        NSString *name = url.lastPathComponent.precomposedStringWithCanonicalMapping;
        if (lstat(url.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
            (uint64_t)info.st_size > FCClipboardMaximumFileBytes || name.length == 0 ||
            name.length > FCClipboardMaximumNameCharacters || [name containsString:@"/"] ||
            [name containsString:@"\\"] || [name containsString:@"\n"] || [name containsString:@"\r"]) {
            valid = NO; break;
        }
        FILEDESCRIPTORW *descriptor = &descriptors[index];
        descriptor->dwFlags = FD_ATTRIBUTES | FD_FILESIZE;
        descriptor->dwFileAttributes = 0x80; // FILE_ATTRIBUTE_NORMAL
        descriptor->nFileSizeHigh = (DWORD)((uint64_t)info.st_size >> 32);
        descriptor->nFileSizeLow = (DWORD)((uint64_t)info.st_size & UINT32_MAX);
        [sizes addObject:@((uint64_t)info.st_size)];
        unichar characters[FCClipboardMaximumNameCharacters] = {0};
        [name getCharacters:characters range:NSMakeRange(0, name.length)];
        for (NSUInteger character = 0; character < name.length; character++)
            descriptor->cFileName[character] = (WCHAR)characters[character];
    }
    BYTE *serialized = NULL;
    UINT32 serializedLength = 0;
    UINT status = valid ? cliprdr_serialize_file_list(descriptors, (UINT32)urls.count, &serialized, &serializedLength) : ERROR_INVALID_DATA;
    free(descriptors);
    if (status != CHANNEL_RC_OK || !serialized || serializedLength == 0 || serializedLength > 1024 * 1024) {
        free(serialized);
        return nil;
    }
    NSData *result = [NSData dataWithBytes:serialized length:serializedLength];
    free(serialized);
    self.clipboardFileSnapshot = [[FCClipboardFileSnapshot alloc] initWithFiles:urls
                                                                    descriptors:result
                                                                          sizes:sizes];
    return result;
}
- (NSData *)clipboardFileDescriptorsForRequestFormat:(UINT32)requestedFormat
                                      registeredFormat:(UINT32)registeredFormat
                                            serverFlags:(UINT32)serverFlags {
    if (!registeredFormat || requestedFormat != registeredFormat) return nil;
    // Once the remote side asks for a new file manifest, retire the previous
    // transfer even if this request no longer satisfies the opt-in/capability
    // gates. Otherwise a later range request could read an obsolete snapshot.
    self.clipboardFileTransferSnapshot = nil;
    if (!self.clipboardFileTransferAllowed || !self.clipboardActive ||
        !(serverFlags & CB_STREAM_FILECLIP_ENABLED)) return nil;
    FCClipboardFileSnapshot *snapshot = self.clipboardFileSnapshot;
    self.clipboardFileTransferSnapshot = snapshot.descriptors.length ? snapshot : nil;
    if (!snapshot.descriptors.length) return nil;
    // Retain the exact manifest snapshot until Windows requests another one.
    return snapshot.descriptors;
}
- (NSData *)clipboardFileContentsForURL:(NSURL *)url expectedSize:(uint64_t)expectedSize
                                  flags:(uint32_t)flags offset:(uint64_t)offset requestedLength:(uint32_t)requestedLength {
    return FCClipboardFileContents(url, expectedSize, flags, offset, requestedLength);
}
- (NSData *)clipboardFileContentsForRequest:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request
                               serverFlags:(UINT32)serverFlags {
    FCClipboardFileSnapshot *snapshot = self.clipboardFileTransferSnapshot;
    if (!request || !self.clipboardFileTransferAllowed || !self.clipboardActive ||
        !(serverFlags & CB_STREAM_FILECLIP_ENABLED) || !snapshot.files.count ||
        !snapshot.descriptors.length || request->listIndex >= snapshot.files.count ||
        request->listIndex >= snapshot.sizes.count)
        return nil;

    if (request->dwFlags == FILECONTENTS_SIZE &&
        (request->nPositionLow || request->nPositionHigh || request->cbRequested != sizeof(uint64_t)))
        return nil;
    if (request->dwFlags != FILECONTENTS_SIZE && request->dwFlags != FILECONTENTS_RANGE) return nil;

    const uint64_t expectedSize = snapshot.sizes[request->listIndex].unsignedLongLongValue;
    const uint64_t offset = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
    return FCClipboardFileContents(snapshot.files[request->listIndex], expectedSize,
                                   request->dwFlags, offset, request->cbRequested);
}
- (void)discardRemoteClipboardFileTransfer {
    FCRemoteClipboardTransfer *transfer = self.remoteClipboardTransfer;
    self.remoteClipboardTransfer = nil;
    if (transfer.directory.length)
        [[NSFileManager defaultManager] removeItemAtPath:transfer.directory error:nil];
}
- (void)cleanupRemoteClipboardOutputFiles {
    NSString *directory = self.remoteClipboardOutputDirectory;
    self.remoteClipboardOutputDirectory = nil;
    if (directory.length) [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
}
- (BOOL)beginRemoteClipboardFileTransfer:(NSData *)data clip:(CliprdrClientContext *)clip {
    [self discardRemoteClipboardFileTransfer];
    if (!data.length || data.length > 1024 * 1024 || !self.clipboardFileTransferAllowed ||
        !self.clipboardActive || !self->_sessionActive || self.cancelled || !clip->ClientFileContentsRequest)
        return NO;

    // FreeRDP 3.32's parser can loop forever on valid names containing a dot.
    // Parse the fixed-width wire records ourselves after validating count/size.
    const BYTE *wire = data.bytes;
    if (data.length < 4) return NO;
    UINT32 count = FCReadLE32(wire);
    if (count == 0 || count > FCClipboardMaximumFiles ||
        4ULL + (uint64_t)count * FCClipboardFileDescriptorBytes != data.length) return NO;

    NSMutableArray<FCRemoteClipboardFile *> *files = [NSMutableArray arrayWithCapacity:count];
    NSMutableSet<NSString *> *names = [NSMutableSet setWithCapacity:count];
    uint64_t totalSize = 0;
    BOOL valid = YES;
    for (UINT32 index = 0; index < count; index++) {
        const BYTE *descriptor = wire + 4 + (NSUInteger)index * FCClipboardFileDescriptorBytes;
        const UINT32 descriptorFlags = FCReadLE32(descriptor);
        const UINT32 fileAttributes = FCReadLE32(descriptor + 36);
        if (!(descriptorFlags & FD_FILESIZE) ||
            ((descriptorFlags & FD_ATTRIBUTES) && (fileAttributes & 0x10))) {
            valid = NO; break;
        }
        NSUInteger nameLength = 0;
        unichar characters[260] = {0};
        while (nameLength < 260) {
            characters[nameLength] = FCReadLE16(descriptor + 72 + nameLength * sizeof(uint16_t));
            if (!characters[nameLength]) break;
            nameLength++;
        }
        if (nameLength == 0 || nameLength == 260) { valid = NO; break; }
        NSString *name = [[NSString alloc] initWithCharacters:characters length:nameLength];
        name = name.precomposedStringWithCanonicalMapping;
        if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
            [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255 ||
            [name containsString:@"/"] || [name containsString:@"\\"] || [name containsString:@":"] ||
            [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
            [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\u202A\u202B\u202D\u202E\u2066\u2067\u2068\u2069"]].location != NSNotFound) {
            valid = NO; break;
        }
        NSString *collisionKey = name.lowercaseString;
        if ([names containsObject:collisionKey]) { valid = NO; break; }
        [names addObject:collisionKey];
        uint64_t size = ((uint64_t)FCReadLE32(descriptor + 64) << 32) | FCReadLE32(descriptor + 68);
        if (size > FCClipboardMaximumFileBytes || size > FCClipboardMaximumIncomingTotalBytes - totalSize) {
            valid = NO; break;
        }
        totalSize += size;
        [files addObject:[[FCRemoteClipboardFile alloc] initWithName:name url:nil size:size]];
    }
    if (!valid || files.count != count) return NO;

    __block NSInteger pasteboardChangeCount = 0;
    void (^readPasteboardState)(void) = ^{ pasteboardChangeCount = NSPasteboard.generalPasteboard.changeCount; };
    if (NSThread.isMainThread) readPasteboardState();
    else dispatch_sync(dispatch_get_main_queue(), readPasteboardState);

    NSString *directoryTemplate = [NSTemporaryDirectory() stringByAppendingPathComponent:@"FjarrConnectClipboard.XXXXXX"];
    char directoryPath[PATH_MAX] = {0};
    if (![directoryTemplate getFileSystemRepresentation:directoryPath maxLength:sizeof(directoryPath)] || !mkdtemp(directoryPath))
        return NO;
    NSString *directory = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:directoryPath
                                                                                     length:strlen(directoryPath)];
    NSMutableArray<FCRemoteClipboardFile *> *createdFiles = [NSMutableArray arrayWithCapacity:count];
    for (FCRemoteClipboardFile *file in files) {
        NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:file.name]];
        int fd = open(url.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                      S_IRUSR | S_IWUSR);
        BOOL created = fd >= 0 && ftruncate(fd, (off_t)file.size) == 0;
        if (fd >= 0) close(fd);
        if (!created) { valid = NO; break; }
        [createdFiles addObject:[[FCRemoteClipboardFile alloc] initWithName:file.name url:url size:file.size]];
    }
    if (!valid || createdFiles.count != count) {
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        return NO;
    }

    FCRemoteClipboardTransfer *transfer = [[FCRemoteClipboardTransfer alloc] initWithDirectory:directory files:createdFiles];
    transfer.streamID = arc4random();
    if (!transfer.streamID) transfer.streamID = 1;
    transfer.fileIndex = 0;
    transfer.fileOffset = 0;
    transfer.pendingLength = 0;
    transfer.awaitingResponse = NO;
    transfer.cancelled = NO;
    // Keep the clipboard contents that were present when Windows offered the
    // files. A user's intervening copy must not be overwritten by completion.
    transfer.pasteboardChangeCount = pasteboardChangeCount;
    self.remoteClipboardTransfer = transfer;
    [self requestNextRemoteClipboardFileChunk:clip];
    return YES;
}
- (void)requestNextRemoteClipboardFileChunk:(CliprdrClientContext *)clip {
    FCRemoteClipboardTransfer *transfer = self.remoteClipboardTransfer;
    if (!transfer || transfer.cancelled || !self.clipboardActive || !self.clipboardFileTransferAllowed ||
        !self->_sessionActive || self.cancelled || !clip->ClientFileContentsRequest) {
        [self discardRemoteClipboardFileTransfer];
        return;
    }
    while (transfer.fileIndex < transfer.files.count &&
           transfer.files[transfer.fileIndex].size == transfer.fileOffset) {
        transfer.fileIndex++; transfer.fileOffset = 0;
    }
    if (transfer.fileIndex >= transfer.files.count) {
        self.remoteClipboardTransfer = nil;
        NSArray<NSURL *> *urls = [transfer.files valueForKey:@"url"];
        NSInteger baseline = transfer.pasteboardChangeCount;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            if (!self.clipboardActive || !self->_sessionActive || !NSApp.isActive || !self.window.isKeyWindow ||
                self.cancelled || pasteboard.changeCount != baseline) {
                [[NSFileManager defaultManager] removeItemAtPath:transfer.directory error:nil];
                return;
            }
            [pasteboard clearContents];
            if ([pasteboard writeObjects:urls]) {
                self->_clipboardChange = pasteboard.changeCount;
                [self cleanupRemoteClipboardOutputFiles];
                self.remoteClipboardOutputDirectory = transfer.directory;
            } else {
                [[NSFileManager defaultManager] removeItemAtPath:transfer.directory error:nil];
            }
        });
        return;
    }
    if (transfer.awaitingResponse) return;

    FCRemoteClipboardFile *file = transfer.files[transfer.fileIndex];
    UINT32 requestedLength = (UINT32)MIN((uint64_t)FCClipboardMaximumIncomingChunkBytes,
                                         file.size - transfer.fileOffset);
    CLIPRDR_FILE_CONTENTS_REQUEST request = {0};
    request.common.msgType = CB_FILECONTENTS_REQUEST;
    request.common.dataLen = (UINT32)(sizeof(request) - sizeof(request.common));
    request.streamId = ++transfer.streamID;
    if (!request.streamId) request.streamId = ++transfer.streamID;
    request.listIndex = (UINT32)transfer.fileIndex;
    request.dwFlags = FILECONTENTS_RANGE;
    request.nPositionLow = (UINT32)(transfer.fileOffset & UINT32_MAX);
    request.nPositionHigh = (UINT32)(transfer.fileOffset >> 32);
    request.cbRequested = requestedLength;
    transfer.streamID = request.streamId;
    transfer.pendingLength = requestedLength;
    transfer.awaitingResponse = YES;
    UINT status = clip->ClientFileContentsRequest(clip, &request);
    if (status != CHANNEL_RC_OK) [self discardRemoteClipboardFileTransfer];
}
- (UINT)receiveRemoteClipboardFileResponse:(CliprdrClientContext *)clip
                                  response:(const CLIPRDR_FILE_CONTENTS_RESPONSE *)response {
    FCRemoteClipboardTransfer *transfer = self.remoteClipboardTransfer;
    if (!transfer) return CHANNEL_RC_OK;
    if (!response || transfer.cancelled || !self.clipboardActive || !self.clipboardFileTransferAllowed ||
        !self->_sessionActive || self.cancelled || !transfer.awaitingResponse ||
        response->streamId != transfer.streamID || !(response->common.msgFlags & CB_RESPONSE_OK) ||
        response->cbRequested != transfer.pendingLength || !response->requestedData ||
        transfer.fileIndex >= transfer.files.count) {
        [self discardRemoteClipboardFileTransfer];
        return CHANNEL_RC_OK;
    }

    FCRemoteClipboardFile *file = transfer.files[transfer.fileIndex];
    int fd = open(file.url.fileSystemRepresentation, O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
    BOOL success = fd >= 0;
    size_t written = 0;
    while (success && written < response->cbRequested) {
        ssize_t count = pwrite(fd, response->requestedData + written, response->cbRequested - written,
                               (off_t)(transfer.fileOffset + written));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { success = NO; break; }
        written += (size_t)count;
    }
    if (fd >= 0) close(fd);
    if (!success || written != response->cbRequested || response->cbRequested > file.size - transfer.fileOffset) {
        [self discardRemoteClipboardFileTransfer];
        return CHANNEL_RC_OK;
    }
    transfer.fileOffset += response->cbRequested;
    transfer.awaitingResponse = NO;
    transfer.pendingLength = 0;
    [self requestNextRemoteClipboardFileChunk:clip];
    return CHANNEL_RC_OK;
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
    [self enqueue:input release:NO];
}
- (void)enqueue:(FCInput)input release:(BOOL)isRelease {
    if (self.cancelled || self.connectionStatus != 2) return;
    [_lock lock];
    // Reserve room for key-up and mouse-up events so queue pressure cannot
    // leave a remote key or button held after the user releases it.
    if (_input.count < 4096 || (isRelease && _input.count < 4608))
        [_input addObject:[input copy]];
    [_lock unlock];
}
- (void)enqueueKeyRepeat:(unsigned short)key code:(DWORD)code {
    if (self.cancelled || self.connectionStatus != 2) return;
    NSNumber *keyNumber = @(key);
    [_lock lock];
    // Preserve normal autorepeat while the worker keeps up, but coalesce a
    // held key to one pending repeat when the network/input loop is delayed.
    if (_input.count < 4096 && ![_queuedKeyRepeats containsObject:keyNumber]) {
        [_queuedKeyRepeats addObject:keyNumber];
        __weak FCRDPView *weakSelf = self;
        [_input addObject:[^(FCContext *ctx) {
            freerdp_input_send_keyboard_event_ex(ctx->common.context.input, TRUE, TRUE, code);
            FCRDPView *view = weakSelf;
            if (!view) return;
            [view->_lock lock];
            [view->_queuedKeyRepeats removeObject:keyNumber];
            [view->_lock unlock];
        } copy]];
    }
    [_lock unlock];
}
- (void)runConnection {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ WLog_SetLogLevel(WLog_GetRoot(), WLOG_OFF); });
    RDP_CLIENT_ENTRY_POINTS entry = {0};
    entry.Version = RDP_CLIENT_INTERFACE_VERSION; entry.Size = sizeof(entry);
    entry.ContextSize = sizeof(FCContext);
    rdpContext *base = freerdp_client_context_new(&entry);
    if (!base) { self.errorCode = 0xFFFFFFFF; return; }
    FCContext *ctx = (FCContext *)base; ctx->view = self;
    ctx->fileClipboard = ClipboardCreate();
    if (ctx->fileClipboard)
        ctx->fileGroupDescriptorFormat = ClipboardRegisterFormat(ctx->fileClipboard, "FileGroupDescriptorW");
    freerdp *instance = base->instance;
    instance->PreConnect = FCPreConnect; instance->PostConnect = FCPostConnect; instance->PostDisconnect = FCPostDisconnect;
    instance->VerifyCertificateEx = FCCertificate; instance->VerifyChangedCertificateEx = FCChangedCertificate;
    instance->AuthenticateEx = FCAuthenticate; instance->PresentGatewayMessage = FCGatewayMessage; instance->RetryDialog = FCRetry;
    NSArray<NSString *> *freeRDPLines = [_arguments componentsSeparatedByString:@"\n"];
    char **argv = calloc(freeRDPLines.count + 2, sizeof(char *)); int argc = 0;
    argv[argc++] = strdup("FjarrConnect");
    for (NSString *line in freeRDPLines) argv[argc++] = strdup(line.UTF8String);
    int parsed = freerdp_client_settings_parse_command_line(base->settings, argc, argv, FALSE);
    const char *configuredUsername = freerdp_settings_get_string(base->settings, FreeRDP_Username);
    const char *configuredPassword = freerdp_settings_get_string(base->settings, FreeRDP_Password);
    self.inputState = (parsed == 0 ? 1u : 0u) |
        (configuredUsername && configuredUsername[0] ? 2u : 0u) |
        (configuredPassword && configuredPassword[0] ? 4u : 0u);
    for (int i = 0; i < argc; i++) { if (argv[i]) { memset_s(argv[i], strlen(argv[i]), 0, strlen(argv[i])); free(argv[i]); } }
    free(argv); _arguments = nil;
    self.clipboardAllowed = freerdp_settings_get_bool(base->settings, FreeRDP_RedirectClipboard);
    self.clipboardFileTransferAllowed = self.clipboardFileTransferRequested && self.clipboardAllowed;
    // Text and image clipboard remain independent of the opt-in file flows.
    freerdp_settings_set_uint32(base->settings, FreeRDP_ClipboardFeatureMask,
                                [self clipboardFeatureMaskForFileTransfer:self.clipboardFileTransferAllowed]);
    // The callback receives a SHA-256 fingerprint; never show an untranslated CLI prompt.
    freerdp_settings_set_bool(base->settings, FreeRDP_CertificateCallbackPreferPEM, FALSE);
    freerdp_settings_set_bool(base->settings, FreeRDP_AutoReconnectionEnabled, FALSE);
    freerdp_settings_set_bool(base->settings, FreeRDP_UnicodeInput, TRUE);
    // The embedded runtime does not use the RDSTLS gateway transport, so keep
    // it disabled for direct connections. Preserve HYBRID_EX: GNOME Remote
    // Desktop can select it when the client offers extended NLA security.
    freerdp_settings_set_bool(base->settings, FreeRDP_RdstlsSecurity, FALSE);
    // Keep FreeRDP's network autodetection enabled: Windows sends RTT requests
    // during desktop activation and the core must be able to answer them.
    [_lock lock]; _context = ctx; BOOL cancelled = self.cancelled; [_lock unlock];
    BOOL connected = parsed == 0 && !cancelled && freerdp_connect(instance);
    // Keep negotiated protocol flags available while a live session is active.
    // Capturing these only after the worker disconnects made successful
    // sessions appear to have selected the legacy zero-valued RDP protocol.
    self.requestedProtocols = freerdp_settings_get_uint32(base->settings, FreeRDP_RequestedProtocols);
    self.selectedProtocol = freerdp_settings_get_uint32(base->settings, FreeRDP_SelectedProtocol);
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
    [self discardRemoteClipboardFileTransfer];
    [_lock lock]; _context = NULL; [_input removeAllObjects]; [_queuedKeyRepeats removeAllObjects]; [_lock unlock];
    if (ctx->fileClipboard) { ClipboardDestroy(ctx->fileClipboard); ctx->fileClipboard = NULL; }
    freerdp_client_context_free(base);
    self.clipboardText = nil; self.clipboardImage = nil;
    self.clipboardFileSnapshot = nil; self.clipboardFileTransferSnapshot = nil;
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
- (void)mouse:(NSEvent *)event flags:(UINT16)flags release:(BOOL)isRelease {
    NSRect rect = [self imageRect]; NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (rect.size.width <= 0 || rect.size.height <= 0 || !_frame) return;
    UINT16 x = (UINT16)MAX(0, MIN(_frame.size.width - 1, (point.x - rect.origin.x) * _frame.size.width / rect.size.width));
    UINT16 y = (UINT16)MAX(0, MIN(_frame.size.height - 1, (point.y - rect.origin.y) * _frame.size.height / rect.size.height));
    [self enqueue:^(FCContext *ctx) { freerdp_input_send_mouse_event(ctx->common.context.input, flags, x, y); } release:isRelease];
}
- (void)mouse:(NSEvent *)event flags:(UINT16)flags { [self mouse:event flags:flags release:NO]; }
- (void)mouseMoved:(NSEvent *)event { [self mouse:event flags:PTR_FLAGS_MOVE]; }
- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)otherMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)button:(NSEvent *)event down:(BOOL)down button:(UINT16)button {
    [self.window makeFirstResponder:self];
    if (down) [_mouseButtons addObject:@(button)]; else [_mouseButtons removeObject:@(button)];
    [self mouse:event flags:button | (down ? PTR_FLAGS_DOWN : 0) release:!down];
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
    [self sendKey:key down:down repeat:NO];
}
- (void)sendKey:(unsigned short)key down:(BOOL)down repeat:(BOOL)isRepeat {
    DWORD code = [self scancode:key]; if (!code) return;
    NSNumber *keyNumber = @(key);
    if (down) {
        if ([_pressedKeys containsObject:keyNumber]) {
            if (isRepeat) [self enqueueKeyRepeat:key code:code];
            return;
        }
        if (isRepeat) return;
        [_pressedKeys addObject:keyNumber];
    } else {
        if (![_pressedKeys containsObject:keyNumber]) return;
        [_pressedKeys removeObject:keyNumber];
    }
    [self enqueue:^(FCContext *ctx) { freerdp_input_send_keyboard_event_ex(ctx->common.context.input, down, FALSE, code); } release:!down];
}
- (void)keyDown:(NSEvent *)event {
    if (!self.unicodeSupported || (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand))) [self sendKey:event.keyCode down:YES repeat:event.isARepeat];
    else [self interpretKeyEvents:@[event]];
}
- (void)keyUp:(NSEvent *)event { if ([_pressedKeys containsObject:@(event.keyCode)]) [self sendKey:event.keyCode down:NO repeat:NO]; }
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
- (void)sendSecureAttentionSequence {
    [self releaseInput];
    DWORD control = [self scancode:59], alt = [self scancode:58];
    DWORD end = FCMakeExtendedScanCode([self scancode:119]);
    [self enqueue:^(FCContext *ctx) {
        FCKeyboardStroke strokes[6];
        size_t count = FCMakeSecureAttentionSequence(control, alt, end, strokes);
        rdpInput *input = ctx->common.context.input;
        for (size_t index = 0; index < count; index++)
            freerdp_input_send_keyboard_event_ex(input, strokes[index].down, FALSE, strokes[index].scancode);
    }];
}
// Standard macOS Edit menu shortcuts operate on the remote application.
- (void)copy:(id)sender { [self sendControlShortcut:8]; }
- (void)cut:(id)sender { [self sendControlShortcut:7]; }
- (void)paste:(id)sender {
    BOOL active = _sessionActive && NSApp.isActive && self.window.isKeyWindow && self.clipboardAllowed;
    if (active && self.connectionStatus == 2) {
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        _clipboardChange = pasteboard.changeCount;
        [self captureClipboardFromPasteboard:pasteboard];
    }
    [self sendControlShortcut:9];
}
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
    for (NSNumber *button in _mouseButtons) [self enqueue:^(FCContext *ctx) { freerdp_input_send_mouse_event(ctx->common.context.input, button.unsignedShortValue, 0, 0); } release:YES];
    [_mouseButtons removeAllObjects];
}
- (BOOL)resignFirstResponder { [self releaseInput]; return [super resignFirstResponder]; }
- (void)insertText:(id)string replacementRange:(NSRange)range {
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    [self unmarkText];
    if (text.length > 1024 * 1024) return;
    NSData *input = [self unicodeInputDataForText:text];
    [self enqueue:^(FCContext *ctx) {
        const uint8_t *bytes = input.bytes;
        for (NSUInteger i = 0; i < input.length; i += sizeof(uint16_t)) {
            uint16_t unit = 0;
            memcpy(&unit, bytes + i, sizeof(unit));
            unit = CFSwapInt16LittleToHost(unit);
            freerdp_input_send_unicode_keyboard_event(ctx->common.context.input, KBD_FLAGS_DOWN, unit);
            freerdp_input_send_unicode_keyboard_event(ctx->common.context.input, KBD_FLAGS_RELEASE, unit);
        }
    }];
}
- (NSData *)unicodeInputDataForText:(NSString *)text {
    NSMutableData *input = [NSMutableData dataWithLength:text.length * sizeof(uint16_t)];
    uint8_t *bytes = input.mutableBytes;
    for (NSUInteger i = 0; i < text.length; i++) {
        uint16_t unit = CFSwapInt16HostToLittle([text characterAtIndex:i]);
        memcpy(bytes + i * sizeof(unit), &unit, sizeof(unit));
    }
    return input;
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
static UINT FCClipCapabilities(CliprdrClientContext *clip, const CLIPRDR_CAPABILITIES *caps) {
    FCContext *ctx = clip->custom;
    for (UINT32 index = 0; index < caps->cCapabilitiesSets; index++) {
        const CLIPRDR_CAPABILITY_SET *set = &caps->capabilitySets[index];
        if (set->capabilitySetType == CB_CAPSTYPE_GENERAL && set->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN) {
            ctx->serverClipboardFlags = ((const CLIPRDR_GENERAL_CAPABILITY_SET *)set)->generalFlags;
            FCClipboardLog(@"server-flags=0x%08x stream-files=%d", ctx->serverClipboardFlags,
                           (ctx->serverClipboardFlags & CB_STREAM_FILECLIP_ENABLED) != 0);
            break;
        }
    }
    return CHANNEL_RC_OK;
}
static UINT FCClipReady(CliprdrClientContext *clip, const CLIPRDR_MONITOR_READY *ready) {
    FCContext *ctx = clip->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = {CB_CAPSTYPE_GENERAL, CB_CAPSTYPE_GENERAL_LEN, CB_CAPS_VERSION_2,
        CB_USE_LONG_FORMAT_NAMES};
    if (ctx->view.clipboardFileTransferAllowed && ctx->fileGroupDescriptorFormat && ctx->view.clipboardAllowed)
        general.generalFlags |= CB_STREAM_FILECLIP_ENABLED;
    CLIPRDR_CAPABILITIES caps = {0}; caps.cCapabilitiesSets = 1; caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT result = clip->ClientCapabilities(clip, &caps); ctx->clipboardReady = TRUE;
    FCClipboardLog(@"client-flags=0x%08x result=%u", general.generalFlags, result);
    FCAnnounceClipboard(ctx); return result;
}
static void FCAnnounceClipboard(FCContext *ctx) {
    if (!ctx->clipboard) return;
    FCClipboardFileSnapshot *fileSnapshot = ctx->view.clipboardFileSnapshot;
    CLIPRDR_FORMAT formats[3] = {0};
    CLIPRDR_FORMAT_LIST list = {0};
    if (ctx->view.clipboardActive) {
        // Finder may publish both a file URL and its path as text. Only the
        // descriptor format is sent for that clipboard to avoid leaking paths.
        if (ctx->view.clipboardFileTransferAllowed && fileSnapshot.descriptors.length && ctx->fileGroupDescriptorFormat &&
            (ctx->serverClipboardFlags & CB_STREAM_FILECLIP_ENABLED))
            formats[list.numFormats++] = (CLIPRDR_FORMAT){ctx->fileGroupDescriptorFormat, "FileGroupDescriptorW"};
        // Keep DIB ahead of text so Windows pastes an image when both exist.
        if (ctx->view.clipboardImage) formats[list.numFormats++] = (CLIPRDR_FORMAT){CF_DIB, NULL};
        if (ctx->view.clipboardText) formats[list.numFormats++] = (CLIPRDR_FORMAT){CF_UNICODETEXT, NULL};
    }
    list.formats = formats;
    FCClipboardLog(@"announce count=%u files=%lu image=%d text=%d server-stream-files=%d",
                   list.numFormats, (unsigned long)fileSnapshot.files.count,
                   ctx->view.clipboardImage != nil, ctx->view.clipboardText != nil,
                   (ctx->serverClipboardFlags & CB_STREAM_FILECLIP_ENABLED) != 0);
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
        if (ctx->view.clipboardFileTransferAllowed && ctx->fileGroupDescriptorFormat &&
            (ctx->serverClipboardFlags & CB_STREAM_FILECLIP_ENABLED) &&
            candidate == ctx->fileGroupDescriptorFormat) {
            format = candidate;
            break;
        }
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
        else data = [ctx->view clipboardFileDescriptorsForRequestFormat:request->requestedFormatId
                                                       registeredFormat:ctx->fileGroupDescriptorFormat
                                                             serverFlags:ctx->serverClipboardFlags];
    }
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0}; response.common.msgFlags = CB_RESPONSE_FAIL;
    const NSUInteger maximum = request->requestedFormatId == CF_DIB ? FCClipboardImageMaximumBytes :
        (request->requestedFormatId == ctx->fileGroupDescriptorFormat ? 1024 * 1024 : 1024 * 1024 + 2);
    if (data && data.length <= maximum) {
        response.common.msgFlags = CB_RESPONSE_OK; response.common.dataLen = (UINT32)data.length; response.requestedFormatData = data.bytes;
    }
    FCClipboardLog(@"format-request id=0x%08x available=%d bytes=%lu", request->requestedFormatId,
                   data != nil, (unsigned long)data.length);
    return clip->ClientFormatDataResponse(clip, &response);
}
static UINT FCClipFileContentsRequest(CliprdrClientContext *clip, const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
    FCContext *ctx = clip->custom;
    CLIPRDR_FILE_CONTENTS_RESPONSE response = {0};
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    response.streamId = request->streamId;
    FCClipboardLog(@"file-request index=%u flags=0x%08x requested=%u", request->listIndex,
                   request->dwFlags, request->cbRequested);
    NSData *payload = [ctx->view clipboardFileContentsForRequest:request serverFlags:ctx->serverClipboardFlags];
    if (!payload) return clip->ClientFileContentsResponse(clip, &response);
    if (payload) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.cbRequested = (UINT32)payload.length;
        response.requestedData = payload.bytes;
    }
    FCClipboardLog(@"file-response success=%d bytes=%lu", payload != nil, (unsigned long)payload.length);
    return clip->ClientFileContentsResponse(clip, &response);
}
static UINT FCClipResponse(CliprdrClientContext *clip, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    FCContext *ctx = clip->custom; UINT32 length = response->common.dataLen;
    if (!ctx->view.clipboardActive || !(response->common.msgFlags & CB_RESPONSE_OK) || !response->requestedFormatData) return CHANNEL_RC_OK;
    const UINT32 format = ctx->view.clipboardRequestedFormat;
    if (format == ctx->fileGroupDescriptorFormat && ctx->view.clipboardFileTransferAllowed &&
        (ctx->serverClipboardFlags & CB_STREAM_FILECLIP_ENABLED) && length && length <= 1024 * 1024) {
        NSData *descriptors = [NSData dataWithBytes:response->requestedFormatData length:length];
        [ctx->view beginRemoteClipboardFileTransfer:descriptors clip:clip];
        return CHANNEL_RC_OK;
    }
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
static UINT FCClipRemoteFileContentsResponse(CliprdrClientContext *clip,
                                             const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
    return [((FCContext *)clip->custom)->view receiveRemoteClipboardFileResponse:clip response:response];
}
static UINT FCDisplayCaps(DispClientContext *disp, UINT32 count, UINT32 a, UINT32 b) { ((FCContext *)disp->custom)->displayReady = count > 0; return CHANNEL_RC_OK; }
static void FCChannelConnected(void *context, const ChannelConnectedEventArgs *event) {
    FCContext *ctx = context;
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *clip = event->pInterface; ctx->clipboard = clip; clip->custom = ctx;
        clip->ServerCapabilities = FCClipCapabilities; clip->MonitorReady = FCClipReady;
        clip->ServerFormatList = FCClipList; clip->ServerFormatListResponse = FCClipListResponse;
        clip->ServerFormatDataRequest = FCClipRequest; clip->ServerFormatDataResponse = FCClipResponse;
        clip->ServerFileContentsRequest = FCClipFileContentsRequest;
        clip->ServerFileContentsResponse = FCClipRemoteFileContentsResponse;
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
    rdpAutoDetect *autodetect = autodetect_get(instance->context);
    FCContext *ctx = (FCContext *)instance->context;
    if (autodetect) {
        ctx->originalRTTMeasureResponse = autodetect->RTTMeasureResponse;
        autodetect->RTTMeasureResponse = FCRTTMeasureResponse;
    }
    if (PubSub_SubscribeStateChanged(instance->context->pubSub, FCStateChanged) < 0) return FALSE;
    return PubSub_SubscribeChannelConnected(instance->context->pubSub, FCChannelConnected) >= 0 &&
           PubSub_SubscribeChannelDisconnected(instance->context->pubSub, FCChannelDisconnected) >= 0;
}
static BOOL FCRTTMeasureResponse(rdpAutoDetect *autodetect, RDP_TRANSPORT_TYPE transport,
                                 UINT16 sequenceNumber) {
    if (!autodetect || !autodetect->context) return FALSE;
    FCContext *ctx = (FCContext *)autodetect->context;
    if (ctx->originalRTTMeasureResponse &&
        !ctx->originalRTTMeasureResponse(autodetect, transport, sequenceNumber)) return FALSE;
    // FreeRDP updates this value from its RTT probe response before dispatching
    // the callback. Reading it here avoids racing the network thread from Swift.
    if (autodetect->netCharAverageRTT > 0) {
        FCView(autodetect->context).roundTripMilliseconds = autodetect->netCharAverageRTT;
    }
    return TRUE;
}
static BOOL FCPostConnect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;
    rdpContext *ctx = instance->context;
    FCRDPView *view = FCView(ctx);
    view.unicodeSupported = freerdp_settings_get_bool(ctx->settings, FreeRDP_UnicodeInput);
    // These settings are finalized by FreeRDP's capability exchange. Prefer
    // the most specific graphics codec when several compatible flags remain.
    if (freerdp_settings_get_bool(ctx->settings, FreeRDP_GfxH264)) view.negotiatedCodec = 1;
    else if (freerdp_settings_get_bool(ctx->settings, FreeRDP_RemoteFxCodec)) view.negotiatedCodec = 2;
    else if (freerdp_settings_get_bool(ctx->settings, FreeRDP_NSCodec)) view.negotiatedCodec = 3;
    else view.negotiatedCodec = 4;
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
uint32_t fc_rdp_abi(void) { return 8; }
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
void fc_rdp_secure_attention(void *view) { [(__bridge FCRDPView *)view sendSecureAttentionSequence]; }
int fc_rdp_status(void *view) { return ((__bridge FCRDPView *)view).connectionStatus; }
int fc_rdp_has_frame(void *view) { return ((__bridge FCRDPView *)view).hasReceivedFrame ? 1 : 0; }
uint32_t fc_rdp_error(void *view) { return ((__bridge FCRDPView *)view).errorCode; }
const char *fc_rdp_codec(void *view) {
    switch (((__bridge FCRDPView *)view).negotiatedCodec) {
        case 1: return "H.264";
        case 2: return "RemoteFX";
        case 3: return "NSCodec";
        case 4: return "Bitmap";
        default: return "";
    }
}

uint32_t fc_rdp_requested_protocols(void *view) {
    return ((__bridge FCRDPView *)view).requestedProtocols;
}

uint32_t fc_rdp_selected_protocol(void *view) {
    return ((__bridge FCRDPView *)view).selectedProtocol;
}
uint32_t fc_rdp_input_state(void *view) {
    return ((__bridge FCRDPView *)view).inputState;
}
uint32_t fc_rdp_round_trip_milliseconds(void *view) {
    return ((__bridge FCRDPView *)view).roundTripMilliseconds;
}

int fc_rdp_failure(void *view) {
    const UINT32 error = fc_rdp_error(view);
    // Licensing failures arrive as Error Info PDUs rather than individual
    // connection error constants. Keep the range tied to the FreeRDP header,
    // which is shared by the arm64 and x86_64 bundled runtimes.
    if (GET_FREERDP_ERROR_CLASS(error) == FREERDP_ERROR_ERRINFO_CLASS &&
        GET_FREERDP_ERROR_TYPE(error) >= ERRINFO_LICENSE_INTERNAL &&
        GET_FREERDP_ERROR_TYPE(error) <= ERRINFO_LICENSE_NO_REMOTE_CONNECTIONS) return 7;
    if (GET_FREERDP_ERROR_CLASS(error) == FREERDP_ERROR_ERRINFO_CLASS) {
        const UINT32 type = GET_FREERDP_ERROR_TYPE(error);
        // These FreeRDP Error Info codes specifically describe virtual-channel
        // framing, compression, or channel-ID failures. Other Error Info codes
        // remain generic because they can describe unrelated protocol errors.
        switch (type) {
            case ERRINFO_VCHANNEL_DATA_TOO_SHORT:
            case ERRINFO_VIRTUAL_CHANNEL_DECOMPRESSION:
            case ERRINFO_INVALID_VC_COMPRESSION_TYPE:
            case ERRINFO_INVALID_CHANNEL_ID:
            case ERRINFO_VCHANNELS_TOO_MANY:
                return 10;
        }
    }
    switch (error) {
        case FREERDP_ERROR_DNS_ERROR: case FREERDP_ERROR_DNS_NAME_NOT_FOUND: return 1;
        case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
            // Once TCP connected, a peer that closes while FreeRDP waits for
            // the RDP negotiation reply is reachable but is not completing
            // the RDP handshake. Report that separately from an unreachable
            // server; this also avoids sending users to check a closed port.
            return ((__bridge FCRDPView *)view).connectionStage == CONNECTION_STATE_NEGO ? 9 : 1;
        case FREERDP_ERROR_CONNECT_FAILED:
            // FreeRDP also uses CONNECT_FAILED when a connection stalls after
            // TCP connect while waiting for the server's RDP negotiation reply.
            // Preserve that distinction so a reachable listener is not reported
            // as an unreachable host.
            return ((__bridge FCRDPView *)view).connectionStage == CONNECTION_STATE_NEGO ? 9 : 1;
        case FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED: return 9;
        case FREERDP_ERROR_TLS_CONNECT_FAILED: return 2;
        case FREERDP_ERROR_AUTHENTICATION_FAILED: case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD: case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS: return 3;
        case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED: case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
        case FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED: case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION: case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
        case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED: case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED: return 4;
        case FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT: return 5;
        case FREERDP_ERROR_CONNECT_HYBRID_REQUIRED_BY_SERVER: return 6;
        case FREERDP_ERROR_LOGOFF_BY_USER: return 8;
        default: return 0;
    }
}
const char *fc_rdp_connection_phase(void *view) {
    if (!view) return NULL;
    const int stage = ((__bridge FCRDPView *)view).connectionStage;
    if (stage < CONNECTION_STATE_INITIAL || stage > CONNECTION_STATE_ACTIVE) return NULL;
    return freerdp_state_string((CONNECTION_STATE)stage);
}
