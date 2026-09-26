import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var releaseUpdates: ReleaseUpdateChecker
    @AppStorage(AppSettings.showSidebar) private var showSidebar = true
    @AppStorage(AppSettings.useLargeControls) private var useLargeControls = false
    @AppStorage(AppSettings.autoStartDiscovery) private var autoStartDiscovery = true
    @AppStorage(AppSettings.confirmClosingSessions) private var confirmClosingSessions = true
    @AppStorage(AppSettings.autoHideSidebarWhileConnected) private var autoHideSidebarWhileConnected = false
    @AppStorage(AppSettings.autoHideSessionTabsWhileConnected) private var autoHideSessionTabsWhileConnected = false
    @AppStorage(AppSettings.scanTimeout) private var scanTimeout = 2.0
    @AppStorage(AppSettings.scanConcurrency) private var scanConcurrency = 32
    @AppStorage(AppSettings.recordingRetentionDays) private var recordingRetentionDays = 30
    @AppStorage(AppSettings.keyboardLayout) private var keyboardLayout = RDPKeyboardLayout.automatic.rawValue
    @AppStorage(AppSettings.automaticUpdateChecks) private var automaticUpdateChecks = true
    @State private var transfer: ProfileTransfer?
    @State private var transferMessage: String?
    @State private var showingRecordings = false

    var body: some View {
        TabView {
            Form {
                Section("settings.appearance") {
                    Toggle("settings.showSidebar", isOn: $showSidebar)
                    Toggle("settings.useLargeControls", isOn: $useLargeControls)
                    Toggle("settings.autoHideSidebarWhileConnected", isOn: $autoHideSidebarWhileConnected)
                    Toggle("settings.autoHideSessionTabsWhileConnected", isOn: $autoHideSessionTabsWhileConnected)
                }
                Section("settings.connections") {
                    Toggle("settings.autoStartDiscovery", isOn: $autoStartDiscovery)
                    Toggle("settings.confirmClosingSessions", isOn: $confirmClosingSessions)
                }
                Section("updates.title") {
                    Toggle("updates.automatic", isOn: $automaticUpdateChecks)
                    Text("updates.automatic.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("updates.checkNow") {
                        Task { await releaseUpdates.checkNow() }
                    }
                    .disabled(releaseUpdates.status == .checking)
                    updateStatus
                }
                Section("settings.keyboard") {
                    Picker("settings.keyboardLayout", selection: $keyboardLayout) {
                        ForEach(RDPKeyboardLayout.allCases) { layout in
                            Text(layout.titleKey).tag(layout.rawValue)
                        }
                    }
                    Text("settings.keyboardLayout.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("settings.simple", systemImage: "slider.horizontal.3") }

            Form {
                Section("settings.networkScan") {
                    Stepper(value: $scanTimeout, in: 0.1...10, step: 0.1) {
                        Text(String(format: NSLocalizedString("settings.scanTimeout", comment: ""), scanTimeout))
                    }
                    Text("settings.scanTimeout.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(value: $scanConcurrency, in: 1...64) {
                        Text(String(format: NSLocalizedString("settings.scanConcurrency", comment: ""), scanConcurrency))
                    }
                    Text("settings.scanConcurrency.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("profiles.transfer") {
                    Text("profiles.transfer.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("profiles.export", action: chooseExport)
                        Button("profiles.import", action: chooseImport)
                        Button("profiles.importExternal", action: chooseExternalImport)
                    }
                    if let transferMessage { Text(transferMessage).foregroundStyle(.secondary) }
                }
                Section("record.library") {
                    Picker("record.retention", selection: $recordingRetentionDays) {
                        Text("record.retention.never").tag(0)
                        Text(String(format: NSLocalizedString("record.retention.days", comment: ""), 7)).tag(7)
                        Text(String(format: NSLocalizedString("record.retention.days", comment: ""), 30)).tag(30)
                        Text(String(format: NSLocalizedString("record.retention.days", comment: ""), 90)).tag(90)
                    }
                    Button("record.library.open") { showingRecordings = true }
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("settings.advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 540, height: 430)
        .sheet(item: $transfer) { transfer in
            ProfileTransferSheet(transfer: transfer) { passphrase in
                perform(transfer, passphrase: passphrase)
            }
        }
        .sheet(isPresented: $showingRecordings) { RecordingLibraryView(retentionDays: recordingRetentionDays) }
    }

    private func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FjarrConnect-profiles.fjarrconnect.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transfer = .export(url)
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch releaseUpdates.status {
        case .idle:
            EmptyView()
        case .checking:
            Label("updates.checking", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let version, let releaseURL):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: NSLocalizedString("updates.available", comment: ""), version))
                    .font(.caption)
                Link("updates.openRelease", destination: releaseURL)
                    .font(.caption)
            }
        case .upToDate:
            Text("updates.upToDate")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text("updates.failed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transfer = .import(url)
    }

    private func chooseExternalImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "rdp") ?? .data,
            UTType(filenameExtension: "vnc") ?? .data
        ]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ProfileStore.readBoundedFile(at: url, maximumBytes: ProfileStore.maximumExternalProfileBytes)
            try profiles.importExternalProfile(data: data, fileExtension: url.pathExtension)
            transferMessage = NSLocalizedString("profiles.importExternal.done", comment: "")
        } catch {
            transferMessage = NSLocalizedString("profiles.transfer.error", comment: "")
        }
    }

    private func perform(_ transfer: ProfileTransfer, passphrase: String) -> Result<Int, Error> {
        do {
            switch transfer {
            case .export(let url):
                let data = try profiles.encryptedExport(passphrase: passphrase)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                transferMessage = NSLocalizedString("profiles.export.done", comment: "")
                return .success(profiles.profiles.count)
            case .import(let url):
                let data = try ProfileStore.readBoundedFile(at: url, maximumBytes: ProfileStore.maximumProfileTransferBytes)
                let count = try profiles.importEncryptedProfiles(data, passphrase: passphrase)
                transferMessage = String(format: NSLocalizedString("profiles.import.done", comment: ""), count)
                return .success(count)
            }
        } catch {
            transferMessage = NSLocalizedString("profiles.transfer.error", comment: "")
            return .failure(error)
        }
    }
}

private struct RecordingLibraryView: View {
    let retentionDays: Int
    @Environment(\.dismiss) private var dismiss
    @State private var recordings: [RecordingFile] = []
    @State private var search = ""
    @State private var message: String?

    private var filtered: [RecordingFile] {
        search.isEmpty ? recordings : recordings.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("record.library").font(.title2.bold())
                Spacer()
                Button("action.done") { dismiss() }
            }
            TextField("search.placeholder", text: $search).textFieldStyle(.roundedBorder)
            List(filtered) { recording in
                HStack {
                    VStack(alignment: .leading) {
                        Text(recording.url.deletingPathExtension().lastPathComponent)
                        Text(recording.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: recording.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    Button("record.export") { export(recording) }
                    Button(role: .destructive) { delete(recording) } label: { Image(systemName: "trash") }
                        .accessibilityLabel(Text("action.delete"))
                }
            }
            HStack {
                Button("record.cleanup") { cleanup() }.disabled(retentionDays == 0)
                Spacer()
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .padding(20).frame(width: 620, height: 430)
        .onAppear(perform: reload)
    }

    private func reload() { recordings = RecordingLibrary.files() }
    private func delete(_ recording: RecordingFile) {
        do { try FileManager.default.removeItem(at: recording.url); reload() }
        catch { message = NSLocalizedString("record.error", comment: "") }
    }
    private func cleanup() {
        let count = RecordingLibrary.cleanup(olderThan: retentionDays)
        message = String(format: NSLocalizedString("record.cleanup.done", comment: ""), count)
        reload()
    }
    private func export(_ recording: RecordingFile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = recording.url.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try FileManager.default.copyItem(at: recording.url, to: destination) }
        catch { message = NSLocalizedString("record.error", comment: "") }
    }
}

private enum ProfileTransfer: Identifiable {
    case export(URL)
    case `import`(URL)
    var id: String {
        switch self {
        case .export(let url): return "export:" + url.path
        case .import(let url): return "import:" + url.path
        }
    }
    var titleKey: LocalizedStringKey {
        switch self { case .export: return "profiles.export"; case .import: return "profiles.import" }
    }
}

private struct ProfileTransferSheet: View {
    let transfer: ProfileTransfer
    let submit: (String) -> Result<Int, Error>
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var error = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(transfer.titleKey, systemImage: "lock.doc")
                .font(.title2.bold())
            Text("profiles.transfer.password.hint").font(.caption).foregroundStyle(.secondary)
            SecureField("profiles.transfer.password", text: $passphrase)
            if case .export = transfer {
                SecureField("profiles.transfer.confirm", text: $confirmation)
            }
            if error { Text("profiles.transfer.error").foregroundStyle(.red) }
            HStack {
                Button("action.cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("action.continue") {
                    error = submit(passphrase).isFailure
                    if !error { passphrase = ""; confirmation = ""; dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty || (isExport && passphrase != confirmation))
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 420)
    }

    private var isExport: Bool { if case .export = transfer { return true }; return false }
}

private extension Result where Success == Int, Failure == Error {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}
