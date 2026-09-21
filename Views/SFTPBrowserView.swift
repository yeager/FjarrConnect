import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers

struct SFTPBrowserView: View {
    @ObservedObject var session: SFTPRemoteSession
    @State private var path = ""
    @State private var selection: SFTPEntry.ID?
    private var selected: SFTPEntry? { session.entries.first { $0.id == selection } }

    var body: some View {
        Group {
            if session.status == .connecting, let terminal = session.terminal {
                VStack(alignment: .leading) {
                    Text("files.auth").font(.callout).padding()
                    SFTPAuthenticationView(terminal: terminal)
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button { session.browse((session.directory as NSString).deletingLastPathComponent.isEmpty ? "/" : (session.directory as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }.help("files.parent").accessibilityIdentifier("files.parent")
                        TextField("files.path", text: $path).textFieldStyle(.roundedBorder).onSubmit { session.browse(path) }.accessibilityIdentifier("files.path")
                        Button { session.browse(session.directory) } label: { Image(systemName: "arrow.clockwise") }.help("action.refresh").accessibilityIdentifier("files.refresh")
                        Button("files.upload", action: upload).accessibilityIdentifier("files.upload")
                        Button("files.download") { if let selected { download(selected) } }.disabled(selected == nil || selected?.isSymbolicLink == true).accessibilityIdentifier("files.download")
                        Menu {
                            Button("files.newFolder") { if let name = askName(title: "files.newFolder", initial: "") { session.makeDirectory(name) } }
                            if let selected {
                                Button("files.rename") { if let name = askName(title: "files.rename", initial: selected.name) { session.rename(selected, to: name) } }
                                Button("action.delete", role: .destructive) { delete(selected) }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .fixedSize().accessibilityIdentifier("files.actions")
                    }.padding(10).disabled(session.busy || session.status != .connected)
                    Divider()
                    Table(session.entries, selection: $selection) {
                        TableColumn("field.name") { entry in
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : (entry.isSymbolicLink ? "link" : "doc"))
                                .accessibilityIdentifier("files.entry.\(entry.name)")
                        }
                        TableColumn("files.size") { entry in Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)) }.width(min: 70, ideal: 90, max: 130)
                        TableColumn("files.modified") { entry in if let date = entry.modified { Text(date, format: .dateTime.year().month().day().hour().minute()) } }.width(min: 130, ideal: 175, max: 220)
                    }
                    // Let the table own selection and its primary row action, so
                    // double-clicking any column works without consuming selection.
                    .contextMenu(forSelectionType: SFTPEntry.ID.self) { ids in
                        if let entry = session.entries.first(where: { ids.contains($0.id) }) {
                            if entry.isDirectory { Button("files.openFolder") { open(entry) } }
                            Button("files.download") { download(entry) }.disabled(entry.isSymbolicLink)
                            Button("files.rename") { if let name = askName(title: "files.rename", initial: entry.name) { session.rename(entry, to: name) } }
                            Button("action.delete", role: .destructive) { delete(entry) }
                        }
                    } primaryAction: { ids in
                        if let entry = session.entries.first(where: { ids.contains($0.id) }) { open(entry) }
                    }
                    .accessibilityIdentifier("files.table")
                    .disabled(session.busy || session.status != .connected)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard !session.busy, session.status == .connected, urls.allSatisfy(\.isFileURL) else { return false }
                        upload(urls); return true
                    }
                    if session.busy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: session.transferred), countStyle: .file)).monospacedDigit()
                            Spacer()
                            Button("files.cancelTransfer") { session.cancelTransfer() }
                                .disabled(session.recoveringTransfer)
                                .accessibilityIdentifier("files.cancelTransfer")
                        }.padding(10)
                    }
                }
            }
        }
        .onChange(of: session.directory, initial: true) { _, value in path = value; selection = nil }
        .alert("error.title", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("action.ok", role: .cancel) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }
    private func open(_ entry: SFTPEntry) {
        guard !session.busy, session.status == .connected else { return }
        if entry.isDirectory { session.browse(SFTPClient.join(session.directory, entry.name)) }
        else if entry.isRegularFile { download(entry) }
    }
    private func upload() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { upload(panel.urls) }
    }
    private func upload(_ urls: [URL]) {
        var files: [(URL, Bool)] = []
        for url in urls {
            let exists = session.entries.contains { $0.name == url.lastPathComponent }
            if exists && !confirm(title: "files.replace", message: url.lastPathComponent) { continue }
            files.append((url, exists))
        }
        if !files.isEmpty { session.upload(files) }
    }
    private func download(_ entry: SFTPEntry) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            session.download(entry, to: url, overwrite: FileManager.default.fileExists(atPath: url.path))
        }
    }
    private func delete(_ entry: SFTPEntry) {
        if confirm(title: "files.delete", message: entry.name + "\n\n" + NSLocalizedString("files.delete.hint", comment: "")) { session.remove(entry) }
    }
    private func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(title, comment: ""); alert.informativeText = message
        alert.addButton(withTitle: NSLocalizedString("action.cancel", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("action.ok", comment: ""))
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = NSLocalizedString(title, comment: "")
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityIdentifier("files.itemName")
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("action.cancel", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("action.ok", comment: ""))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertSecondButtonReturn, SFTPClient.safeName(field.stringValue) else { return nil }
        return field.stringValue
    }
}

private struct SFTPAuthenticationView: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    func makeNSView(context: Context) -> LocalProcessTerminalView { terminal }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}
