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
    @State private var password = ""
    @State private var changePassword = false
    @State private var group: String
    @State private var errorMessage: String?

    init(profile: ConnectionProfile?) {
        existing = profile
        _name = State(initialValue: profile?.name ?? "")
        _transport = State(initialValue: profile?.transport ?? .vnc)
        _host = State(initialValue: profile?.host ?? "")
        _portText = State(initialValue: profile.map { String($0.port) } ?? "")
        _username = State(initialValue: profile?.username ?? "")
        _group = State(initialValue: profile?.group ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(existing == nil ? "profile.new" : "profile.edit", systemImage: "display.2")
                .font(.title2.bold())
            Form {
                Section {
                    TextField("field.name", text: $name)
                    Picker("field.protocol", selection: $transport) {
                        ForEach(ProtocolRegistry.available) { Text(LocalizedStringKey($0.displayNameKey)).tag($0) }
                    }
                    .onChange(of: transport) { old, new in
                        if portText.isEmpty || portText == String(old.defaultPort) { portText = String(new.defaultPort) }
                    }
                    TextField("field.host", text: $host)
                    TextField(String(format: NSLocalizedString("field.port.format", comment: ""), Int(transport.defaultPort)), text: $portText)
                    TextField("field.group", text: $group)
                }
                Section {
                    TextField("field.username", text: $username)
                    if transport == .ssh {
                        Text("ssh.authentication").font(.caption).foregroundStyle(.secondary)
                    } else {
                        if existing != nil { Toggle("field.changePassword", isOn: $changePassword) }
                        if existing == nil || changePassword {
                            SecureField("field.password", text: $password)
                            Text("field.password.hint").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.formStyle(.grouped)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("action.cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("action.save", action: save).keyboardShortcut(.defaultAction).disabled(candidate == nil)
            }
        }.padding(24).frame(width: 480)
    }

    private var candidate: ConnectionProfile? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = portValue.isEmpty ? transport.defaultPort : UInt16(portValue), port > 0 else { return nil }
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = ConnectionProfile(id: existing?.id ?? UUID(), name: cleanName.isEmpty ? cleanHost : cleanName,
                                       transport: transport, host: cleanHost, port: port,
                                       username: cleanUser.isEmpty ? nil : cleanUser, group: cleanGroup.isEmpty ? nil : cleanGroup)
        return result.isValid ? result : nil
    }

    private func save() {
        guard let profile = candidate else { return }
        do {
            let credential: String? = transport == .ssh ? nil : (existing == nil || changePassword ? password : nil)
            try profiles.save(profile, password: credential)
            password = ""
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
