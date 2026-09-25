import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss
    private let existing: ConnectionProfile?
    @State private var name: String
    @State private var transport: RemoteTransport
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var usesMacScreenSharingAuthentication: Bool
    @State private var password = ""
    @State private var changePassword = false
    @State private var group: String
    @State private var tags: String
    @State private var logsSSHCommands: Bool
    @State private var requiresBiometricUnlock: Bool
    @State private var ssh: SSHOptions
    @State private var rdp: RDPOptions
    @State private var links: HostLinks
    @State private var clipboard: Bool
    @State private var forwards: [SSHForward]
    @State private var automaticReconnect: Bool
    @State private var wakeOnLANMac: String
    @State private var errorMessage: String?

    init(profile: ConnectionProfile?) {
        existing = profile
        _ssh = State(initialValue: profile?.ssh ?? SSHOptions())
        _rdp = State(initialValue: profile?.rdp ?? RDPOptions())
        _links = State(initialValue: profile?.links ?? HostLinks())
        _clipboard = State(initialValue: profile?.sharesClipboard ?? true)
        _forwards = State(initialValue: profile?.ssh?.forwards ?? [])
        _automaticReconnect = State(initialValue: profile?.reconnectsAutomatically ?? false)
        _wakeOnLANMac = State(initialValue: profile?.wakeOnLANMac ?? "")
        _name = State(initialValue: profile?.name ?? "")
        _transport = State(initialValue: profile?.transport ?? .vnc)
        _host = State(initialValue: profile?.host ?? "")
        _portText = State(initialValue: profile.map { String($0.port) } ?? "")
        _username = State(initialValue: profile?.username ?? "")
        // New VNC profiles default to macOS Screen Sharing, which requires an
        // account name. Password-only VNC remains available as an explicit mode.
        _usesMacScreenSharingAuthentication = State(initialValue: profile?.usesMacScreenSharingAuthentication ?? true)
        _group = State(initialValue: profile?.group ?? "")
        _tags = State(initialValue: profile?.normalizedTags.joined(separator: ", ") ?? "")
        _logsSSHCommands = State(initialValue: profile?.logsSSHCommands ?? false)
        _requiresBiometricUnlock = State(initialValue: profile?.requiresBiometricUnlock ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(existing == nil ? "profile.new" : "profile.edit", systemImage: "display.2")
                .font(.title2.bold())
            Form {
                Section {
                    TextField("field.name", text: $name).accessibilityIdentifier("profile.name")
                    Picker("field.protocol", selection: $transport) {
                        ForEach(ProtocolRegistry.available) { Text(LocalizedStringKey($0.displayNameKey)).tag($0) }
                    }
                    .accessibilityIdentifier("profile.transport")
                    .onChange(of: transport) { old, new in
                        if portText.isEmpty || portText == String(old.defaultPort) { portText = String(new.defaultPort) }
                    }
                    TextField("field.host", text: $host).accessibilityIdentifier("profile.host")
                    TextField(String(format: NSLocalizedString("field.port.format", comment: ""), Int(transport.defaultPort)), text: $portText)
                    TextField("field.group", text: $group)
                    TextField("field.tags", text: $tags)
                }
                Section {
                    TextField(LocalizedStringKey(transport == .vnc
                        ? (usesMacScreenSharingAuthentication ? "field.vncUsernameRequired" : "field.vncUsername")
                        : "field.username"), text: $username)
                        .accessibilityLabel(Text(LocalizedStringKey(transport == .vnc
                            ? (usesMacScreenSharingAuthentication ? "field.vncUsernameRequired" : "field.vncUsername")
                            : "field.username")))
                        .accessibilityIdentifier("profile.username")
                    if transport == .vnc {
                        Picker("vnc.authenticationMode", selection: $usesMacScreenSharingAuthentication) {
                            Text("vnc.authentication.standard").tag(false)
                            Text("vnc.authentication.mac").tag(true)
                        }
                        .accessibilityIdentifier("profile.vncAuthenticationMode")
                        Text(LocalizedStringKey(usesMacScreenSharingAuthentication
                            ? "vnc.authentication.macHint"
                            : "vnc.authentication.standardHint"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("auth.vnc.hint").font(.caption).foregroundStyle(.secondary)
                    }
                    if transport == .ssh || transport == .sftp {
                        Text("ssh.authentication").font(.caption).foregroundStyle(.secondary)
                        if transport == .ssh { Toggle("ssh.log.enable", isOn: $logsSSHCommands)
                            .toggleStyle(.checkbox)
                            .disabled(!(ssh.startCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
                            .accessibilityIdentifier("profile.sshLogging")
                        Text("ssh.log.hint").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Toggle("profile.touchID", isOn: $requiresBiometricUnlock)
                        Text("profile.touchID.hint").font(.caption).foregroundStyle(.secondary)
                        if existing != nil { Toggle("field.changePassword", isOn: $changePassword) }
                        if existing == nil || changePassword || transport == .vnc {
                            SecureField("field.password", text: $password)
                                .accessibilityIdentifier("profile.password")
                            Text("field.password.hint").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                AdvancedConnectionOptions(transport: transport, ssh: $ssh, rdp: $rdp, links: $links, clipboard: $clipboard, forwards: $forwards, automaticReconnect: $automaticReconnect, wakeOnLANMac: $wakeOnLANMac)
            }.formStyle(.grouped)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("action.cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("action.save", action: save).keyboardShortcut(.defaultAction).disabled(candidate == nil).accessibilityIdentifier("profile.save")
            }
        }.padding(24).frame(width: 540, height: 650)
    }

    private var candidate: ConnectionProfile? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = portValue.isEmpty ? transport.defaultPort : UInt16(portValue), port > 0 else { return nil }
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ConnectionProfile(id: existing?.id ?? UUID(), name: cleanName.isEmpty ? cleanHost : cleanName,
                                       transport: transport, host: cleanHost, port: port,
                                       username: cleanUser.isEmpty ? nil : cleanUser,
                                       usesMacScreenSharingAuthentication: transport == .vnc && usesMacScreenSharingAuthentication,
                                       group: cleanGroup.isEmpty ? nil : cleanGroup,
                                       isFavorite: existing?.isFavorite ?? false,
                                       reconnectsAutomatically: automaticReconnect,
                                       logsSSHCommands: transport == .ssh && logsSSHCommands)
        result.ssh = ssh
        result.ssh?.forwards = forwards.isEmpty ? nil : forwards
        result.rdp = rdp
        result.links = links
        result.clipboardEnabled = clipboard
        result.wakeOnLANMac = wakeOnLANMac.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : wakeOnLANMac.trimmingCharacters(in: .whitespacesAndNewlines)
        result.requiresBiometricUnlock = transport.isGraphical && requiresBiometricUnlock
        result.tags = Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return result.isValid ? result : nil
    }

    private func save() {
        guard let profile = candidate else { return }
        do {
            let credential = Self.loginPasswordToSave(
                existingProfile: existing != nil,
                changeRequested: changePassword,
                transport: transport,
                entered: password
            )
            try profiles.save(profile, password: credential)
            password = ""
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    static func loginPasswordToSave(existingProfile: Bool, changeRequested: Bool,
                                    transport: RemoteTransport, entered: String) -> String? {
        guard transport != .ssh && transport != .sftp else { return nil }
        if !existingProfile || changeRequested { return entered }
        if transport == .vnc && !entered.isEmpty { return entered }
        return nil
    }
}
