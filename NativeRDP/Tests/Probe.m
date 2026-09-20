// Test executable only. It is never bundled with FjärrConnect.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "FCRDPView.h"
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
        [window makeFirstResponder:view]; fc_rdp_set_active((__bridge void *)view, 1); fc_rdp_start((__bridge void *)view);
        NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + ([NSProcessInfo.processInfo.environment[@"FC_TEST_LONG"] isEqualToString:@"1"] ? 65 : 25);
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
                if (connectedAt && NSDate.timeIntervalSinceReferenceDate - connectedAt > 6) {
                    NSBitmapImageRep *image = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                    [view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
                    NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    [png writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
                    result = incorrectCertificate ? 6 : 0; break;
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
