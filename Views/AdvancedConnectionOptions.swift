import SwiftUI

struct AdvancedConnectionOptions: View {
    let transport: RemoteTransport
    @Binding var ssh: SSHOptions
    @Binding var rdp: RDPOptions
    @Binding var links: HostLinks
    @Binding var clipboard: Bool
    @Binding var forwards: [SSHForward]
    @Binding var automaticReconnect: Bool

    var body: some View {
        DisclosureGroup("options.title") {
            Section("session.reconnect") {
                Toggle("session.reconnect.enable", isOn: $automaticReconnect)
                Text("session.reconnect.hint").font(.caption).foregroundStyle(.secondary)
            }
            if transport.isGraphical { Toggle((transport == .rdp || transport == .remoteApp) ? "options.rdpClipboard" : "options.clipboard", isOn: $clipboard) }
            Section(transport.isGraphical ? "files.connection" : "options.ssh") {
                if transport.isGraphical {
                    Text("files.connection.hint").font(.caption).foregroundStyle(.secondary)
                    TextField("field.host", text: optional($ssh.host))
                    TextField("options.port", value: $ssh.port, format: .number)
                    TextField("field.username", text: optional($ssh.username))
                }
                HStack {
                    TextField("ssh.identity", text: optional($ssh.identityFile))
                    Button("options.choose") {
                        let panel = NSOpenPanel(); panel.showsHiddenFiles = true; panel.canChooseDirectories = false
                        if panel.runModal() == .OK { ssh.identityFile = panel.url?.path }
                    }
                }
                TextField("ssh.jump.host", text: optional($ssh.jumpHost))
                TextField("ssh.jump.port", value: $ssh.jumpPort, format: .number)
                TextField("ssh.jump.username", text: optional($ssh.jumpUsername))
                TextField("files.startDirectory", text: optional($ssh.startDirectory))
                if transport == .ssh {
                    TextField("ssh.startCommand", text: optional($ssh.startCommand))
                    Text("ssh.startCommand.hint").font(.caption).foregroundStyle(.secondary)
                }
            }
            if transport == .ssh {
                Section("ssh.keepAlive") {
                    Toggle("ssh.keepAlive.enable", isOn: Binding(
                        get: { ssh.usesKeepAlive },
                        set: { ssh.keepAlive = $0 }
                    ))
                    Text("ssh.keepAlive.hint").font(.caption).foregroundStyle(.secondary)
                }
                Section("ssh.forwards") {
                    Text("ssh.forwards.hint").font(.caption).foregroundStyle(.secondary)
                    ForEach($forwards) { $forward in
                        VStack {
                            HStack {
                                Picker("ssh.forward.direction", selection: $forward.direction) {
                                    ForEach(SSHForward.Direction.allCases, id: \.self) { Text(LocalizedStringKey("ssh.forward." + $0.rawValue)).tag($0) }
                                }.labelsHidden()
                                TextField("ssh.forward.listen", value: $forward.listenPort, format: .number).frame(width: 90)
                                Button { forwards.removeAll { $0.id == forward.id } } label: { Image(systemName: "minus.circle") }
                            }
                            if forward.direction != .dynamic {
                                HStack {
                                    TextField("ssh.forward.destination", text: $forward.destinationHost)
                                    TextField("options.port", value: $forward.destinationPort, format: .number).frame(width: 90)
                                }
                            }
                        }
                    }
                    Button("ssh.forward.add") { forwards.append(SSHForward()) }
                }
            }
            if transport == .rdp || transport == .remoteApp {
                if transport == .rdp {
                Section("rdp.display") {
                    Toggle("rdp.dynamicResolution", isOn: Binding(
                        get: { rdp.resizesRemoteDesktop },
                        set: { rdp.dynamicResolution = $0 }
                    ))
                    Text("rdp.dynamicResolution.hint").font(.caption).foregroundStyle(.secondary)
                }
                }
                Section("rdp.devices") {
                    Toggle("rdp.audio", isOn: Binding(get: { rdp.redirectsAudio }, set: { rdp.audioRedirection = $0 }))
                    Toggle("rdp.microphone", isOn: Binding(get: { rdp.redirectsMicrophone }, set: { rdp.microphoneRedirection = $0 }))
                    Text("rdp.devices.hint").font(.caption).foregroundStyle(.secondary)
                }
                if transport == .rdp {
                    Section("rdp.network") {
                        Picker("rdp.network.profile", selection: Binding(
                            get: { rdp.selectedNetworkProfile },
                            set: { rdp.networkProfile = $0 == .automatic ? nil : $0 }
                        )) {
                            ForEach(RDPOptions.NetworkProfile.allCases, id: \.self) { profile in
                                Text(LocalizedStringKey("rdp.network." + profile.rawValue)).tag(profile)
                            }
                        }
                        Text("rdp.network.hint").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if transport == .remoteApp { Section("rdp.remoteApp") {
                    TextField("rdp.remoteApp.program", text: optional($rdp.remoteApp), prompt: Text("rdp.remoteApp.example"))
                    Text("rdp.remoteApp.hint").font(.caption).foregroundStyle(.secondary)
                } }
                Section("rdp.gateway") {
                    TextField("field.host", text: optional($rdp.gatewayHost))
                    TextField("rdp.gateway.port", value: $rdp.gatewayPort, format: .number)
                    TextField("rdp.gateway.username", text: optional($rdp.gatewayUsername))
                    Text("rdp.gateway.hint").font(.caption).foregroundStyle(.secondary)
                }
                Section("rdp.folders") {
                    Text("rdp.folders.hint").font(.caption).foregroundStyle(.secondary)
                    ForEach(rdp.sharedFolders ?? [], id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button { rdp.sharedFolders?.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                        }
                    }
                    Button("rdp.folders.add") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
                        if panel.runModal() == .OK { rdp.sharedFolders = Array(Set((rdp.sharedFolders ?? []) + panel.urls.map(\.path))).sorted() }
                    }
                }
            }
            Section("links.title") {
                TextField("links.smb", text: optional($links.smb), prompt: Text("smb://"))
                TextField("links.web", text: optional($links.web), prompt: Text("https://"))
            }
        }
    }
    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
