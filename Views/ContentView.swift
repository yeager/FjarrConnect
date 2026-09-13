import SwiftUI

struct ContentView: View {
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var discovery: BonjourBrowser
    @EnvironmentObject var connection: ConnectionManager

    @State private var quickConnect = ""
    @State private var editing: ConnectionProfile?
    @State private var showingNew = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 240)
        } detail: {
            detail
        }
        .sheet(isPresented: $showingNew) {
            ProfileEditorView(profile: nil)
        }
        .sheet(item: $editing) { profile in
            ProfileEditorView(profile: profile)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List {
            Section {
                HStack {
                    TextField("quickconnect.placeholder", text: $quickConnect)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(runQuickConnect)
                    Button(action: runQuickConnect) {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(quickConnect.isEmpty)
                }
            }

            Section("sidebar.saved") {
                ForEach(profiles.grouped, id: \.group) { bucket in
                    if profiles.grouped.count > 1 {
                        Text(bucket.group).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(bucket.profiles) { profile in
                        profileRow(profile)
                    }
                }
                if profiles.profiles.isEmpty {
                    Text("sidebar.saved.empty").foregroundStyle(.secondary)
                }
            }

            Section("sidebar.discovered") {
                ForEach(discovery.hosts) { host in
                    Button {
                        connectDiscovered(host)
                    } label: {
                        Label(host.name, systemImage: "bonjour")
                    }
                    .buttonStyle(.plain)
                }
                if discovery.hosts.isEmpty {
                    Text("sidebar.discovered.empty").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { showingNew = true } label: { Image(systemName: "plus") }
                    .help("profile.new")
            }
        }
    }

    private func profileRow(_ profile: ConnectionProfile) -> some View {
        Button {
            connection.connect(profile)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                    Text(profile.uri)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon(for: profile.transport))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("action.edit") { editing = profile }
            Button("action.delete", role: .destructive) { profiles.remove(profile) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let session = connection.session {
            VStack(spacing: 0) {
                HStack {
                    Text(session.profile.name).font(.headline)
                    Spacer()
                    Text(session.status.label).foregroundStyle(.secondary)
                    Button("action.disconnect") { connection.disconnect() }
                }
                .padding(8)
                Divider()
                session.makeScreenView()
            }
        } else {
            ContentUnavailableView(
                "detail.empty.title",
                systemImage: "display.2",
                description: Text("detail.empty.description")
            )
        }
    }

    // MARK: Actions

    private func runQuickConnect() {
        guard let profile = ConnectionURI.profile(from: quickConnect) else { return }
        connection.connect(profile)
        quickConnect = ""
    }

    private func connectDiscovered(_ host: DiscoveredHost) {
        discovery.resolve(host) { resolvedHost, port in
            let profile = ConnectionProfile(name: host.name, transport: .vnc,
                                            host: resolvedHost, port: port)
            DispatchQueue.main.async { connection.connect(profile) }
        }
    }

    private func icon(for transport: RemoteTransport) -> String {
        switch transport {
        case .vnc: return "display"
        case .rdp: return "pc"
        case .ssh: return "terminal"
        }
    }
}
