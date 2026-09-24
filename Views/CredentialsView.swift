import SwiftUI

struct CredentialsView: View {
    let profile: ConnectionProfile
    let saved: Bool
    let connect: (ConnectionProfile, String, String?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var usesMacScreenSharingAuthentication: Bool
    @State private var password = ""
    @State private var gatewayPassword = ""
    @State private var remember = false

    init(profile: ConnectionProfile, saved: Bool, connect: @escaping (ConnectionProfile, String, String?, Bool) -> Void) {
        self.profile = profile
        self.saved = saved
        self.connect = connect
        _username = State(initialValue: profile.username ?? "")
        _usesMacScreenSharingAuthentication = State(initialValue: profile.usesMacScreenSharingAuthentication)
    }

    var allowsVNCAuthenticationModeSelection: Bool {
        profile.transport == .vnc && !profile.usesMacScreenSharingAuthentication
    }

    var requiresVNCUsername: Bool {
        profile.transport == .vnc &&
            (profile.usesMacScreenSharingAuthentication || usesMacScreenSharingAuthentication)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("auth.title", systemImage: "lock.shield").font(.title2.bold())
            Text(profile.uri).foregroundStyle(.secondary).textSelection(.enabled)
            // A profile marked for Apple Screen Sharing must keep using its
            // account-based authentication here. Let users choose a mode only
            // for profiles that have not been identified/configured as Mac.
            if allowsVNCAuthenticationModeSelection {
                Picker("vnc.authenticationMode", selection: $usesMacScreenSharingAuthentication) {
                    Text("vnc.authentication.standard").tag(false)
                    Text("vnc.authentication.mac").tag(true)
                }
                .accessibilityIdentifier("auth.vncAuthenticationMode")
            }
            TextField(LocalizedStringKey(profile.transport == .vnc
                ? (requiresVNCUsername ? "field.vncUsernameRequired" : "field.vncUsername")
                : "field.username"), text: $username)
                .accessibilityLabel(Text(LocalizedStringKey(profile.transport == .vnc
                    ? (requiresVNCUsername ? "field.vncUsernameRequired" : "field.vncUsername")
                    : "field.username")))
                .accessibilityIdentifier("auth.username")
            SecureField("field.password", text: $password).accessibilityIdentifier("auth.password")
            if profile.rdp?.gatewayHost != nil, let gatewayUser = profile.rdp?.gatewayUsername {
                Text(gatewayUser).font(.caption).foregroundStyle(.secondary)
                SecureField("rdp.gateway.password", text: $gatewayPassword)
            }
            Text(LocalizedStringKey(profile.transport == .vnc ? "auth.vnc.hint" : "auth.hint"))
                .font(.caption).foregroundStyle(.secondary)
            if saved { Toggle("auth.remember", isOn: $remember) }
            HStack {
                Button("action.cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("auth.cancel")
                Spacer()
                Button("action.connect") {
                    var candidate = profile
                    let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    candidate.username = user.isEmpty ? nil : user
                    candidate.usesMacScreenSharingAuthentication = requiresVNCUsername
                    connect(candidate, password, profile.rdp?.gatewayUsername == nil ? nil : gatewayPassword, remember)
                    password = ""; gatewayPassword = ""
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(requiresVNCUsername &&
                              username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("auth.connect")
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 420)
    }
}
