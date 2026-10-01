import SwiftUI

/// AppKit owns the buttons and horizontal scrolling, including their hit testing
/// on macOS 14/15. Changing the selected tab never recreates its connection.
struct SessionTabBar: NSViewRepresentable {
    let tabs: [SessionTab]
    let selectedID: UUID?
    let largeControls: Bool
    let select: (UUID) -> Void
    let close: (UUID) -> Void

    func makeNSView(context: Context) -> TabScrollView { TabScrollView() }
    func updateNSView(_ view: TabScrollView, context: Context) {
        view.update(tabs: tabs, selectedID: selectedID, largeControls: largeControls,
                    select: select, close: close)
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

        func update(tabs: [SessionTab], selectedID: UUID?, largeControls: Bool,
                    select: @escaping (UUID) -> Void, close: @escaping (UUID) -> Void) {
            let ids = Set(tabs.map(\.id))
            for id in Array(rows.keys) where !ids.contains(id) {
                if let row = rows.removeValue(forKey: id) { strip.removeArrangedSubview(row); row.removeFromSuperview() }
            }
            for tab in tabs {
                let row: TabRow
                if let existing = rows[tab.id] { row = existing }
                else { row = TabRow(); rows[tab.id] = row; strip.addArrangedSubview(row) }
                row.update(profile: tab.backend.profile, selected: tab.id == selectedID,
                           largeControls: largeControls,
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
        private let stack = NSStackView()
        private var selectButtonHeight: NSLayoutConstraint!
        private var selectButtonMaxWidth: NSLayoutConstraint!
        private var closeButtonWidth: NSLayoutConstraint!
        private var closeButtonHeight: NSLayoutConstraint!

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 8
            stack.addArrangedSubview(selectButton)
            stack.addArrangedSubview(closeButton)
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
            selectButtonHeight = selectButton.heightAnchor.constraint(equalToConstant: 24)
            selectButtonMaxWidth = selectButton.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
            closeButtonWidth = closeButton.widthAnchor.constraint(equalToConstant: 24)
            closeButtonHeight = closeButton.heightAnchor.constraint(equalToConstant: 24)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                selectButtonHeight,
                selectButtonMaxWidth,
                closeButtonWidth,
                closeButtonHeight
            ])
        }
        required init?(coder: NSCoder) { nil }

        func update(profile: ConnectionProfile, selected: Bool, largeControls: Bool,
                    select: @escaping () -> Void, close: @escaping () -> Void) {
            let tabTitle = profile.sessionTabTitle
            let buttonSize: CGFloat = largeControls ? 32 : 24
            selectButton.controlSize = largeControls ? .large : .regular
            closeButton.controlSize = largeControls ? .large : .regular
            selectButton.font = .systemFont(ofSize: largeControls ? NSFont.systemFontSize + 3 : NSFont.systemFontSize)
            stack.spacing = largeControls ? 12 : 8
            selectButtonHeight.constant = buttonSize
            selectButtonMaxWidth.constant = largeControls ? 300 : 240
            closeButtonWidth.constant = buttonSize
            closeButtonHeight.constant = buttonSize
            selectButton.title = tabTitle
            selectButton.image = NSImage(systemSymbolName: profile.transport.symbol, accessibilityDescription: nil)
            selectButton.toolTip = tabTitle
            selectButton.setAccessibilityIdentifier("session.select.\(profile.name)")
            selectButton.setAccessibilityLabel(tabTitle)
            selectButton.setAccessibilitySelected(selected)
            selectButton.callback = select
            let closeLabel = String(
                format: NSLocalizedString("action.closeNamedSession", comment: "Accessibility label for closing a named session"),
                tabTitle
            )
            closeButton.toolTip = closeLabel
            closeButton.setAccessibilityLabel(closeLabel)
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
