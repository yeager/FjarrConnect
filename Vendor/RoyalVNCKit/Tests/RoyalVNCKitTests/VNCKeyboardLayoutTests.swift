#if os(macOS)
import CoreGraphics
import XCTest
@testable import RoyalVNCKit

final class VNCKeyboardLayoutTests: XCTestCase {
    func testModifierKeysRemainHeldUntilTheirPhysicalKeyUp() {
        let modifiers: [VNCKeyCode] = [
            .shift, .rightShift, .control, .rightControl,
            .option, .optionForARD, .rightOption, .rightOptionForARD,
            .command, .commandForARD, .rightCommand, .rightCommandForARD
        ]

        XCTAssertTrue(modifiers.allSatisfy(\.isModifier))
        XCTAssertFalse(VNCKeyCode(asciiCharacter: 0x61).isModifier)
    }

    func testKeyUpReleasesTheSymbolSentForKeyDown() {
        var tracker = VNCKeyEventTracker()

        let keyDown = tracker.keyDown(for: CGKeyCode(19), characters: "@")
        let repeatedKeyDown = tracker.keyDown(for: CGKeyCode(19), characters: "2", isRepeat: true)
        let keyUp = tracker.keyUp(for: CGKeyCode(19))

        XCTAssertEqual(keyDown.map(\.rawValue), [0x40])
        XCTAssertEqual(repeatedKeyDown, keyDown)
        XCTAssertEqual(keyUp, keyDown)
        XCTAssertTrue(tracker.keyUp(for: CGKeyCode(19)).isEmpty)
    }

    func testLateAutorepeatAfterKeyUpDoesNotStartANewPress() {
        var tracker = VNCKeyEventTracker()

        XCTAssertEqual(tracker.keyDown(for: CGKeyCode(27), characters: "-"), [.init(0x2D)])
        XCTAssertEqual(tracker.keyUp(for: CGKeyCode(27)), [.init(0x2D)])
        XCTAssertTrue(tracker.keyDown(for: CGKeyCode(27), characters: "-", isRepeat: true).isEmpty)
        XCTAssertTrue(tracker.releaseAll().isEmpty)
    }

    func testSwedishOptionTwoUsesResolvedAtCharacter() {
        var tracker = VNCKeyEventTracker()

        let keyDown = tracker.keyDown(for: CGKeyCode(19), characters: "@")
        let keyUp = tracker.keyUp(for: CGKeyCode(19))

        XCTAssertEqual(keyDown.map(\.rawValue), [0x40])
        XCTAssertEqual(keyUp, keyDown)
    }

    func testResolvedCharactersFromDifferentLayoutsMapToTheirOwnKeysyms() {
        var tracker = VNCKeyEventTracker()

        let qwertzY = tracker.keyDown(for: CGKeyCode(6), characters: "y")
        XCTAssertEqual(qwertzY.map(\.rawValue), [0x79])
        _ = tracker.keyUp(for: CGKeyCode(6))

        let swedishCharacters: [(String, UInt32)] = [("å", 0xE5), ("ä", 0xE4), ("ö", 0xF6)]
        for (character, keysym) in swedishCharacters {
            let key = tracker.keyDown(for: CGKeyCode(0xFFFF), characters: character)
            XCTAssertEqual(key.map(\.rawValue), [keysym])
            XCTAssertEqual(tracker.keyUp(for: CGKeyCode(0xFFFF)), key)
        }
    }

    func testNonPrintableCharactersFallBackToPhysicalControlKeys() {
        let cases: [(CGKeyCode, String, VNCKeyCode)] = [
            (CGKeyCode(51), "\u{7f}", .delete),
            (CGKeyCode(36), "\r", .return),
            (CGKeyCode(48), "\t", .tab)
        ]

        for (keyCode, characters, expected) in cases {
            var tracker = VNCKeyEventTracker()
            let keyDown = tracker.keyDown(for: keyCode, characters: characters)

            XCTAssertEqual(keyDown, [expected], "keyCode=\(keyCode), characters=\(characters.debugDescription)")
            XCTAssertEqual(tracker.keyUp(for: keyCode), [expected])
        }
    }

    func testInternationalCharactersUseValidUnicodeKeysyms() {
        var tracker = VNCKeyEventTracker()
        let characters: [(String, UInt32)] = [
            ("é", 0xE9),          // Latin-1 character used by AZERTY layouts.
            ("€", 0x010020AC),    // Unicode keysym for characters above Latin-1.
            ("日", 0x010065E5),    // CJK input.
            ("🙂", 0x0101F642)     // Supplementary-plane Unicode input.
        ]

        for (index, item) in characters.enumerated() {
            let keyCode = CGKeyCode(0xFF00 + index)
            let keyDown = tracker.keyDown(for: keyCode, characters: item.0)
            XCTAssertEqual(keyDown.map(\.rawValue), [item.1], item.0)
            XCTAssertEqual(tracker.keyUp(for: keyCode), keyDown, item.0)
        }
    }

    func testSwedishRightOptionTwoSendsAtAndReleasesBothKeys() {
        var tracker = VNCKeyEventTracker()
        let optionDown = KeyboardModifiers(currentFlags: [.rightOption], lastFlags: []).events
        XCTAssertEqual(optionDown.count, 1)
        let optionKey = optionDown[0]
        let optionKeys = tracker.keyDown(for: CGKeyCode(optionKey.keyCode),
                                         characters: optionKey.charactersIgnoringModifiers)

        // AppKit resolves Swedish right Option+2 to "@". Send that character
        // directly, with Option temporarily released by the framebuffer view.
        let atKeys = tracker.keyDown(for: CGKeyCode(19), characters: "@")
        let releasedAtKeys = tracker.keyUp(for: CGKeyCode(19))

        let optionUp = KeyboardModifiers(currentFlags: [], lastFlags: [.rightOption]).events
        XCTAssertEqual(optionUp.count, 1)
        let releasedOptionKeys = tracker.keyUp(for: CGKeyCode(optionUp[0].keyCode))

        XCTAssertEqual(optionKeys.map(\.rawValue), [0xFFEA])
        XCTAssertEqual(atKeys.map(\.rawValue), [0x40])
        XCTAssertEqual(releasedAtKeys, atKeys)
        XCTAssertEqual(releasedOptionKeys, optionKeys)
    }

    func testReleaseAllReturnsEveryOutstandingKeyOnce() {
        var tracker = VNCKeyEventTracker()
        _ = tracker.keyDown(for: CGKeyCode(0xFFFF), characters: "å")
        _ = tracker.keyDown(for: CGKeyCode(0xFFFE), characters: "ä")

        XCTAssertEqual(tracker.releaseAll().map(\.rawValue), [0xE4, 0xE5])
        XCTAssertTrue(tracker.releaseAll().isEmpty)
    }

    func testInitialPressGetsRemoteReleaseWithoutClearingPhysicalKeyForRepeats() {
        let queue = Queue<VNCSendableMessage>()
        let initialDown = VNCProtocol.KeyEvent(isDown: true, key: 0x2D)
        let keyUp = VNCProtocol.KeyEvent(isDown: false, key: 0x2D)

        queue.enqueueKeyEvent(initialDown)
        queue.enqueueKeyTapRelease(keyUp)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, true)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, false,
                       "The initial press is released even if AppKit later loses physical key-up")

        queue.enqueueKeyRepeat(initialDown)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, true,
                       "The client retains physical state so autorepeat still works")
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, false)
        queue.enqueueKeyEvent(keyUp)
        queue.enqueueKeyRepeat(initialDown)
        XCTAssertNil(queue.dequeue())
    }

    func testPhysicalKeyUpKeepsAnUnsentInitialPressBalanced() {
        let queue = Queue<VNCSendableMessage>()
        let keyDown = VNCProtocol.KeyEvent(isDown: true, key: 0x2D)
        let keyUp = VNCProtocol.KeyEvent(isDown: false, key: 0x2D)

        queue.enqueueKeyEvent(keyDown)
        queue.enqueueKeyTapRelease(keyUp)
        queue.enqueueKeyEvent(keyUp)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, true)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, false,
                       "The real key-up replaces a synthetic release removed from the unsent queue")
        XCTAssertNil(queue.dequeue())
    }

    func testPendingAutorepeatsAreBoundedUntilTheSendQueueDrains() {
        let queue = Queue<VNCSendableMessage>()
        let initialDown = VNCProtocol.KeyEvent(isDown: true, key: 0x2D)
        let repeatDown = VNCProtocol.KeyEvent(isDown: true, key: 0x2D)
        let keyUp = VNCProtocol.KeyEvent(isDown: false, key: 0x2D)

        queue.enqueueKeyEvent(initialDown)
        for _ in 0..<10_000 {
            queue.enqueueKeyRepeat(repeatDown)
        }

        XCTAssertNotNil(queue.dequeue() as? VNCProtocol.KeyEvent, "The initial press is preserved")
        XCTAssertNil(queue.dequeue(), "Repeats coalesce while the initial key-down is still pending")

        for _ in 0..<10_000 {
            queue.enqueueKeyRepeat(repeatDown)
        }
        let repeatedPress = queue.dequeue() as? VNCProtocol.KeyEvent
        XCTAssertEqual(repeatedPress?.isDown, true, "One pending repeat is preserved after the initial press drains")
        let repeatedRelease = queue.dequeue() as? VNCProtocol.KeyEvent
        XCTAssertEqual(repeatedRelease?.isDown, false, "Every autorepeat is paired with a release")
        XCTAssertNil(queue.dequeue(), "Further repeats coalesce until that pending repeat drains")

        for _ in 0..<10_000 {
            queue.enqueueKeyRepeat(repeatDown)
        }
        queue.enqueueKeyEvent(keyUp)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, false,
                       "Key-up discards both events of a repeat that had not reached the server")
        queue.enqueueKeyRepeat(repeatDown)
        XCTAssertNil(queue.dequeue(), "A repeat after key-up cannot start another remote press")

        queue.enqueueKeyEvent(initialDown)
        queue.enqueueKeyRepeat(repeatDown)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, true)
        queue.enqueueKeyRepeat(repeatDown)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, true,
                       "A held physical key can still autorepeat after its initial press is sent")
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, false,
                       "The repeat releases its key even while the physical key remains held")
        queue.enqueueKeyRepeat(repeatDown)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, true)
        XCTAssertEqual((queue.dequeue() as? VNCProtocol.KeyEvent)?.isDown, false)
        queue.enqueueKeyEvent(keyUp)
        XCTAssertNil(queue.dequeue(), "A key-up after a balanced repeat must not send a duplicate release")
    }
}
#endif
