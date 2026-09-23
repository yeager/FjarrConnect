import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var profiles: ProfileStore
    @AppStorage(AppSettings.showSidebar) private var showSidebar = true
    @AppStorage(AppSettings.useLargeControls) private var useLargeControls = false
    @AppStorage(AppSettings.autoStartDiscovery) private var autoStartDiscovery = true
    @AppStorage(AppSettings.confirmClosingSessions) private var confirmClosingSessions = true
    @AppStorage(AppSettings.autoHideSidebarWhileConnected) private var autoHideSidebarWhileConnected = false
    @AppStorage(AppSettings.autoHideSessionTabsWhileConnected) private var autoHideSessionTabsWhileConnected = false
    @AppStorage(AppSettings.scanTimeout) private var scanTimeout = 2.0
    @AppStorage(AppSettings.scanConcurrency) private var scanConcurrency = 32
    @State private var transfer: ProfileTransfer?
    @State private var transferMessage: String?

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
    }

    private func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FjarrConnect-profiles.fjarrconnect.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transfer = .export(url)
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
        panel.allowedFileTypes = ["rdp", "vnc"]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profiles.importExternalProfile(data: Data(contentsOf: url), fileExtension: url.pathExtension)
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
                let count = try profiles.importEncryptedProfiles(Data(contentsOf: url), passphrase: passphrase)
                transferMessage = String(format: NSLocalizedString("profiles.import.done", comment: ""), count)
                return .success(count)
            }
        } catch {
            transferMessage = NSLocalizedString("profiles.transfer.error", comment: "")
            return .failure(error)
        }
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
