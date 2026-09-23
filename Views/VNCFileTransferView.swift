import SwiftUI
import RoyalVNCKit

struct VNCFileTransferView: View {
    @ObservedObject var session: VNCRemoteSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedName: String?
    init(session: VNCRemoteSession) { self.session = session }

    private var rows: [VNCRemoteFileRow] { session.remoteFiles.map(VNCRemoteFileRow.init) }
    private var selectedFile: VNCRemoteFile? { session.remoteFiles.first { $0.name == selectedName } }

    var body: some View {
        VStack(spacing: 0) {
            Text("vnc.files.hint").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 8)
            HStack {
                Button(action: goToParent) { Image(systemName: "arrow.up") }
                    .help("vnc.files.parent")
                    .disabled(session.remoteDirectory == "/")
                Text(session.remoteDirectory).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { session.browseRemoteFiles(session.remoteDirectory) } label: { Image(systemName: "arrow.clockwise") }
                    .help("vnc.files.refresh")
                Button {
                    if session.isUploadingFile { return }
                    upload()
                } label: {
                    if session.isUploadingFile {
                        Label("vnc.files.uploading", systemImage: "arrow.up.doc")
                    } else {
                        Label("vnc.files.upload", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(!session.fileUploadAvailable || session.isUploadingFile)
                .help(LocalizedStringKey(session.fileUploadAvailable ? "vnc.files.uploadHint" : "vnc.files.uploadUnavailable"))
                Button("vnc.files.download", action: download)
                    .disabled(session.isLoadingRemoteFiles || selectedFile == nil || selectedFile?.isDirectory == true)
            }.padding(12)
            Divider()
            if session.isLoadingRemoteFiles {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.remoteFiles.isEmpty {
                ContentUnavailableView("vnc.files.empty", systemImage: "folder")
            } else {
                Table(rows, selection: $selectedName) {
                    TableColumn("field.name") { row in
                        Label(row.file.name, systemImage: row.file.isDirectory ? "folder" : "doc")
                            .onTapGesture(count: 2) { if row.file.isDirectory { open(row.file) } }
                    }
                    TableColumn("files.size") { row in
                        Text(row.file.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: row.file.size), countStyle: .file))
                    }.width(min: 80, ideal: 100, max: 140)
                }
                .contextMenu(forSelectionType: String.self) { names in
                    if let file = session.remoteFiles.first(where: { names.contains($0.name) }) {
                        if file.isDirectory { Button("vnc.files.open") { open(file) } }
                        else { Button("vnc.files.download") { download(file) } }
                    }
                } primaryAction: { names in
                    if let file = session.remoteFiles.first(where: { names.contains($0.name) }) {
                        if file.isDirectory { open(file) } else { download(file) }
                    }
                }
            }
            if let notice = session.fileTransferNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .frame(minWidth: 580, minHeight: 360)
        .onAppear { session.browseRemoteFiles(session.remoteDirectory) }
        .alert("error.title", isPresented: Binding(
            get: { !session.fileTransferAvailable },
            set: { if !$0 { dismiss() } }
        )) {
            Button("action.ok", role: .cancel) { dismiss() }
        } message: { Text("vnc.files.notSupported") }
    }

    private func open(_ file: VNCRemoteFile) {
        guard file.isDirectory else { return }
        let path = session.remoteDirectory == "/" ? "/\(file.name)" : "\(session.remoteDirectory)/\(file.name)"
        session.browseRemoteFiles(path)
    }

    private func goToParent() {
        let parent = (session.remoteDirectory as NSString).deletingLastPathComponent
        session.browseRemoteFiles(parent.isEmpty ? "/" : parent)
    }

    private func download() {
        guard let selectedFile else { return }
        download(selectedFile)
    }

    private func download(_ file: VNCRemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { session.downloadRemoteFile(file, to: url) }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("vnc.files.upload", comment: "")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if session.remoteFiles.contains(where: { $0.name == url.lastPathComponent }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("files.replace", comment: "")
            alert.informativeText = url.lastPathComponent
            alert.addButton(withTitle: NSLocalizedString("action.ok", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("action.cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            session.uploadLocalFile(url, overwrite: true)
        } else {
            session.uploadLocalFile(url)
        }
    }
}

private struct VNCRemoteFileRow: Identifiable {
    let file: VNCRemoteFile
    var id: String { file.name }
    init(_ file: VNCRemoteFile) { self.file = file }
}
