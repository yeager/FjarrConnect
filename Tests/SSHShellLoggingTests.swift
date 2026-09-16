import XCTest
import SwiftTerm
@testable import FjarrConnect

final class SSHShellLoggingTests: XCTestCase {
    func testBashReportsCommandNamesWithoutArgumentsOrPasswordInput() throws { try checkShell("/bin/bash") }
    func testZshReportsCommandNamesWithoutArgumentsOrPasswordInput() throws { try checkShell("/bin/zsh") }

    private func checkShell(_ shell: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let terminal = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        defer { terminal.terminate() }
        let ready = expectation(description: "Shell integration ready")
        var names: [String] = []
        var readyReceived = false
        terminal.getTerminal().registerOscHandler(code: SSHCommandLogging.oscCode) { bytes in
            switch SSHCommandLogging.event(bytes) {
            case .ready:
                if !readyReceived { readyReceived = true; ready.fulfill() }
            case .command(let name): names.append(name)
            default: break
            }
        }
        terminal.startProcess(executable: "/bin/sh", args: ["-c", SSHCommandLogging.remoteCommand],
                              environment: ["HOME=\(home.path)", "SHELL=\(shell)", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color"])
        wait(for: [ready], timeout: 10)
        func send(_ text: String) { terminal.process.send(data: Array(text.utf8)[...]) }
        func awaitCount(_ count: Int) {
            let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in names.count >= count }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed)
        }
        send("printf '%s\\n' 'fixture-private-argument'\r")
        awaitCount(1)
        send("fixture-private-value\r")
        awaitCount(2)
        // This child asks for secret input without echo, like sudo/ssh. Its
        // input is never a shell preexec event and must never enter the log.
        send("bash -c 'read -s -p Password: value; printf %s%s FJARR_READ_ COMPLETE'\r")
        awaitCount(3)
        let passwordPrompt = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.last == "Password:"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [passwordPrompt], timeout: 5), .completed)
        send("fixture-private-password\r")
        let finishedRead = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("FJARR_READ_COMPLETE")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finishedRead], timeout: 5), .completed)
        send("pwd\r")
        awaitCount(4)
        XCTAssertEqual(names, ["printf", "other", "bash", "pwd"])
    }
}
