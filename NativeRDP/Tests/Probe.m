// Test executable only. It is never bundled with FjärrConnect.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "FCRDPView.h"
#include <string.h>

// These selectors are deliberately private to the native view. Declaring them
// in this test-only category preserves compile-time checking without exposing
// them through the shipping C API.
@interface NSView (FCRDPClipboardProbe)
- (void)clipboardTick;
- (void)receiveClipboardDIB:(NSData *)dib;
@end

static NSString *expectedFingerprint;
static NSString *expectedTitle;
static BOOL sawCertificate;
static BOOL rejectCertificate;
static BOOL incorrectCertificate;
static NSModalResponse inspectCertificate(id self, SEL command) {
    NSAlert *alert = self;
    sawCertificate = YES;
    BOOL valid = expectedFingerprint.length &&
        [alert.informativeText localizedCaseInsensitiveContainsString:expectedFingerprint] &&
        [alert.messageText isEqualToString:expectedTitle] && alert.buttons.count == 3;
    if (!valid) { incorrectCertificate = YES; return NSAlertFirstButtonReturn; }
    return rejectCertificate ? NSAlertFirstButtonReturn : NSAlertSecondButtonReturn;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        expectedFingerprint = NSProcessInfo.processInfo.environment[@"FC_TEST_CERT_FINGERPRINT"];
        expectedTitle = NSProcessInfo.processInfo.environment[@"FC_TEST_CERT_TITLE"];
        rejectCertificate = [NSProcessInfo.processInfo.environment[@"FC_TEST_CERT_REJECT"] isEqualToString:@"1"];
        if (expectedFingerprint) method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)inspectCertificate);
        NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        NSString *arguments = [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding];
        NSData *translations = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSString *json = [[NSString alloc] initWithData:translations encoding:NSUTF8StringEncoding];
        NSView *view = (__bridge_transfer NSView *)fc_rdp_create(arguments.UTF8String, json.UTF8String);
        if (!view || fc_rdp_abi() != 1) return 3;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 1100, 750) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        window.title = @"FjärrConnect — embedded RDP integration test";
        window.contentView = view; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_CLIPBOARD_IMAGE"] isEqualToString:@"1"]) {
            // Exercise the native CLIPRDR image path without a server: AppKit image
            // -> CF_DIB -> AppKit image. This catches architecture-specific bitmap
            // and pasteboard regressions before a package is published.
            [view setValue:@YES forKey:@"clipboardAllowed"];
            fc_rdp_set_active((__bridge void *)view, 1);
            [view setValue:@2 forKey:@"connectionStatus"];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            NSBitmapImageRep *source = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaFirst bytesPerRow:8 bitsPerPixel:32];
            if (!source || !source.bitmapData) return 8;
            uint8_t *pixels = source.bitmapData;
            const uint8_t sample[] = { 255, 0, 0, 255, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255 };
            memcpy(pixels, sample, sizeof(sample));
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            [pasteboard clearContents];
            [pasteboard setData:[source representationUsingType:NSBitmapImageFileTypePNG properties:@{}] forType:NSPasteboardTypePNG];
            [(id)view clipboardTick];
            NSData *dib = [view valueForKey:@"clipboardImage"];
            [pasteboard clearContents];
            [(id)view receiveClipboardDIB:dib];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            NSImage *roundTrip = [[NSImage alloc] initWithData:[pasteboard dataForType:NSPasteboardTypeTIFF]];
            return dib.length > 40 && roundTrip.size.width == 2 && roundTrip.size.height == 2 ? 0 : 8;
        }
        [window makeFirstResponder:view]; fc_rdp_set_active((__bridge void *)view, 1); fc_rdp_start((__bridge void *)view);
        NSTimeInterval stableSeconds = MAX(6, MIN(120, [NSProcessInfo.processInfo.environment[@"FC_TEST_STABLE_SECONDS"] doubleValue]));
        NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + MAX(stableSeconds + 25, [NSProcessInfo.processInfo.environment[@"FC_TEST_LONG"] isEqualToString:@"1"] ? 65 : 25);
        NSTimeInterval connectedAt = 0;
        BOOL resize = NO;
        int result = 4;
        while (NSDate.timeIntervalSinceReferenceDate < deadline) {
            @autoreleasepool {
                NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02] inMode:NSDefaultRunLoopMode dequeue:YES];
                if (event) [NSApp sendEvent:event];
                [NSApp updateWindows];
                int status = fc_rdp_status((__bridge void *)view);
                if (status == 3) { result = rejectCertificate && sawCertificate && !incorrectCertificate ? 0 : 5; break; }
                if (status == 2 && !connectedAt) connectedAt = NSDate.timeIntervalSinceReferenceDate;
                if (connectedAt && !resize && NSDate.timeIntervalSinceReferenceDate - connectedAt > 2) {
                    [window setContentSize:NSMakeSize(950, 660)]; resize = YES;
                    // Send a harmless shell command to the disposable xterm fixture.
                    if ([NSProcessInfo.processInfo.environment[@"FC_TEST_INPUT"] isEqualToString:@"1"]) {
                        NSPoint point = [view convertPoint:NSMakePoint(140, 140) toView:nil];
                        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
                        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:0];
                        [view mouseDown:down]; [view mouseUp:up];
                        const unsigned short keys[] = {14,8,4,31,49,3,38,0,15,15,36};
                        NSArray *characters = @[@"e",@"c",@"h",@"o",@" ",@"f",@"j",@"a",@"r",@"r",@"\r"];
                        for (NSUInteger i = 0; i < characters.count; i++) {
                            for (int release = 0; release < 2; release++) {
                                NSEvent *key = [NSEvent keyEventWithType:release ? NSEventTypeKeyUp : NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:characters[i] charactersIgnoringModifiers:characters[i] isARepeat:NO keyCode:keys[i]];
                                [NSApp postEvent:key atStart:NO];
                            }
                        }
                    }
                }
                if (connectedAt && NSDate.timeIntervalSinceReferenceDate - connectedAt > stableSeconds) {
                    // A negotiated connection alone is not a working desktop. This
                    // private test view must also receive a rendered remote frame.
                    NSImage *remoteFrame = [view valueForKey:@"_frame"];
                    if (!remoteFrame || remoteFrame.size.width <= 0 || remoteFrame.size.height <= 0) { result = 7; break; }
                    NSBitmapImageRep *image = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                    [view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
                    NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    BOOL saved = [png writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
                    result = incorrectCertificate ? 6 : (saved ? 0 : 7); break;
                }
            }
        }
        fc_rdp_stop((__bridge void *)view);
        NSTimeInterval stopDeadline = NSDate.timeIntervalSinceReferenceDate + 5;
        while (fc_rdp_status((__bridge void *)view) != 3 && NSDate.timeIntervalSinceReferenceDate < stopDeadline)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        printf("result=%d certificate=%d rejected=%d status=%d error=0x%08x stage=%d windows=%lu\n", result, sawCertificate, rejectCertificate, fc_rdp_status((__bridge void *)view), fc_rdp_error((__bridge void *)view), [[view valueForKey:@"connectionStage"] intValue], (unsigned long)NSApp.windows.count);
        return result;
    }
}
