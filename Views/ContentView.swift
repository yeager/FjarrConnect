import SwiftUI

struct ContentView: View {
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var discovery: BonjourBrowser
    @EnvironmentObject var connection: ConnectionManager
    @State private var quickConnect = ""
    @State private var search = ""
    @State private var editing: ConnectionProfile?
    @State private var showingNew = false
    @State private var credentials: ConnectionProfile?
    @State private var deleting: ConnectionProfile?
    @State private var commandLog: ConnectionProfile?
    @State private var errorMessage: String?
    @FocusState private var quickFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if !connection.tabs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(connection.tabs) { tab in
                                SessionTabLabel(tab: tab, selected: connection.selectedID == tab.id,
                                                select: { connection.selectedID = tab.id }, close: { connection.close(tab.id) })
                            }
                        }.padding(8)
                    }.background(.bar)
                    Divider()
                    if let tab = connection.selected {
                        SessionDetailView(tab: tab, reconnect: { requestConnect(tab.backend.profile, forcePrompt: true) },
                                          close: { connection.close(tab.id) })
                            .id(tab.id)
                    }
                } else { welcome }
            }
        }
        .navigationTitle("FjärrConnect")
        .toolbar {
            ToolbarItemGroup {
                Button { quickFocused = true } label: { Image(systemName: "bolt") }
                    .help("action.quickConnect").keyboardShortcut("k")
                Button { showingNew = true } label: { Image(systemName: "plus") }
                    .help("profile.new").keyboardShortcut("n").accessibilityIdentifier("newConnection")
            }
        }
        .sheet(isPresented: $showingNew) { ProfileEditorView(profile: nil) }
        .sheet(item: $editing) { ProfileEditorView(profile: $0) }
        .sheet(item: $commandLog) { SSHCommandLogView(profile: $0) }
        .onChange(of: profiles.profiles) { _, saved in
            for tab in connection.tabs {
                guard let session = tab.backend as? SSHRemoteSession else { continue }
                session.updateLoggingPreference(saved.first { $0.id == session.profile.id }?.logsSSHCommands ?? false)
            }
        }
        .sheet(item: $credentials) { profile in
            CredentialsView(profile: profile, saved: profiles.profiles.contains { $0.id == profile.id }) { candidate, password, remember in
                do {
                    if remember { try profiles.save(candidate, password: password) }
                    connection.connect(candidate, password: password)
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("error.title", isPresented: Binding(get: { errorMessage != nil || profiles.errorMessage != nil },
                                                  set: { if !$0 { errorMessage = nil; profiles.errorMessage = nil } })) {
            Button("action.ok", role: .cancel) { errorMessage = nil; profiles.errorMessage = nil }
        } message: { Text(errorMessage ?? profiles.errorMessage ?? "") }
        .confirmationDialog("profile.delete.title", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("action.delete", role: .destructive) {
                guard let profile = deleting else { return }
                for tab in connection.tabs.filter({ $0.backend.profile.id == profile.id }) { connection.close(tab.id) }
                do { try profiles.remove(profile) } catch { errorMessage = error.localizedDescription }
                deleting = nil
            }
        } message: { Text(deleting?.name ?? "") }
    }

    private var sidebar: some View {
        List {
            Section("action.quickConnect") {
                HStack(spacing: 8) {
                    TextField("quickconnect.placeholder", text: $quickConnect)
                        .textFieldStyle(.roundedBorder).focused($quickFocused).onSubmit(runQuickConnect)
                    Button(action: runQuickConnect) { Image(systemName: "arrow.right.circle.fill").font(.title3) }
                        .buttonStyle(.borderless).help("action.connect")
                        .disabled(quickConnect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.vertical, 4)
            }
            if !profiles.favorites.isEmpty {
                Section("sidebar.favorites") {
                    ForEach(profiles.favorites.filter { matches($0) }) { profile in profileRow(profile) }
                }
            }
            Section("sidebar.saved") {
                ForEach(profiles.grouped, id: \.group) { bucket in
                    let visible = bucket.profiles.filter { matches($0) }
                    if !visible.isEmpty {
                        if profiles.grouped.count > 1 { Text(bucket.group).font(.caption).foregroundStyle(.secondary) }
                        ForEach(visible) { profile in profileRow(profile) }
                    }
                }
                if profiles.profiles.isEmpty { Text("sidebar.saved.empty").foregroundStyle(.secondary) }
                else if profiles.profiles.filter({ matches($0) }).isEmpty { Text("search.empty").foregroundStyle(.secondary) }
            }
            Section("sidebar.discovered") {
                ForEach(discovery.hosts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { host in
                    Button {
                        discovery.resolve(host) { result in
                            switch result {
                            case .success(let endpoint):
                                requestConnect(ConnectionProfile(name: host.name, host: endpoint.host, port: endpoint.port))
                            case .failure(let error): errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label(host.name, systemImage: "bonjour").padding(.vertical, 3)
                    }.buttonStyle(.plain)
                }
                if discovery.hosts.isEmpty {
                    Text(discovery.errorMessage ?? NSLocalizedString("sidebar.discovered.empty", comment: ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("action.refresh") { discovery.stop(); discovery.start() }.font(.caption)
            }
        }.listStyle(.sidebar).searchable(text: $search, prompt: Text("search.placeholder"))
    }

    private func profileRow(_ profile: ConnectionProfile) -> some View {
        HStack(spacing: 6) {
            Button { requestConnect(profile) } label: {
                HStack(spacing: 10) {
                    Image(systemName: profile.transport.symbol).foregroundStyle(.tint).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name).font(.body.weight(.medium))
                        Text(profile.uri).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { toggleFavorite(profile) } label: {
                Image(systemName: profile.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(profile.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(profile.isFavorite ? "favorite.remove" : "favorite.add")
            .accessibilityLabel(Text(profile.isFavorite ? "favorite.remove" : "favorite.add"))
            .accessibilityValue(Text(profile.name))
            .accessibilityIdentifier("favorite.\(profile.name)")
        }.contextMenu {
            Button("action.connect") { requestConnect(profile) }
            Button(profile.isFavorite ? "favorite.remove" : "favorite.add") { toggleFavorite(profile) }
            Button("action.edit") { editing = profile }
            if profile.transport == .ssh {
                Button(profile.logsSSHCommands ? "ssh.log.disable" : "ssh.log.enable") {
                    var updated = profile
                    updated.logsSSHCommands.toggle()
                    do { try profiles.save(updated, password: nil) } catch { errorMessage = error.localizedDescription }
                }
            }
            if profile.transport == .ssh {
                Button("ssh.log.title") { commandLog = profile }
            }
            Button("action.copyAddress") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(profile.uri, forType: .string) }
            Divider()
            Button("action.delete", role: .destructive) { deleting = profile }
        }
    }

    private func toggleFavorite(_ profile: ConnectionProfile) {
        do { try profiles.toggleFavorite(profile.id) } catch { errorMessage = error.localizedDescription }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 108, height: 108)
            VStack(spacing: 10) {
                Text("welcome.title").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("detail.empty.description").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
            }
            HStack(spacing: 12) {
                Button("profile.new") { showingNew = true }.buttonStyle(.borderedProminent)
                Button("action.quickConnect") { quickFocused = true }.buttonStyle(.bordered)
            }.controlSize(.large)
            HStack(spacing: 22) {
                Label("VNC", systemImage: "display")
                Label("SSH", systemImage: "terminal")
                Label("RDP", systemImage: "pc")
            }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [Color.accentColor.opacity(0.08), Color(nsColor: .windowBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func matches(_ profile: ConnectionProfile) -> Bool {
        search.isEmpty || [profile.name, profile.host, profile.group ?? "", profile.transport.rawValue]
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }
    private func runQuickConnect() {
        guard let profile = ConnectionURI.profile(from: quickConnect) else {
            errorMessage = NSLocalizedString("quickconnect.invalid", comment: ""); return
        }
        requestConnect(profile)
    }
    private func requestConnect(_ profile: ConnectionProfile, forcePrompt: Bool = false) {
        if profile.transport == .ssh { connection.connect(profile); return }
        if profile.transport == .rdp && RDPRemoteSession.executable == nil {
            errorMessage = NSLocalizedString("rdp.install", comment: ""); return
        }
        do {
            if !forcePrompt, let password = try KeychainStore.password(for: profile.id) {
                connection.connect(profile, password: password)
            } else { credentials = profile }
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct SessionTabLabel: View {
    @ObservedObject var tab: SessionTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                Label(tab.backend.profile.name, systemImage: tab.backend.profile.transport.symbol).lineLimit(1)
            }.buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain).help("action.closeSession")
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SessionDetailView: View {
    @ObservedObject var tab: SessionTab
    let reconnect: () -> Void
    let close: () -> Void
    @State private var showingCommandLog = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.backend.profile.name).font(.headline)
                    Text(tab.backend.profile.uri).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(tab.backend.status.label).font(.callout).foregroundStyle(.secondary)
                if tab.backend.profile.transport == .ssh {
                    Button { showingCommandLog = true } label: { Image(systemName: "lock.doc") }
                        .help("ssh.log.title")
                }
                if tab.backend.status.isFinished { Button("action.reconnect", action: reconnect) }
                Button("action.disconnect", action: close)
            }.padding(12).background(.bar)
            Divider()
            if let error = tab.backend.status.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = tab.backend.notice {
                Label(notice, systemImage: "info.circle").foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if tab.backend.status.isFinished && tab.backend.profile.transport != .ssh {
                ContentUnavailableView("status.disconnected", systemImage: "network.slash", description: Text("session.retry"))
            } else { tab.backend.makeScreenView() }
        }
        .sheet(isPresented: $showingCommandLog) { SSHCommandLogView(profile: tab.backend.profile) }
    }
}

extension RemoteTransport {
    var symbol: String {
        switch self { case .vnc: return "display"; case .rdp: return "pc"; case .ssh: return "terminal" }
    }
}
