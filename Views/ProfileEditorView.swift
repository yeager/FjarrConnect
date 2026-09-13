import SwiftUI

/// Create or edit a saved connection profile. The password is written straight to
/// the Keychain via `ProfileStore`; it never lives in the profile struct or on disk.
struct ProfileEditorView: View {
    @EnvironmentObject var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss

    private let existing: ConnectionProfile?

    @State private var name: String
    @State private var transport: RemoteTransport
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var password: String
    @State private var group: String

    init(profile: ConnectionProfile?) {
        self.existing = profile
        _name     = State(initialValue: profile?.name ?? "")
        _transport = State(initialValue: profile?.transport ?? .vnc)
        _host     = State(initialValue: profile?.host ?? "")
        _portText = State(initialValue: profile.map { String($0.port) } ?? "")
        _username = State(initialValue: profile?.username ?? "")
        _password = State(initialValue: profile.flatMap { KeychainStore.password(for: $0.id) } ?? "")
        _group    = State(initialValue: profile?.group ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "profile.new" : "profile.edit")
                .font(.title2).bold()

            Form {
                TextField("field.name", text: $name)

                Picker("field.protocol", selection: $transport) {
                    ForEach(ProtocolRegistry.available) { t in
                        Text(LocalizedStringKey(t.displayNameKey)).tag(t)
                    }
                }
                .onChange(of: transport) { _, newValue in
                    if portText.isEmpty { portText = String(newValue.defaultPort) }
                }

                TextField("field.host", text: $host)
                TextField(placeholderPort, text: $portText)
                TextField("field.username", text: $username)
                SecureField("field.password", text: $password)
                TextField("field.group", text: $group)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("action.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("action.save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || host.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var placeholderPort: String {
        String(format: NSLocalizedString("field.port.format", comment: ""),
               Int(transport.defaultPort))
    }

    private func save() {
        let port = UInt16(portText) ?? transport.defaultPort
        var profile = existing ?? ConnectionProfile(name: name, transport: transport, host: host)
        profile.name = name
        profile.transport = transport
        profile.host = host
        profile.port = port
        profile.username = username.isEmpty ? nil : username
        profile.group = group.isEmpty ? nil : group

        if existing == nil {
            profiles.add(profile, password: password)
        } else {
            profiles.update(profile, password: password)
        }
        dismiss()
    }
}
