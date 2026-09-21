import SwiftUI

struct NetworkDiscoveryView: View {
    @ObservedObject var scanner: NetworkScanner
    let choose: (ConnectionProfile, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var subnet = ""
    @State private var suggestions: [String] = []
    @State private var selected: UUID?
    @State private var vnc = true
    @State private var rdp = true
    @State private var ssh = true
    @State private var vncPorts = "5900,5901"
    @State private var rdpPorts = "3389"
    @State private var sshPorts = "22"

    private var services: [ScanService]? {
        var result: [ScanService] = []
        for (enabled, transport, text) in [(vnc, RemoteTransport.vnc, vncPorts), (rdp, .rdp, rdpPorts), (ssh, .ssh, sshPorts)] where enabled {
            guard let ports = ScanService.ports(text) else { return nil }
            result += ports.map { ScanService(transport: transport, port: $0) }
        }
        guard let range = IPv4Subnet(subnet), !result.isEmpty, range.hostCount * result.count <= 16384 else { return nil }
        return result
    }
    private var selectedHost: ScannedHost? { scanner.hosts.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("discovery.scan.title", systemImage: "network").font(.title2.bold())
            Text("discovery.scan.hint").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("discovery.scan.range", text: $subnet).accessibilityIdentifier("scan.range")
                if !suggestions.isEmpty {
                    Menu("discovery.scan.local") {
                        ForEach(suggestions, id: \.self) { value in Button(value) { subnet = value } }
                    }.fixedSize()
                }
            }.disabled(scanner.isScanning)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("field.protocol"); Text("discovery.scan.ports") }.font(.caption).foregroundStyle(.secondary)
                serviceRow("VNC", enabled: $vnc, ports: $vncPorts, id: "vnc")
                serviceRow("RDP", enabled: $rdp, ports: $rdpPorts, id: "rdp")
                serviceRow("SSH", enabled: $ssh, ports: $sshPorts, id: "ssh")
            }.disabled(scanner.isScanning)
            if services == nil { Text("discovery.scan.invalid").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if scanner.isScanning {
                    ProgressView(value: Double(scanner.completed), total: Double(max(1, scanner.total)))
                    Text(String(format: NSLocalizedString("discovery.scan.progress", comment: ""), scanner.completed, scanner.total))
                        .font(.caption).monospacedDigit().fixedSize()
                    Button("action.cancel") { scanner.stop() }.accessibilityIdentifier("scan.stop")
                } else {
                    Text(String(format: NSLocalizedString("discovery.scan.count", comment: ""), scanner.hosts.count)).foregroundStyle(.secondary)
                    if scanner.state == .cancelled { Text("discovery.scan.cancelled").font(.caption) }
                    Spacer()
                    Button("discovery.scan.start") { start() }
                        .disabled(services == nil).accessibilityIdentifier("scan.start")
                }
            }
            if let error = scanner.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            List(selection: $selected) {
                ForEach(scanner.hosts) { host in
                    HStack {
                        Label(host.address, systemImage: host.service.transport.symbol)
                        Spacer()
                        Text("\(host.service.transport.rawValue.uppercased()) · \(host.service.port)").foregroundStyle(.secondary)
                    }.padding(.vertical, 3).contentShape(Rectangle()).tag(host.id)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { choose(host.profile, true) })
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("scan.host.\(host.service.transport.rawValue).\(host.address)")
                }
            }.overlay {
                if scanner.hosts.isEmpty && !scanner.isScanning && scanner.state != .idle {
                    Text("discovery.scan.empty").foregroundStyle(.secondary).padding().multilineTextAlignment(.center)
                }
            }
            HStack {
                Button("action.close") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("scan.close")
                Spacer()
                Button("action.save") { if let host = selectedHost { choose(host.profile, false) } }
                    .disabled(selectedHost == nil).accessibilityIdentifier("scan.save")
                Button("action.connect") { if let host = selectedHost { choose(host.profile, true) } }
                    .disabled(selectedHost == nil).accessibilityIdentifier("scan.connect")
            }
        }.padding(24).frame(width: 600, height: 610)
            .onAppear {
                suggestions = IPv4Subnet.localSuggestions()
                if subnet.isEmpty { subnet = scanner.lastSubnet ?? suggestions.first ?? "" }
                if !scanner.lastServices.isEmpty {
                    let ports: (RemoteTransport) -> String = { transport in scanner.lastServices.filter { $0.transport == transport }.map { String($0.port) }.sorted().joined(separator: ",") }
                    vnc = !ports(.vnc).isEmpty; vncPorts = vnc ? ports(.vnc) : "5900,5901"
                    rdp = !ports(.rdp).isEmpty; rdpPorts = rdp ? ports(.rdp) : "3389"
                    ssh = !ports(.ssh).isEmpty; sshPorts = ssh ? ports(.ssh) : "22"
                }
            }
            .onDisappear { scanner.stop() }
    }
    private func serviceRow(_ title: String, enabled: Binding<Bool>, ports: Binding<String>, id: String) -> some View {
        GridRow {
            Toggle(title, isOn: enabled).toggleStyle(.checkbox).accessibilityIdentifier("scan.enable.\(id)")
            TextField("discovery.scan.ports", text: ports).labelsHidden().disabled(!enabled.wrappedValue)
                .accessibilityIdentifier("scan.ports.\(id)")
        }
    }
    private func start() {
        guard let range = IPv4Subnet(subnet), let services else { return }
        subnet = range.description; selected = nil
        scanner.start(subnet: range, services: services)
    }
}
