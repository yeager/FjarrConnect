import SwiftUI

struct ContentView: View {
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var discovery: BonjourBrowser
    @EnvironmentObject var connection: ConnectionManager
    @StateObject private var scanner = NetworkScanner()
    @State private var showingNetworkSearch = false
    @State private var discoveredAction: (profile: ConnectionProfile, connect: Bool)?
    @State private var quickConnect = ""
    @State private var search = ""
    @State private var selectedProfileID: UUID?
    @State private var editing: ConnectionProfile?
    @State private var showingNew = false
    @State private var credentials: ConnectionProfile?
    @State private var deleting: ConnectionProfile?
    @State private var commandLog: ConnectionProfile?
    @State private var errorMessage: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage(AppSettings.showSidebar) private var showSidebar = true
    @AppStorage(AppSettings.useLargeControls) private var useLargeControls = false
    @AppStorage(AppSettings.autoHideSidebarWhileConnected) private var autoHideSidebarWhileConnected = false
    @AppStorage(AppSettings.autoHideSessionTabsWhileConnected) private var autoHideSessionTabsWhileConnected = false
    @FocusState private var quickFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar.navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if !connection.tabs.isEmpty {
                    if !autoHideSessionTabsWhileConnected || !connection.hasActiveSessions {
                        SessionTabBar(tabs: connection.tabs, selectedID: connection.selectedID,
                                      select: { connection.selectedID = $0 }, close: { connection.requestClose($0) })
                        .frame(height: 56)
                        .background(.bar, ignoresSafeAreaEdges: [])
                        Divider()
                    }
                    if let tab = connection.selected {
                        SessionDetailView(tab: tab, reconnect: {
                            let saved = profiles.profiles.first { $0.id == tab.backend.profile.id } ?? tab.backend.profile
                            let current = tab.backend.profile.transport == .sftp ? saved.fileProfile : saved
                            requestConnect(current, forcePrompt: true)
                        },
                                          close: { connection.requestClose(tab.id) },
                                          openFiles: { connection.connect(tab.backend.profile.fileProfile) })
                            .id(tab.id)
                    }
                } else { welcome }
            }
        }
        .navigationTitle("FjärrConnect")
        .controlSize(useLargeControls ? .large : .regular)
        .onAppear(perform: syncSidebarVisibility)
        .onChange(of: showSidebar) { _, _ in syncSidebarVisibility() }
        .onChange(of: autoHideSidebarWhileConnected) { _, _ in syncSidebarVisibility() }
        .onChange(of: connection.hasActiveSessions) { _, _ in syncSidebarVisibility() }
        .onChange(of: columnVisibility) { _, _ in syncSidebarVisibility() }
        .toolbar {
            ToolbarItemGroup {
                Button { quickFocused = true } label: { Image(systemName: "bolt") }
                    .help("action.quickConnect").keyboardShortcut("k")
                Button { showingNew = true } label: { Image(systemName: "plus") }
                    .help("profile.new").keyboardShortcut("n").accessibilityIdentifier("newConnection")
            }
        }
        .sheet(isPresented: $showingNetworkSearch, onDismiss: applyDiscoveredAction) {
            NetworkDiscoveryView(scanner: scanner) { profile, connect in
                discoveredAction = (profile, connect)
                showingNetworkSearch = false
            }
        }
        .onDisappear { scanner.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .connectSavedProfile)) { notification in
            guard let id = notification.object as? UUID,
                  let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
            requestConnect(profile)
        }
        .sheet(isPresented: $showingNew) { ProfileEditorView(profile: nil) }
        .sheet(item: $editing) { ProfileEditorView(profile: $0) }
        .sheet(item: $commandLog) { SSHCommandLogView(profile: $0) }
        .onChange(of: profiles.profiles) { _, saved in
            if let selectedProfileID, !saved.contains(where: { $0.id == selectedProfileID }) {
                self.selectedProfileID = nil
            }
            for tab in connection.tabs {
                guard let session = tab.backend as? SSHRemoteSession else { continue }
                session.updateLoggingPreference(saved.first { $0.id == session.profile.id }?.logsSSHCommands ?? false)
            }
        }
        .sheet(item: $credentials) { profile in
            CredentialsView(profile: profile, saved: profiles.profiles.contains { $0.id == profile.id }) { candidate, password, gatewayPassword, remember in
                do {
                    if remember { try profiles.save(candidate, password: password, gatewayPassword: gatewayPassword) }
                    connection.connect(candidate, password: password, gatewayPassword: gatewayPassword)
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

    private var keepsSidebarVisible: Bool {
        showSidebar && !(autoHideSidebarWhileConnected && connection.hasActiveSessions)
    }

    private func syncSidebarVisibility() {
        let target: NavigationSplitViewVisibility = keepsSidebarVisible ? .all : .detailOnly
        if columnVisibility != target { columnVisibility = target }
    }

    private var sidebar: some View {
        List(selection: $selectedProfileID) {
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
            if !profiles.recent.isEmpty {
                Section("sidebar.recent") {
                    ForEach(profiles.recent.filter { matches($0) }) { profile in profileRow(profile) }
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
                ForEach(discovery.hosts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.transport.rawValue.localizedCaseInsensitiveContains(search) }) { host in
                    Button {
                        discovery.resolve(host) { result in
                            switch result {
                            case .success(let endpoint):
                                requestConnect(ConnectionProfile(name: host.name, transport: host.transport, host: endpoint.host, port: endpoint.port))
                            case .failure(let error): errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Label(host.name, systemImage: host.transport.symbol)
                            Spacer()
                            Text(host.transport.rawValue.uppercased()).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }.buttonStyle(.plain)
                }
                if let error = discovery.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                else if discovery.hosts.isEmpty { Text("sidebar.discovered.empty").font(.caption).foregroundStyle(.secondary) }
                Button("action.refresh") { discovery.stop(); discovery.start() }.font(.caption)
                Button("discovery.scan.title") { showingNetworkSearch = true }
                    .font(.caption).accessibilityIdentifier("network.scan")
            }
            if !scanner.hosts.isEmpty {
                Section("discovery.scan.results") {
                    ForEach(scanner.hosts.filter { matches($0.profile) }) { host in
                        HStack {
                            Button { selectedProfileID = host.id } label: {
                                Label(host.profile.uri, systemImage: host.service.transport.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .simultaneousGesture(TapGesture(count: 2).onEnded { requestConnect(host.profile) })
                                .accessibilityAction(named: Text("action.connect")) { requestConnect(host.profile) }
                            Button { saveDiscovered(host.profile) } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless).help("action.save").accessibilityLabel(Text("action.save"))
                        }.tag(host.id)
                    }
                }
            }
        }.listStyle(.sidebar).searchable(text: $search, prompt: Text("search.placeholder"))
    }

    private func profileRow(_ profile: ConnectionProfile) -> some View {
        HStack(spacing: 6) {
            Button { selectedProfileID = profile.id } label: {
                HStack(spacing: 10) {
                    Image(systemName: profile.transport.symbol).foregroundStyle(.tint).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name).font(.body.weight(.medium))
                        Text(profile.uri).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { requestConnect(profile) })
                .accessibilityAction(named: Text("action.connect")) { requestConnect(profile) }
                .accessibilityIdentifier("connect.\(profile.name)")
            Button { toggleFavorite(profile) } label: {
                Image(systemName: profile.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(profile.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(profile.isFavorite ? "favorite.remove" : "favorite.add")
            .accessibilityLabel(Text(profile.isFavorite ? "favorite.remove" : "favorite.add"))
            .accessibilityValue(Text(profile.name))
            .accessibilityIdentifier("favorite.\(profile.name)")
        }.tag(profile.id).contextMenu {
            Button("action.connect") { requestConnect(profile) }
            Button("files.title") { connection.connect(profile.fileProfile) }
            Button("links.smb") { if let url = profile.serviceURL("smb") { NSWorkspace.shared.open(url) } }
            Button("links.web") { if let url = profile.serviceURL("https") { NSWorkspace.shared.open(url) } }
            if let mac = profile.wakeOnLANMac {
                Button("wol.wake") { WakeOnLAN.send(mac: mac) { [weak profiles] sent in
                    guard !sent else { return }
                    DispatchQueue.main.async { profiles?.errorMessage = NSLocalizedString("wol.error", comment: "") }
                } }
            }
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

    private func applyDiscoveredAction() {
        guard let action = discoveredAction else { return }
        discoveredAction = nil
        if action.connect { requestConnect(action.profile) } else { saveDiscovered(action.profile) }
    }

    private func saveDiscovered(_ profile: ConnectionProfile) {
        if let existing = profiles.profiles.first(where: {
            $0.host.caseInsensitiveCompare(profile.host) == .orderedSame && $0.port == profile.port && $0.transport == profile.transport
        }) { selectedProfileID = existing.id; return }
        do { try profiles.save(profile, password: nil); selectedProfileID = profile.id }
        catch { errorMessage = error.localizedDescription }
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
        search.isEmpty || ([profile.name, profile.host, profile.group ?? "", profile.transport.rawValue] + profile.normalizedTags)
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }
    private func runQuickConnect() {
        guard let profile = ConnectionURI.profile(from: quickConnect) else {
            errorMessage = NSLocalizedString("quickconnect.invalid", comment: ""); return
        }
        requestConnect(profile)
    }
    private func requestConnect(_ profile: ConnectionProfile, forcePrompt: Bool = false) {
        profiles.markUsed(profile.id)
        if profile.transport == .ssh || profile.transport == .sftp { connection.connect(profile); return }
        if (profile.transport == .rdp || profile.transport == .remoteApp) && !RDPRemoteSession.isAvailable {
            errorMessage = NSLocalizedString("rdp.install", comment: ""); return
        }
        guard profile.requiresBiometricUnlock else {
            continueConnect(profile, forcePrompt: forcePrompt)
            return
        }
        ProfileAccessAuthenticator.authenticate(reason: NSLocalizedString("profile.touchID.reason", comment: "")) { result in
            DispatchQueue.main.async {
                switch result {
                case .success: self.continueConnect(profile, forcePrompt: forcePrompt)
                case .failure: self.errorMessage = NSLocalizedString("profile.touchID.failed", comment: "")
                }
            }
        }
    }

    private func continueConnect(_ profile: ConnectionProfile, forcePrompt: Bool) {
        do {
            if !forcePrompt, let password = try KeychainStore.password(for: profile.id) {
                let gatewayPassword = profile.rdp?.gatewayUsername == nil ? nil : try KeychainStore.password(for: profile.id, purpose: .gateway)
                if profile.rdp?.gatewayUsername != nil && gatewayPassword == nil { credentials = profile }
                else { connection.connect(profile, password: password, gatewayPassword: gatewayPassword) }
            } else { credentials = profile }
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct SessionDetailView: View {
    @ObservedObject var tab: SessionTab
    let reconnect: () -> Void
    let close: () -> Void
    let openFiles: () -> Void
    @State private var showingCommandLog = false
    @State private var showingFileTransferSuggestion = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.backend.profile.name).font(.headline)
                    Text(tab.backend.profile.uri).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(tab.backend.status.label).font(.callout).foregroundStyle(.secondary)
                SessionHealthMenu(health: tab.health, reconnectAttempt: tab.reconnectAttempt)
                if let attempt = tab.reconnectAttempt {
                    Text(String(format: NSLocalizedString("session.reconnect.status", comment: ""), attempt, 3))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("session.reconnecting")
                }
                if tab.canRecord {
                    if tab.recorder.isRecording {
                        Label("record.recording", systemImage: "record.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("recording.indicator")
                    }
                    Button {
                        if tab.recorder.isRecording { tab.stopRecording() }
                        else { tab.startRecording() }
                    } label: {
                        Image(systemName: tab.recorder.isRecording ? "stop.circle.fill" : "record.circle")
                            .foregroundStyle(tab.recorder.isRecording ? .red : .primary)
                    }
                    .help(tab.recorder.isRecording ? "record.stop" : "record.start")
                    .accessibilityIdentifier("session.record")
                    .disabled(!tab.recorder.isRecording && (tab.backend.status.isFinished || !tab.backend.status.isActive))
                }
                if tab.backend.profile.transport == .ssh {
                    Button { showingCommandLog = true } label: { Image(systemName: "lock.doc") }
                        .help("ssh.log.title")
                }
                if tab.backend.profile.transport.isGraphical {
                    Button(action: openFiles) { Image(systemName: "folder.badge.plus") }
                        .help("files.title")
                        .accessibilityIdentifier("session.files")
                }
                if tab.backend.status.isFinished && tab.reconnectAttempt == nil { Button("action.reconnect", action: reconnect) }
                Button("action.disconnect", action: close)
            }.padding(12).background(.bar)
            Divider()
            if let error = tab.backend.status.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("diagnostics.save") { DiagnosticReport.save(profile: tab.backend.profile, status: tab.backend.status) }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = tab.backend.notice {
                Label(notice, systemImage: "info.circle").foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let recordingError = tab.recorder.errorMessage {
                Label(recordingError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if tab.backend.status.isFinished && tab.backend.profile.transport != .ssh {
                ContentUnavailableView("status.disconnected", systemImage: "network.slash", description: Text("session.retry"))
            } else {
                tab.backend.makeScreenView()
                    .dropDestination(for: URL.self) { urls, _ in
                        guard tab.backend.profile.transport.isGraphical,
                              urls.allSatisfy(\.isFileURL) else { return false }
                        showingFileTransferSuggestion = true
                        return true
                    }
            }
        }
        .sheet(isPresented: $showingCommandLog) { SSHCommandLogView(profile: tab.backend.profile) }
        .confirmationDialog("files.drop.title", isPresented: $showingFileTransferSuggestion, titleVisibility: .visible) {
            Button("files.title", action: openFiles)
            Button("action.cancel", role: .cancel) {}
        } message: { Text("files.drop.hint") }
    }
}

private struct SessionHealthMenu: View {
    let health: SessionHealth
    let reconnectAttempt: Int?

    var body: some View {
        Menu {
            Text("health.title").font(.headline)
            Divider()
            healthRow("health.latency", value: health.latencyMilliseconds.map { String(format: NSLocalizedString("health.latency.value", comment: ""), $0) } ?? NSLocalizedString("health.unavailable", comment: ""))
            healthRow("health.packetLoss", value: health.packetLossPercent.map { String(format: NSLocalizedString("health.packetLoss.value", comment: ""), $0) } ?? NSLocalizedString("health.packetLoss.unavailable", comment: ""))
            healthRow("health.codec", value: health.codec ?? NSLocalizedString("health.unavailable", comment: ""))
            healthRow("health.reconnect", value: reconnectAttempt.map { String(format: NSLocalizedString("health.reconnect.value", comment: ""), $0, 3) } ?? NSLocalizedString("health.reconnect.none", comment: ""))
        } label: {
            Image(systemName: "chart.bar.xaxis")
        }
        .help("health.title")
        .accessibilityIdentifier("session.health")
    }

    @ViewBuilder
    private func healthRow(_ key: LocalizedStringKey, value: String) -> some View {
        HStack { Text(key); Spacer(); Text(value).foregroundStyle(.secondary) }
    }
}

extension RemoteTransport {
    var symbol: String {
        switch self { case .vnc: return "display"; case .rdp, .remoteApp: return "pc"; case .ssh: return "terminal"; case .sftp: return "folder" }
    }
}
