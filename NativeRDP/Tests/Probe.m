// Test executable only. It is never bundled with FjärrConnect.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "FCRDPView.h"
#include <freerdp/error.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

enum {
    FCProbeFileContentsSize = 0x00000001,
    FCProbeFileContentsRange = 0x00000002
};

// These selectors are deliberately private to the native view. Declaring them
// in this test-only category preserves compile-time checking without exposing
// them through the shipping C API.
@interface NSView (FCRDPClipboardProbe)
- (void)clipboardTick;
- (void)captureClipboardFromPasteboard:(NSPasteboard *)pasteboard;
- (NSArray<NSURL *> *)clipboardFileURLsFromPasteboard:(NSPasteboard *)pasteboard;
- (NSData *)fileDescriptorDataForURLs:(NSArray<NSURL *> *)urls;
- (NSData *)clipboardFileContentsForURL:(NSURL *)url expectedSize:(uint64_t)expectedSize
                                  flags:(uint32_t)flags offset:(uint64_t)offset requestedLength:(uint32_t)requestedLength;
- (NSData *)unicodeInputDataForText:(NSString *)text;
- (NSData *)DIBFromPasteboard:(NSPasteboard *)pasteboard;
- (void)receiveClipboardDIB:(NSData *)dib;
- (void)writeClipboardDIB:(NSData *)dib;
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
        if (!view || fc_rdp_abi() != 2) return 3;
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_FAILURE_CATEGORIES"] isEqualToString:@"1"]) {
            const struct { const char *name; UINT32 error; int category; } cases[] = {
                {"network", FREERDP_ERROR_CONNECT_FAILED, 1},
                {"certificate", FREERDP_ERROR_TLS_CONNECT_FAILED, 2},
                {"authentication", FREERDP_ERROR_CONNECT_WRONG_PASSWORD, 3},
                {"account", FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT, 4},
                {"activation", FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT, 5},
                {"nla", FREERDP_ERROR_CONNECT_HYBRID_REQUIRED_BY_SERVER, 6},
                {"licensing", MAKE_FREERDP_ERROR(ERRINFO, ERRINFO_LICENSE_NO_LICENSE_SERVER), 7},
                {"server-logoff", FREERDP_ERROR_LOGOFF_BY_USER, 8},
                {"unknown", UINT32_MAX, 0}
            };
            for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
                [view setValue:@(cases[index].error) forKey:@"errorCode"];
                if (fc_rdp_failure((__bridge void *)view) != cases[index].category) {
                    fprintf(stderr, "RDP error category mismatch: %s\n", cases[index].name);
                    return 11;
                }
            }
            puts("RDP failure categories passed: network, certificate, authentication, account, activation, NLA, licensing, server logoff, unknown.");
            return 0;
        }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_KEYBOARD_INPUT"] isEqualToString:@"1"]) {
            const uint16_t atAndSwedish[] = { CFSwapInt16HostToLittle(0x0040), CFSwapInt16HostToLittle(0x00E5), CFSwapInt16HostToLittle(0x00C5) };
            const uint16_t multilingual[] = { CFSwapInt16HostToLittle(0x20AC), CFSwapInt16HostToLittle(0x65E5) };
            const uint16_t supplementary[] = { CFSwapInt16HostToLittle(0xD83D), CFSwapInt16HostToLittle(0xDE42) };
            BOOL valid = [[(id)view unicodeInputDataForText:@"@åÅ"] isEqualToData:[NSData dataWithBytes:atAndSwedish length:sizeof(atAndSwedish)]] &&
                [[(id)view unicodeInputDataForText:@"€日"] isEqualToData:[NSData dataWithBytes:multilingual length:sizeof(multilingual)]] &&
                [[(id)view unicodeInputDataForText:@"🙂"] isEqualToData:[NSData dataWithBytes:supplementary length:sizeof(supplementary)]] &&
                [[(id)view unicodeInputDataForText:@""] length] == 0;
            return valid ? 0 : 10;
        }
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 1100, 750) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        window.title = @"FjärrConnect — embedded RDP integration test";
        window.contentView = view; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_CLIPBOARD_IMAGE"] isEqualToString:@"1"]) {
            // Exercise the native CLIPRDR image path without a server: AppKit image
            // -> CF_DIB -> AppKit image. This catches architecture-specific bitmap
            // and pasteboard regressions before a package is published.
            NSBitmapImageRep *source = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:NSBitmapFormatAlphaFirst bytesPerRow:8 bitsPerPixel:32];
            if (!source || !source.bitmapData) return 8;
            uint8_t *pixels = source.bitmapData;
            const uint8_t sample[] = { 255, 0, 0, 255, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255 };
            memcpy(pixels, sample, sizeof(sample));
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            [pasteboard clearContents];
            [pasteboard setData:[source representationUsingType:NSBitmapImageFileTypePNG properties:@{}] forType:NSPasteboardTypePNG];
            NSData *dib = [(id)view DIBFromPasteboard:pasteboard];
            [pasteboard clearContents];
            [(id)view writeClipboardDIB:dib];
            NSImage *roundTrip = [[NSImage alloc] initWithData:[pasteboard dataForType:NSPasteboardTypeTIFF]];
            return dib.length > 40 && roundTrip.size.width == 2 && roundTrip.size.height == 2 ? 0 : 8;
        }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_CLIPBOARD_FILES"] isEqualToString:@"1"]) {
            // Use a private pasteboard so a clipboard test never reads or replaces
            // the user's real clipboard. Only regular local files are exposed.
            NSFileManager *files = NSFileManager.defaultManager;
            NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                          isDirectory:YES];
            if (![files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]) return 9;
            NSURL *file = [directory URLByAppendingPathComponent:@"fixture-å.txt"];
            NSURL *emptyFile = [directory URLByAppendingPathComponent:@"empty.txt"];
            NSURL *folder = [directory URLByAppendingPathComponent:@"folder" isDirectory:YES];
            NSURL *link = [directory URLByAppendingPathComponent:@"link.txt"];
            NSError *error = nil;
            BOOL created = [[NSData dataWithBytes:"clipboard fixture" length:17] writeToURL:file options:0 error:&error] &&
                [[NSData data] writeToURL:emptyFile options:0 error:&error] &&
                [files createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:&error] &&
                [files createSymbolicLinkAtURL:link withDestinationURL:file error:&error];
            if (!created) { [files removeItemAtURL:directory error:nil]; return 9; }

            NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
            BOOL wrote = [pasteboard writeObjects:@[file, emptyFile, folder, link]];
            NSArray<NSURL *> *urls = wrote ? [(id)view clipboardFileURLsFromPasteboard:pasteboard] : @[];
            NSData *descriptors = [(id)view fileDescriptorDataForURLs:urls];
            NSData *unicodeName = [@"fixture-å.txt" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
            BOOL valid = urls.count == 2 && [urls.firstObject isEqual:file] && [urls.lastObject isEqual:emptyFile] &&
                descriptors.length >= 4 + unicodeName.length &&
                memcmp(descriptors.bytes, "\x02\x00\x00\x00", 4) == 0 &&
                [descriptors rangeOfData:unicodeName options:0 range:NSMakeRange(0, descriptors.length)].location != NSNotFound;
            fprintf(stderr, "file-manifest count=%lu order=%d descriptors=%lu unicode=%d\n",
                    (unsigned long)urls.count,
                    urls.count == 2 && [urls.firstObject isEqual:file] && [urls.lastObject isEqual:emptyFile],
                    (unsigned long)descriptors.length,
                    [descriptors rangeOfData:unicodeName options:0 range:NSMakeRange(0, descriptors.length)].location != NSNotFound);

            const uint64_t fileSize = 17;
            NSData *size = [(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                                                           flags:FCProbeFileContentsSize offset:0 requestedLength:0];
            uint64_t decodedSize = 0;
            if (size.length == sizeof(decodedSize)) memcpy(&decodedSize, size.bytes, sizeof(decodedSize));
            NSData *range = [(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                                                            flags:FCProbeFileContentsRange offset:4 requestedLength:6];
            NSData *endRange = [(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                                                               flags:FCProbeFileContentsRange offset:fileSize requestedLength:8];
            NSData *emptySize = [(id)view clipboardFileContentsForURL:emptyFile expectedSize:0
                                                                flags:FCProbeFileContentsSize offset:0 requestedLength:0];
            NSData *emptyRange = [(id)view clipboardFileContentsForURL:emptyFile expectedSize:0
                                                                 flags:FCProbeFileContentsRange offset:0 requestedLength:0];
            const BOOL invalidFlagsRejected = ![(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                flags:FCProbeFileContentsSize | FCProbeFileContentsRange offset:0 requestedLength:8];
            const BOOL invalidOffsetRejected = ![(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                flags:FCProbeFileContentsRange offset:fileSize + 1 requestedLength:1];
            const BOOL zeroLengthRejected = ![(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                flags:FCProbeFileContentsRange offset:0 requestedLength:0];
            const BOOL oversizedReadRejected = ![(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                flags:FCProbeFileContentsRange offset:0 requestedLength:4 * 1024 * 1024 + 1];
            const BOOL wrongSizeRejected = ![(id)view clipboardFileContentsForURL:file expectedSize:fileSize + 1
                flags:FCProbeFileContentsRange offset:0 requestedLength:1];
            const BOOL folderRejected = ![(id)view clipboardFileContentsForURL:folder expectedSize:0
                flags:FCProbeFileContentsSize offset:0 requestedLength:0];
            const BOOL symlinkRejected = ![(id)view clipboardFileContentsForURL:link expectedSize:fileSize
                flags:FCProbeFileContentsSize offset:0 requestedLength:0];
            valid = valid && decodedSize == fileSize && range &&
                [range isEqualToData:[@"board " dataUsingEncoding:NSUTF8StringEncoding]] && endRange.length == 0 &&
                emptySize.length == sizeof(uint64_t) && emptyRange && emptyRange.length == 0 &&
                invalidFlagsRejected && invalidOffsetRejected && zeroLengthRejected && oversizedReadRejected &&
                wrongSizeRejected && folderRejected && symlinkRejected;
            fprintf(stderr, "file-ranges size=%d range=%d end=%d empty-size=%d empty-range=%d invalid=%d/%d/%d/%d/%d/%d/%d\n",
                    decodedSize == fileSize, range != nil && [range isEqualToData:[@"board " dataUsingEncoding:NSUTF8StringEncoding]],
                    endRange.length == 0, emptySize.length == sizeof(uint64_t), emptyRange != nil && emptyRange.length == 0,
                    invalidFlagsRejected, invalidOffsetRejected, zeroLengthRejected, oversizedReadRejected,
                    wrongSizeRejected, folderRejected, symlinkRejected);

            // Replacing a file with a different length invalidates the captured manifest.
            int fileDescriptor = open(file.fileSystemRepresentation, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC);
            const char changed = '!';
            const BOOL changedFile = fileDescriptor >= 0 && write(fileDescriptor, &changed, sizeof(changed)) == sizeof(changed);
            if (fileDescriptor >= 0) close(fileDescriptor);
            const BOOL staleManifestRejected = ![(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                flags:FCProbeFileContentsSize offset:0 requestedLength:0];
            fprintf(stderr, "file-mutation changed=%d stale-manifest-rejected=%d\n", changedFile, staleManifestRejected);
            valid = valid && changedFile && staleManifestRejected;
            [(id)view captureClipboardFromPasteboard:pasteboard];
            NSData *text = [view valueForKey:@"clipboardText"];
            fprintf(stderr, "file-manifest-after-mutation files=%lu text-present=%d\n",
                    (unsigned long)[[view valueForKey:@"clipboardFiles"] count], text != nil);
            valid = valid && text == nil && [[view valueForKey:@"clipboardFiles"] count] == 2;
            [pasteboard releaseGlobally];
            [files removeItemAtURL:directory error:nil];
            return valid ? 0 : 9;
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
