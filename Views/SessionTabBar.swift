import SwiftUI

/// AppKit owns the buttons and horizontal scrolling, including their hit testing
/// on macOS 14/15. Changing the selected tab never recreates its connection.
struct SessionTabBar: NSViewRepresentable {
    let tabs: [SessionTab]
    let selectedID: UUID?
    let select: (UUID) -> Void
    let close: (UUID) -> Void

    func makeNSView(context: Context) -> TabScrollView { TabScrollView() }
    func updateNSView(_ view: TabScrollView, context: Context) {
        view.update(tabs: tabs, selectedID: selectedID, select: select, close: close)
    }

    final class TabScrollView: NSScrollView {
        private let strip = NSStackView()
        private var rows: [UUID: TabRow] = [:]
        private var previousSelection: UUID?

        init() {
            super.init(frame: .zero)
            drawsBackground = false
            hasHorizontalScroller = true
            autohidesScrollers = true
            scrollerStyle = .overlay
            strip.orientation = .horizontal
            strip.alignment = .centerY
            strip.spacing = 6
            strip.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            strip.translatesAutoresizingMaskIntoConstraints = false
            documentView = strip
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                strip.topAnchor.constraint(equalTo: contentView.topAnchor),
                strip.heightAnchor.constraint(equalTo: contentView.heightAnchor)
            ])
        }
        required init?(coder: NSCoder) { nil }

        func update(tabs: [SessionTab], selectedID: UUID?, select: @escaping (UUID) -> Void, close: @escaping (UUID) -> Void) {
            let ids = Set(tabs.map(\.id))
            for id in Array(rows.keys) where !ids.contains(id) {
                if let row = rows.removeValue(forKey: id) { strip.removeArrangedSubview(row); row.removeFromSuperview() }
            }
            for tab in tabs {
                let row: TabRow
                if let existing = rows[tab.id] { row = existing }
                else { row = TabRow(); rows[tab.id] = row; strip.addArrangedSubview(row) }
                row.update(profile: tab.backend.profile, selected: tab.id == selectedID,
                           select: { select(tab.id) }, close: { close(tab.id) })
            }
            if selectedID != previousSelection, let selectedID, let row = rows[selectedID] {
                layoutSubtreeIfNeeded()
                strip.scrollToVisible(row.frame.insetBy(dx: -8, dy: 0))
            }
            previousSelection = selectedID
        }
    }

    private final class TabRow: NSView {
        let selectButton = TabButton()
        let closeButton = TabButton()
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 8
            let stack = NSStackView(views: [selectButton, closeButton])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            selectButton.imagePosition = .imageLeading
            selectButton.lineBreakMode = .byTruncatingTail
            selectButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            closeButton.imageScaling = .scaleProportionallyDown
            closeButton.toolTip = NSLocalizedString("action.closeSession", comment: "")
            closeButton.setAccessibilityLabel(closeButton.toolTip)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                selectButton.heightAnchor.constraint(equalToConstant: 24),
                selectButton.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
                closeButton.widthAnchor.constraint(equalToConstant: 24),
                closeButton.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
        required init?(coder: NSCoder) { nil }

        func update(profile: ConnectionProfile, selected: Bool, select: @escaping () -> Void, close: @escaping () -> Void) {
            selectButton.title = profile.name
            selectButton.image = NSImage(systemSymbolName: profile.transport.symbol, accessibilityDescription: nil)
            selectButton.toolTip = profile.name
            selectButton.setAccessibilityIdentifier("session.select.\(profile.name)")
            selectButton.setAccessibilityLabel(profile.name)
            selectButton.setAccessibilitySelected(selected)
            selectButton.callback = select
            closeButton.setAccessibilityIdentifier("session.close.\(profile.name)")
            closeButton.callback = close
            layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.15) : .clear).cgColor
        }
    }

    private final class TabButton: NSButton {
        var callback: () -> Void = {}
        init() {
            super.init(frame: .zero)
            setButtonType(.momentaryPushIn)
            isBordered = false
            bezelStyle = .inline
            font = .systemFont(ofSize: NSFont.systemFontSize)
            target = self
            action = #selector(activate)
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func activate() { callback() }
    }
}
