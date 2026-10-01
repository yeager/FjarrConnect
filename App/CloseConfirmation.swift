import SwiftUI

enum CloseConfirmation {
    static func session(_ name: String) -> Bool {
        show(title: "close.session.title", message: String(format: NSLocalizedString("close.session.message", comment: ""), name))
    }

    static func application(_ names: [String]) -> Bool {
        let message = String(format: NSLocalizedString("close.app.message", comment: ""), names.count)
        return show(title: "close.app.title", message: message + "\n\n" + names.prefix(8).joined(separator: "\n"))
    }

    private static func show(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(title, comment: "")
        alert.informativeText = message
        alert.addButton(withTitle: NSLocalizedString("action.cancel", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("close.confirm", comment: ""))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

final class FjarrConnectAppDelegate: NSObject, NSApplicationDelegate {
    var shouldTerminate: () -> Bool = { true }
    var prepareForTermination: (@escaping () -> Void) -> Void = { $0() }
    var replyToTermination: (NSApplication, Bool) -> Void = { application, shouldTerminate in
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }
    private var terminationInProgress = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shouldTerminate() else { return .terminateCancel }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        prepareForTermination { [weak self, weak sender] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.terminationInProgress = false
                if let sender { self.replyToTermination(sender, true) }
            }
        }
        return .terminateLater
    }
}

/// Preserve SwiftUI's window delegate for all callbacks except the close decision.
struct WindowCloseConfirmation: NSViewRepresentable {
    let shouldClose: () -> Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> GuardView { GuardView(shouldClose: shouldClose, onClose: onClose) }
    func updateNSView(_ view: GuardView, context: Context) {
        view.guardDelegate.shouldClose = shouldClose
        view.guardDelegate.onClose = onClose
    }

    final class GuardView: NSView {
        let guardDelegate: GuardDelegate
        init(shouldClose: @escaping () -> Bool, onClose: @escaping () -> Void) {
            guardDelegate = GuardDelegate(shouldClose: shouldClose, onClose: onClose)
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        // This background view observes the window; clicks belong to the SwiftUI controls above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== guardDelegate else { return }
            guardDelegate.original = window.delegate
            window.delegate = guardDelegate
        }
    }

    final class GuardDelegate: NSObject, NSWindowDelegate {
        weak var original: (any NSWindowDelegate)?
        var shouldClose: () -> Bool
        var onClose: () -> Void
        init(shouldClose: @escaping () -> Bool, onClose: @escaping () -> Void) {
            self.shouldClose = shouldClose
            self.onClose = onClose
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            onClose()
            original?.windowWillClose?(notification)
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { original }
    }
}
