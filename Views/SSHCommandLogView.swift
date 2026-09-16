import SwiftUI

struct SSHCommandLogView: View {
    let profile: ConnectionProfile
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SSHCommandLogEntry] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("ssh.log.title", systemImage: "lock.doc").font(.title2.bold())
                Spacer()
                Button("action.close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("ssh.log.close")
            }
            Text(profile.name).font(.headline)
            Text("ssh.log.details").font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
            if entries.isEmpty {
                ContentUnavailableView("ssh.log.empty", systemImage: "terminal")
            } else {
                Table(entries.reversed()) {
                    TableColumn("ssh.log.time") { entry in
                        Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                    }.width(min: 190, ideal: 220)
                    TableColumn("ssh.log.command") { entry in
                        Text(entry.command == "other" ? NSLocalizedString("ssh.log.other", comment: "") : entry.command)
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Button("ssh.log.refresh") { load() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("ssh.log.clear", role: .destructive) { confirmingClear = true }.disabled(busy)
            }
        }
        .padding(24).frame(minWidth: 640, idealWidth: 700, minHeight: 450)
        .onAppear { load() }
        .confirmationDialog("ssh.log.clear.confirm", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("ssh.log.clear", role: .destructive) { load(clear: true) }
        }
    }

    private func load(clear: Bool = false) {
        busy = true
        errorMessage = nil
        let id = profile.id
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> [SSHCommandLogEntry] in
                if clear { try SSHCommandLogStore.shared.clear(for: id) }
                return try SSHCommandLogStore.shared.entries(for: id)
            }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let loaded): entries = loaded
                case .failure: errorMessage = NSLocalizedString("ssh.log.readFailed", comment: "")
                }
            }
        }
    }
}
