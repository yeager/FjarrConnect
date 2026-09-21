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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate() ? .terminateNow : .terminateCancel
    }
}

/// Preserve SwiftUI's window delegate for all callbacks except the close decision.
struct WindowCloseConfirmation: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeNSView(context: Context) -> GuardView { GuardView(shouldClose: shouldClose) }
    func updateNSView(_ view: GuardView, context: Context) { view.guardDelegate.shouldClose = shouldClose }

    final class GuardView: NSView {
        let guardDelegate: GuardDelegate
        init(shouldClose: @escaping () -> Bool) {
            guardDelegate = GuardDelegate(shouldClose: shouldClose)
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
        init(shouldClose: @escaping () -> Bool) { self.shouldClose = shouldClose }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { original }
    }
}
