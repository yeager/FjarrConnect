// Test executable only. It is never bundled with FjärrConnect.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "FCRDPView.h"
#import "FCKeyboardSequences.h"
#include <freerdp/error.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/settings_types.h>
#include <winpr/shell.h>
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
- (void)publishFrame:(rdpGdi *)gdi;
- (void)clipboardTick;
- (void)setSessionActive:(BOOL)active pasteboard:(NSPasteboard *)pasteboard;
- (void)setClipboardActive:(BOOL)active pasteboard:(NSPasteboard *)pasteboard;
- (void)captureClipboardFromPasteboard:(NSPasteboard *)pasteboard;
- (NSArray<NSURL *> *)clipboardFileURLsFromPasteboard:(NSPasteboard *)pasteboard;
- (NSData *)fileDescriptorDataForURLs:(NSArray<NSURL *> *)urls;
- (NSData *)clipboardFileDescriptorsForRequestFormat:(UINT32)requestedFormat
                                      registeredFormat:(UINT32)registeredFormat
                                            serverFlags:(UINT32)serverFlags;
- (NSData *)clipboardFileContentsForURL:(NSURL *)url expectedSize:(uint64_t)expectedSize
                                  flags:(uint32_t)flags offset:(uint64_t)offset requestedLength:(uint32_t)requestedLength;
- (NSData *)clipboardFileContentsForRequest:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request
                               serverFlags:(UINT32)serverFlags;
- (NSData *)unicodeInputDataForText:(NSString *)text;
- (DWORD)scancode:(unsigned short)key;
- (NSData *)DIBFromPasteboard:(NSPasteboard *)pasteboard;
- (void)receiveClipboardDIB:(NSData *)dib;
- (void)writeClipboardDIB:(NSData *)dib;
- (BOOL)beginRemoteClipboardFileTransfer:(NSData *)data clip:(CliprdrClientContext *)clip;
- (UINT)receiveRemoteClipboardFileResponse:(CliprdrClientContext *)clip
                                  response:(const CLIPRDR_FILE_CONTENTS_RESPONSE *)response;
- (UINT32)clipboardFeatureMaskForFileTransfer:(BOOL)enabled;
@end

static NSString *expectedFingerprint;
static NSString *expectedTitle;
static BOOL sawCertificate;
static BOOL rejectCertificate;
static BOOL incorrectCertificate;
static CLIPRDR_FILE_CONTENTS_REQUEST capturedRemoteFileRequest;
static NSUInteger remoteFileRequestCount;
static UINT captureRemoteFileRequest(CliprdrClientContext *clip, const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
    if (!request) return 1;
    capturedRemoteFileRequest = *request;
    remoteFileRequestCount++;
    return CHANNEL_RC_OK;
}
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
        if (!view) { fputs("fc_rdp_create returned NULL\n", stderr); return 3; }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_RDP_NEGOTIATION"] isEqualToString:@"1"]) {
            // A password-free live probe isolates FreeRDP negotiation from
            // authentication. Print only state enums and protocol flags.
            fc_rdp_start((__bridge void *)view);
            int status = 0;
            for (NSUInteger attempt = 0; attempt < 200; attempt++) {
                status = fc_rdp_status((__bridge void *)view);
                if (status == 2 || status == 3) break;
                usleep(100000);
            }
            const char *phase = fc_rdp_connection_phase((__bridge void *)view);
            printf("RDP negotiation probe: status=%d phase=%s failure=%d error=0x%08x requested=0x%08x selected=0x%08x\n",
                   status, phase ?: "unavailable", fc_rdp_failure((__bridge void *)view),
                   fc_rdp_error((__bridge void *)view),
                   fc_rdp_requested_protocols((__bridge void *)view), fc_rdp_selected_protocol((__bridge void *)view));
            fc_rdp_stop((__bridge void *)view);
            return status == 3 && phase ? 0 : 25;
        }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_CLIPBOARD_FILE_OPTION"] isEqualToString:@"1"]) {
            const BOOL expected = [NSProcessInfo.processInfo.environment[@"FC_TEST_CLIPBOARD_FILE_OPTION_EXPECTED"] isEqualToString:@"1"];
            const BOOL requested = [[view valueForKey:@"clipboardFileTransferRequested"] boolValue];
            const BOOL markerRemoved = ![[view valueForKey:@"arguments"] containsString:@"/fc:clipboard-files"];
            const UINT32 clipboardFeatures = [(id)view clipboardFeatureMaskForFileTransfer:requested];
            const UINT32 expectedFeatures = CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_REMOTE_TO_LOCAL |
                (expected ? CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES | CLIPRDR_FLAG_REMOTE_TO_LOCAL_FILES : 0);
            printf("RDP file-clipboard opt-in accepted=%d removed-before-FreeRDP=%d bidirectional=%d\n",
                   requested, markerRemoved,
                   (clipboardFeatures & (CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES | CLIPRDR_FLAG_REMOTE_TO_LOCAL_FILES)) ==
                    (expected ? CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES | CLIPRDR_FLAG_REMOTE_TO_LOCAL_FILES : 0));
            return requested == expected && markerRemoved &&
                clipboardFeatures == expectedFeatures ? 0 : 19;
        }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_RDP_FILE_CLIPBOARD_INBOUND"] isEqualToString:@"1"]) {
            const uint64_t fileSize = 4ULL * 1024 * 1024 + 9;
            FILEDESCRIPTORW descriptor = {0};
            descriptor.dwFlags = FD_FILESIZE;
            descriptor.nFileSizeLow = (DWORD)fileSize;
            const unichar name[] = { 'f', 'i', 'x', 't', 'u', 'r', 'e', '.', 'b', 'i', 'n' };
            memcpy(descriptor.cFileName, name, sizeof(name));
            BYTE *encoded = NULL;
            UINT32 encodedLength = 0;
            if (cliprdr_serialize_file_list(&descriptor, 1, &encoded, &encodedLength) != CHANNEL_RC_OK || !encoded) return 26;
            NSData *manifest = [NSData dataWithBytes:encoded length:encodedLength];
            free(encoded);

            [view setValue:@YES forKey:@"clipboardFileTransferAllowed"];
            [view setValue:@YES forKey:@"sessionActive"];
            [view setValue:@NO forKey:@"cancelled"];
            [(id)view setClipboardActive:YES pasteboard:NSPasteboard.generalPasteboard];
            CliprdrClientContext clip = {0};
            clip.ClientFileContentsRequest = captureRemoteFileRequest;
            remoteFileRequestCount = 0;
            BOOL accepted = [(id)view beginRemoteClipboardFileTransfer:manifest clip:&clip];
            id transfer = [view valueForKey:@"remoteClipboardTransfer"];
            NSArray *transferFiles = [transfer valueForKey:@"files"];
            NSURL *receivedFile = [transferFiles.firstObject valueForKey:@"url"];
            BOOL firstRequestValid = accepted && remoteFileRequestCount == 1 &&
                capturedRemoteFileRequest.dwFlags == FILECONTENTS_RANGE &&
                capturedRemoteFileRequest.listIndex == 0 && capturedRemoteFileRequest.nPositionLow == 0 &&
                capturedRemoteFileRequest.cbRequested == 4 * 1024 * 1024;

            NSMutableData *firstChunk = [NSMutableData dataWithLength:capturedRemoteFileRequest.cbRequested];
            memset(firstChunk.mutableBytes, 'A', firstChunk.length);
            CLIPRDR_FILE_CONTENTS_RESPONSE firstResponse = {0};
            firstResponse.common.msgFlags = CB_RESPONSE_OK;
            firstResponse.streamId = capturedRemoteFileRequest.streamId;
            firstResponse.cbRequested = (UINT32)firstChunk.length;
            firstResponse.requestedData = firstChunk.bytes;
            [(id)view receiveRemoteClipboardFileResponse:&clip response:&firstResponse];
            BOOL secondRequestValid = remoteFileRequestCount == 2 &&
                capturedRemoteFileRequest.nPositionLow == 4 * 1024 * 1024 &&
                capturedRemoteFileRequest.cbRequested == 9;

            NSData *lastChunk = [@"BCDEFGHIJ" dataUsingEncoding:NSUTF8StringEncoding];
            CLIPRDR_FILE_CONTENTS_RESPONSE lastResponse = {0};
            lastResponse.common.msgFlags = CB_RESPONSE_OK;
            lastResponse.streamId = capturedRemoteFileRequest.streamId;
            lastResponse.cbRequested = (UINT32)lastChunk.length;
            lastResponse.requestedData = lastChunk.bytes;
            [(id)view receiveRemoteClipboardFileResponse:&clip response:&lastResponse];

            NSData *received = receivedFile ? [NSData dataWithContentsOfURL:receivedFile] : nil;
            const BOOL contentValid = received.length == fileSize &&
                ((const BYTE *)received.bytes)[0] == 'A' &&
                memcmp((const BYTE *)received.bytes + 4 * 1024 * 1024, "BCDEFGHIJ", 9) == 0;
            const BOOL completed = [view valueForKey:@"remoteClipboardTransfer"] == nil;
            FILEDESCRIPTORW unsafeDescriptor = {0};
            unsafeDescriptor.dwFlags = FD_FILESIZE;
            const unichar unsafeName[] = { '.', '.', '/', 'x' };
            memcpy(unsafeDescriptor.cFileName, unsafeName, sizeof(unsafeName));
            BYTE *unsafeBytes = NULL;
            UINT32 unsafeLength = 0;
            BOOL unsafeRejected = cliprdr_serialize_file_list(&unsafeDescriptor, 1,
                                                               &unsafeBytes, &unsafeLength) == CHANNEL_RC_OK &&
                unsafeBytes && ![(id)view beginRemoteClipboardFileTransfer:
                    [NSData dataWithBytes:unsafeBytes length:unsafeLength] clip:&clip];
            free(unsafeBytes);

            FILEDESCRIPTORW oversizedDescriptor = {0};
            oversizedDescriptor.dwFlags = FD_FILESIZE;
            oversizedDescriptor.nFileSizeLow = 256u * 1024u * 1024u + 1u;
            const unichar safeName[] = { 'l', 'a', 'r', 'g', 'e', '.', 'b', 'i', 'n' };
            memcpy(oversizedDescriptor.cFileName, safeName, sizeof(safeName));
            BYTE *oversizedBytes = NULL;
            UINT32 oversizedLength = 0;
            BOOL oversizedRejected = cliprdr_serialize_file_list(&oversizedDescriptor, 1,
                                                                  &oversizedBytes, &oversizedLength) == CHANNEL_RC_OK &&
                oversizedBytes && ![(id)view beginRemoteClipboardFileTransfer:
                    [NSData dataWithBytes:oversizedBytes length:oversizedLength] clip:&clip];
            free(oversizedBytes);
            fprintf(stderr, "RDP inbound file clipboard accepted=%d chunks=%lu ranges=%d/%d content=%d complete=%d\n",
                    accepted, (unsigned long)remoteFileRequestCount, firstRequestValid, secondRequestValid,
                    contentValid, completed);
            if (receivedFile) [[NSFileManager defaultManager] removeItemAtURL:receivedFile.URLByDeletingLastPathComponent error:nil];
            fprintf(stderr, "RDP inbound file clipboard rejected unsafe-name=%d oversized=%d\n",
                    unsafeRejected, oversizedRejected);
            return accepted && firstRequestValid && secondRequestValid && contentValid && completed &&
                unsafeRejected && oversizedRejected ? 0 : 26;
        }
        const uint32_t abi = fc_rdp_abi();
        if (abi != 7) { fprintf(stderr, "Unexpected RDP ABI: %u\n", abi); return 3; }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_SECURITY_PROTOCOLS"] isEqualToString:@"1"]) {
            [view setValue:@(0x0B) forKey:@"requestedProtocols"];
            [view setValue:@(0x08) forKey:@"selectedProtocol"];
            if (fc_rdp_requested_protocols((__bridge void *)view) != 0x0B ||
                fc_rdp_selected_protocol((__bridge void *)view) != 0x08) return 24;
            puts("RDP security negotiation flags are exposed without backend logs.");
            return 0;
        }
        if (fc_rdp_has_frame((__bridge void *)view) != 0) {
            fputs("An RDP view reported a frame before receiving desktop pixels\n", stderr); return 20;
        }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_CONNECTION_PHASE"] isEqualToString:@"1"]) {
            const char *initial = fc_rdp_connection_phase((__bridge void *)view);
            if (!initial || strcmp(initial, "CONNECTION_STATE_INITIAL") != 0) return 22;
            [view setValue:@(CONNECTION_STATE_NEGO) forKey:@"connectionStage"];
            const char *phase = fc_rdp_connection_phase((__bridge void *)view);
            if (!phase || strcmp(phase, "CONNECTION_STATE_NEGO") != 0) return 23;
            puts("RDP connection phase safely reports CONNECTION_STATE_NEGO.");
            return 0;
        }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_FRAME_RECEIVED"] isEqualToString:@"1"]) {
            uint8_t pixels[16] = { 0, 0, 255, 0, 0, 255, 0, 0,
                                   255, 0, 0, 0, 255, 255, 255, 0 };
            rdpGdi frame = {0};
            frame.primary_buffer = pixels; frame.width = 2; frame.height = 2; frame.stride = 8;
            [(id)view publishFrame:&frame];
            if (fc_rdp_has_frame((__bridge void *)view) != 1) {
                fputs("A valid RDP framebuffer was not reported to the session\n", stderr); return 21;
            }
            puts("First desktop frame detected; the waiting overlay can be removed.");
            return 0;
        }
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_RDP_SAS"] isEqualToString:@"1"]) {
            const uint32_t control = [(id)view scancode:59];
            const uint32_t alt = [(id)view scancode:58];
            const uint32_t rawEnd = [(id)view scancode:119];
            const uint32_t end = FCMakeExtendedScanCode(rawEnd);
            FCKeyboardStroke strokes[6];
            if (control != 0x1D || alt != 0x38 || end != 0x14F ||
                FCMakeSecureAttentionSequence(control, alt, end, strokes) != 6 ||
                strokes[0].scancode != control || !strokes[0].down ||
                strokes[1].scancode != alt || !strokes[1].down ||
                strokes[2].scancode != end || !strokes[2].down ||
                strokes[3].scancode != end || strokes[3].down ||
                strokes[4].scancode != alt || strokes[4].down ||
                strokes[5].scancode != control || strokes[5].down) return 18;
            printf("Ctrl+Alt+End scan codes resolved and released in order: %u,%u,%u (raw End %u).\n",
                   control, alt, end, rawEnd);
            return 0;
        }
        NSWindow *window = nil;
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_FAILURE_CATEGORIES"] isEqualToString:@"1"]) {
            const struct { const char *name; UINT32 error; int stage; int category; } cases[] = {
                {"network", FREERDP_ERROR_CONNECT_FAILED, CONNECTION_STATE_INITIAL, 1},
                {"transport", FREERDP_ERROR_CONNECT_TRANSPORT_FAILED, CONNECTION_STATE_INITIAL, 1},
                {"negotiation-timeout", FREERDP_ERROR_CONNECT_FAILED, CONNECTION_STATE_NEGO, 9},
                {"negotiation-transport", FREERDP_ERROR_CONNECT_TRANSPORT_FAILED, CONNECTION_STATE_NEGO, 9},
                {"security-negotiation", FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED, CONNECTION_STATE_NEGO, 9},
                {"certificate", FREERDP_ERROR_TLS_CONNECT_FAILED, CONNECTION_STATE_NEGO, 2},
                {"authentication", FREERDP_ERROR_CONNECT_WRONG_PASSWORD, CONNECTION_STATE_NLA, 3},
                {"account", FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT, CONNECTION_STATE_NLA, 4},
                {"activation", FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT, CONNECTION_STATE_ACTIVE, 5},
                {"nla", FREERDP_ERROR_CONNECT_HYBRID_REQUIRED_BY_SERVER, CONNECTION_STATE_NEGO, 6},
                {"licensing", MAKE_FREERDP_ERROR(ERRINFO, ERRINFO_LICENSE_NO_LICENSE_SERVER), CONNECTION_STATE_LICENSING, 7},
                {"server-logoff", FREERDP_ERROR_LOGOFF_BY_USER, CONNECTION_STATE_ACTIVE, 8},
                {"unknown", UINT32_MAX, CONNECTION_STATE_INITIAL, 0}
            };
            for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
                [view setValue:@(cases[index].error) forKey:@"errorCode"];
                [view setValue:@(cases[index].stage) forKey:@"connectionStage"];
                const int actualCategory = fc_rdp_failure((__bridge void *)view);
                if (actualCategory != cases[index].category) {
                    fprintf(stderr, "RDP error category mismatch: %s expected=%d actual=%d error=0x%08x stage=%d expected-stage=%d\n",
                            cases[index].name, cases[index].category, actualCategory,
                            fc_rdp_error((__bridge void *)view), [[view valueForKey:@"connectionStage"] intValue], cases[index].stage);
                    return 11;
                }
            }
            puts("RDP failure categories passed: network, negotiation transport, security negotiation, certificate, authentication, account, activation, NLA, licensing, server logoff, unknown.");
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
        if ([NSProcessInfo.processInfo.environment[@"FC_TEST_CLIPBOARD_ACTIVATION"] isEqualToString:@"1"]) {
            window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 1100, 750) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
            window.title = @"FjärrConnect — clipboard activation test";
            window.contentView = view; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
            // A file copied outside FjarrConnect becomes available only to the
            // selected RDP session; inactive sessions must clear their copy.
            [view setValue:@YES forKey:@"clipboardAllowed"];
            [view setValue:@2 forKey:@"connectionStatus"];
            NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"FjarrConnectClipboard-%@.txt", NSUUID.UUID.UUIDString]]];
            if (![[@"activation fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:file atomically:YES]) return 12;
            NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
            BOOL wrote = [pasteboard writeObjects:@[file]];
            [(id)view setSessionActive:NO pasteboard:pasteboard];
            BOOL inactiveCleared = [[view valueForKeyPath:@"clipboardFileSnapshot.files"] count] == 0;
            fprintf(stderr, "clipboard-activation context app=%d key=%d allowed=%d status=%d wrote=%d\n",
                    NSApp.isActive, window.isKeyWindow,
                    [[view valueForKey:@"clipboardAllowed"] boolValue],
                    [[view valueForKey:@"connectionStatus"] intValue], wrote);
            [(id)view setSessionActive:YES pasteboard:pasteboard];
            [(id)view setClipboardActive:YES pasteboard:pasteboard];
            BOOL activeCaptured = [[view valueForKeyPath:@"clipboardFileSnapshot.files"] isEqualToArray:@[file]] &&
                [view valueForKeyPath:@"clipboardFileSnapshot.descriptors"] != nil;
            [(id)view setSessionActive:NO pasteboard:pasteboard];
            BOOL inactiveClearedAgain = [[view valueForKeyPath:@"clipboardFileSnapshot.files"] count] == 0 &&
                ![[view valueForKey:@"clipboardActive"] boolValue];
            [pasteboard releaseGlobally]; [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
            BOOL valid = wrote && inactiveCleared && activeCaptured && inactiveClearedAgain;
            fprintf(stderr, "clipboard-activation captured=%d inactive-cleared=%d\n", activeCaptured,
                    inactiveCleared && inactiveClearedAgain);
            return valid ? 0 : 12;
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
            NSURL *alternateFile = [directory URLByAppendingPathComponent:@"alternate.txt"];
            NSURL *folder = [directory URLByAppendingPathComponent:@"folder" isDirectory:YES];
            NSURL *link = [directory URLByAppendingPathComponent:@"link.txt"];
            NSError *error = nil;
            BOOL created = [[NSData dataWithBytes:"clipboard fixture" length:17] writeToURL:file options:0 error:&error] &&
                [[NSData data] writeToURL:emptyFile options:0 error:&error] &&
                [[@"alternate fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:alternateFile options:0 error:&error] &&
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

            // Feed realistic FILECONTENTS_SIZE and RANGE requests through the
            // same handler used by the CLIPRDR network callback.
            [view setValue:@YES forKey:@"clipboardActive"];
            [view setValue:@YES forKey:@"clipboardFileTransferAllowed"];
            const UINT32 fileGroupFormat = 0xC123;
            CLIPRDR_FILE_CONTENTS_REQUEST sizeRequest = {0};
            sizeRequest.listIndex = 0; sizeRequest.dwFlags = FILECONTENTS_SIZE; sizeRequest.cbRequested = sizeof(uint64_t);
            NSData *requestedDescriptors = [(id)view clipboardFileDescriptorsForRequestFormat:fileGroupFormat
                registeredFormat:fileGroupFormat serverFlags:CB_STREAM_FILECLIP_ENABLED];
            const BOOL descriptorRequestGates = [requestedDescriptors isEqualToData:descriptors] &&
                ![(id)view clipboardFileDescriptorsForRequestFormat:fileGroupFormat registeredFormat:0
                    serverFlags:CB_STREAM_FILECLIP_ENABLED] &&
                ![(id)view clipboardFileDescriptorsForRequestFormat:fileGroupFormat registeredFormat:fileGroupFormat
                    serverFlags:0];
            const BOOL rejectedManifestClearedOldSnapshot =
                [view valueForKey:@"clipboardFileTransferSnapshot"] == nil &&
                ![(id)view clipboardFileContentsForRequest:&sizeRequest serverFlags:CB_STREAM_FILECLIP_ENABLED];
            NSData *refreshedDescriptors = [(id)view clipboardFileDescriptorsForRequestFormat:fileGroupFormat
                registeredFormat:fileGroupFormat serverFlags:CB_STREAM_FILECLIP_ENABLED];
            NSData *protocolSize = [(id)view clipboardFileContentsForRequest:&sizeRequest
                                                                  serverFlags:CB_STREAM_FILECLIP_ENABLED];
            CLIPRDR_FILE_CONTENTS_REQUEST rangeRequest = {0};
            rangeRequest.listIndex = 0; rangeRequest.dwFlags = FILECONTENTS_RANGE;
            rangeRequest.nPositionLow = 4; rangeRequest.cbRequested = 6;
            NSData *protocolRange = [(id)view clipboardFileContentsForRequest:&rangeRequest
                                                                   serverFlags:CB_STREAM_FILECLIP_ENABLED];
            CLIPRDR_FILE_CONTENTS_REQUEST invalidSizeRequest = sizeRequest;
            invalidSizeRequest.cbRequested = 7;
            CLIPRDR_FILE_CONTENTS_REQUEST invalidIndexRequest = rangeRequest;
            invalidIndexRequest.listIndex = 2;
            const BOOL invalidProtocolRequestsRejected =
                ![(id)view clipboardFileContentsForRequest:&invalidSizeRequest serverFlags:CB_STREAM_FILECLIP_ENABLED] &&
                ![(id)view clipboardFileContentsForRequest:&invalidIndexRequest serverFlags:CB_STREAM_FILECLIP_ENABLED] &&
                ![(id)view clipboardFileContentsForRequest:&rangeRequest serverFlags:0];
            uint64_t protocolSizeValue = 0;
            if (protocolSize.length == sizeof(protocolSizeValue))
                memcpy(&protocolSizeValue, protocolSize.bytes, sizeof(protocolSizeValue));
            valid = valid && protocolSizeValue == 17 && [refreshedDescriptors isEqualToData:descriptors] &&
                [protocolRange isEqualToData:[@"board " dataUsingEncoding:NSUTF8StringEncoding]] &&
                invalidProtocolRequestsRejected && descriptorRequestGates && rejectedManifestClearedOldSnapshot;
            fprintf(stderr, "cliprdr-requests size=%d range=%d rejected=%d descriptor-gates=%d stale-manifest-cleared=%d\n", protocolSizeValue == 17,
                    protocolRange != nil && [protocolRange isEqualToData:[@"board " dataUsingEncoding:NSUTF8StringEncoding]],
                    invalidProtocolRequestsRejected, descriptorRequestGates, rejectedManifestClearedOldSnapshot);

            // Windows may request a file range after the Mac clipboard has
            // already changed. Keep serving the manifest it requested until
            // Windows asks for a replacement manifest.
            NSData *alternateDescriptors = [(id)view fileDescriptorDataForURLs:@[alternateFile]];
            CLIPRDR_FILE_CONTENTS_REQUEST snapshotRangeRequest = {0};
            snapshotRangeRequest.listIndex = 0; snapshotRangeRequest.dwFlags = FILECONTENTS_RANGE;
            snapshotRangeRequest.cbRequested = 18;
            NSData *previousSnapshotRange = [(id)view clipboardFileContentsForRequest:&snapshotRangeRequest
                serverFlags:CB_STREAM_FILECLIP_ENABLED];
            const BOOL oldSnapshotStable = [previousSnapshotRange isEqualToData:[@"clipboard fixture" dataUsingEncoding:NSUTF8StringEncoding]];
            // Changing local pasteboard data does not replace the manifest the remote side is using.
            NSData *replacedDescriptors = [(id)view clipboardFileDescriptorsForRequestFormat:fileGroupFormat
                registeredFormat:fileGroupFormat serverFlags:CB_STREAM_FILECLIP_ENABLED];
            NSData *replacementSnapshotRange = [(id)view clipboardFileContentsForRequest:&snapshotRangeRequest
                serverFlags:CB_STREAM_FILECLIP_ENABLED];
            const BOOL transferSnapshotStable = [alternateDescriptors isEqualToData:replacedDescriptors] &&
                oldSnapshotStable &&
                [replacementSnapshotRange isEqualToData:[@"alternate fixture" dataUsingEncoding:NSUTF8StringEncoding]];
            valid = valid && transferSnapshotStable;
            fprintf(stderr, "cliprdr-snapshot stays-with-manifest=%d changes-on-next-manifest=%d\n",
                    oldSnapshotStable,
                    [replacementSnapshotRange isEqualToData:[@"alternate fixture" dataUsingEncoding:NSUTF8StringEncoding]]);

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
            BOOL repeatedZeroLengthRejected = YES;
            for (NSUInteger attempt = 0; attempt < 128; attempt++) {
                NSData *invalidRange = [(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                    flags:FCProbeFileContentsRange offset:0 requestedLength:0];
                if (invalidRange) { repeatedZeroLengthRejected = NO; break; }
            }
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
                invalidFlagsRejected && invalidOffsetRejected && zeroLengthRejected && repeatedZeroLengthRejected &&
                oversizedReadRejected &&
                wrongSizeRejected && folderRejected && symlinkRejected;
            fprintf(stderr, "file-ranges size=%d range=%d end=%d empty-size=%d empty-range=%d invalid=%d/%d/%d/%d/%d/%d/%d/%d\n",
                    decodedSize == fileSize, range != nil && [range isEqualToData:[@"board " dataUsingEncoding:NSUTF8StringEncoding]],
                    endRange.length == 0, emptySize.length == sizeof(uint64_t), emptyRange != nil && emptyRange.length == 0,
                    invalidFlagsRejected, invalidOffsetRejected, zeroLengthRejected, repeatedZeroLengthRejected,
                    oversizedReadRejected,
                    wrongSizeRejected, folderRejected, symlinkRejected);

            // A new pasteboard generation with no eligible files must not
            // leave the prior Windows manifest available for later reads.
            NSData *staleManifest = [(id)view fileDescriptorDataForURLs:urls];
            [(id)view clipboardFileDescriptorsForRequestFormat:fileGroupFormat registeredFormat:fileGroupFormat
                serverFlags:CB_STREAM_FILECLIP_ENABLED];
            NSData *emptyManifest = [(id)view fileDescriptorDataForURLs:@[]];
            NSData *emptyAnnouncement = [(id)view clipboardFileDescriptorsForRequestFormat:fileGroupFormat
                registeredFormat:fileGroupFormat serverFlags:CB_STREAM_FILECLIP_ENABLED];
            const BOOL emptyGenerationClearsTransfer = !emptyManifest &&
                !emptyAnnouncement &&
                [view valueForKey:@"clipboardFileSnapshot"] == nil &&
                [view valueForKey:@"clipboardFileTransferSnapshot"] == nil &&
                ![(id)view clipboardFileContentsForRequest:&sizeRequest serverFlags:CB_STREAM_FILECLIP_ENABLED];
            fprintf(stderr, "file-manifest empty-generation-clears-transfer=%d\n", emptyGenerationClearsTransfer);
            valid = valid && staleManifest.length > 0 && emptyGenerationClearsTransfer;

            // Replacing a file with a different length invalidates the captured manifest.
            [(id)view fileDescriptorDataForURLs:urls];
            [(id)view clipboardFileDescriptorsForRequestFormat:fileGroupFormat registeredFormat:fileGroupFormat
                serverFlags:CB_STREAM_FILECLIP_ENABLED];
            int fileDescriptor = open(file.fileSystemRepresentation, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC);
            const char changed = '!';
            const BOOL changedFile = fileDescriptor >= 0 && write(fileDescriptor, &changed, sizeof(changed)) == sizeof(changed);
            if (fileDescriptor >= 0) close(fileDescriptor);
            const BOOL staleManifestRejected = ![(id)view clipboardFileContentsForURL:file expectedSize:fileSize
                flags:FCProbeFileContentsSize offset:0 requestedLength:0];
            const BOOL staleProtocolRequestRejected = ![(id)view clipboardFileContentsForRequest:&sizeRequest
                serverFlags:CB_STREAM_FILECLIP_ENABLED];
            fprintf(stderr, "file-mutation changed=%d stale-manifest-rejected=%d stale-protocol-request-rejected=%d\n",
                    changedFile, staleManifestRejected, staleProtocolRequestRejected);
            valid = valid && changedFile && staleManifestRejected && staleProtocolRequestRejected;
            [(id)view captureClipboardFromPasteboard:pasteboard];
            NSData *text = [view valueForKey:@"clipboardText"];
            fprintf(stderr, "file-manifest-after-mutation files=%lu text-present=%d\n",
                    (unsigned long)[[view valueForKeyPath:@"clipboardFileSnapshot.files"] count], text != nil);
            valid = valid && text == nil && [[view valueForKeyPath:@"clipboardFileSnapshot.files"] count] == 2;
            [pasteboard releaseGlobally];
            [files removeItemAtURL:directory error:nil];
            return valid ? 0 : 9;
        }
        if (!window) {
            window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 1100, 750) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
            window.title = @"FjärrConnect — embedded RDP integration test";
            window.contentView = view; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
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
