import Foundation
import Network

enum WakeOnLAN {
    static func isValidMAC(_ value: String) -> Bool { bytes(for: value) != nil }

    static func magicPacket(mac: String) -> Data? {
        guard let mac = bytes(for: mac) else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(mac) }
        return packet
    }

    static func send(mac: String, completion: @escaping (Bool) -> Void) {
        guard let packet = magicPacket(mac: mac) else { completion(false); return }
        let connection = NWConnection(host: "255.255.255.255", port: 9, using: .udp)
        let resultLock = NSLock()
        var completed = false
        func finish(_ sent: Bool) {
            resultLock.lock()
            defer { resultLock.unlock() }
            guard !completed else { return }
            completed = true
            completion(sent)
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { finish(false); connection.cancel() }
        }
        connection.start(queue: DispatchQueue(label: "se.fjarrconnect.wol"))
        connection.send(content: packet, completion: .contentProcessed { error in
            finish(error == nil); connection.cancel()
        })
    }

    private static func bytes(for value: String) -> Data? {
        let pieces = value.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard pieces.count == 6 else { return nil }
        var result = Data(); result.reserveCapacity(6)
        for piece in pieces {
            guard piece.count == 2, let byte = UInt8(piece, radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }
}

struct SSHOptions: Codable, Hashable {
    var host: String?
    var port: UInt16?
    var username: String?
    var identityFile: String?
    var jumpHost: String?
    var jumpPort: UInt16?
    var jumpUsername: String?
    var forwards: [SSHForward]?
    var startDirectory: String?
    /// Passed as one remote SSH command, never through a local shell.
    var startCommand: String?
    // Nil keeps existing profiles protected from idle network timeouts.
    var keepAlive: Bool?

    var usesKeepAlive: Bool { keepAlive ?? true }

    var isValid: Bool {
        (host.map(ConnectionURI.validHost) ?? true) && (port ?? 22) > 0 &&
        (username.map(ConnectionOptions.validValue) ?? true) &&
        (identityFile.map { $0.hasPrefix("/") && ConnectionOptions.validValue($0) } ?? true) &&
        (jumpHost.map(ConnectionOptions.validJumpHost) ?? true) && (jumpPort ?? 22) > 0 &&
        (jumpUsername.map { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } } ?? true) &&
        (forwards ?? []).allSatisfy(\.isValid) &&
        (startDirectory.map(ConnectionOptions.validValue) ?? true) &&
        (startCommand.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ConnectionOptions.validValue($0) } ?? true)
    }

    var jumpDestination: String? {
        guard let jumpHost else { return nil }
        let host = ConnectionOptions.bracketed(jumpHost)
        return (jumpUsername.map { $0 + "@" } ?? "") + host + ":\(jumpPort ?? 22)"
    }
}

struct SSHForward: Codable, Hashable, Identifiable {
    enum Direction: String, Codable, CaseIterable { case local, remote, dynamic }
    var id = UUID()
    var direction: Direction = .local
    var listenPort: UInt16 = 8080
    var destinationHost: String = "localhost"
    var destinationPort: UInt16 = 80
    var isValid: Bool {
        listenPort > 0 && (direction == .dynamic ||
            (ConnectionOptions.validJumpHost(destinationHost) && destinationPort > 0))
    }
    var arguments: [String] {
        if direction == .dynamic { return ["-D", "127.0.0.1:\(listenPort)"] }
        return [direction == .local ? "-L" : "-R",
                "127.0.0.1:\(listenPort):\(ConnectionOptions.bracketed(destinationHost)):\(destinationPort)"]
    }
}

struct RDPOptions: Codable, Hashable {
    enum SecurityMode: String, Codable, CaseIterable {
        case automatic, nla, tls, rdp

        var freeRDPValue: String? {
            switch self {
            case .automatic: return nil
            case .nla: return "nla"
            case .tls: return "tls"
            case .rdp: return "rdp"
            }
        }
    }

    enum NetworkProfile: String, Codable, CaseIterable {
        case automatic, slow, balanced, lan

        var freeRDPValue: String? {
            switch self {
            case .automatic: return nil
            case .slow: return "modem"
            case .balanced: return "broadband-high"
            case .lan: return "lan"
            }
        }
    }
    var gatewayHost: String?
    var gatewayPort: UInt16?
    var gatewayUsername: String?
    var sharedFolders: [String]?
    // A Windows RemoteApp executable or alias, for example "||wordpad".
    // Nil means a full desktop session.
    var remoteApp: String? = nil
    // Nil keeps profiles saved before this preference dynamically sized.
    var dynamicResolution: Bool?
    /// Nil leaves FreeRDP's automatic security negotiation enabled.
    var securityMode: SecurityMode?
    /// Nil preserves FreeRDP's automatic network selection for older profiles.
    var networkProfile: NetworkProfile?

    var resizesRemoteDesktop: Bool { dynamicResolution ?? true }
    var selectedSecurityMode: SecurityMode { securityMode ?? .automatic }
    var selectedNetworkProfile: NetworkProfile { networkProfile ?? .automatic }
    var remoteAppProgram: String? {
        let program = remoteApp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return program.isEmpty ? nil : program
    }

    var isValid: Bool {
        (gatewayHost.map(ConnectionURI.validHost) ?? true) && (gatewayPort ?? 443) > 0 &&
        (gatewayUsername.map(ConnectionOptions.validValue) ?? true) &&
        (sharedFolders ?? []).allSatisfy { $0.hasPrefix("/") && !$0.contains(",") && ConnectionOptions.validValue($0) } &&
        (remoteApp.map(ConnectionOptions.validValue) ?? true)
    }
}

struct HostLinks: Codable, Hashable {
    var smb: String?
    var web: String?
    var isValid: Bool {
        (smb.map { Self.url($0, scheme: "smb") != nil } ?? true) &&
        (web.map { Self.url($0, scheme: "https") != nil } ?? true)
    }
    static func url(_ value: String, scheme: String) -> URL? {
        guard ConnectionOptions.validValue(value),
              let parts = URLComponents(string: value), parts.scheme?.lowercased() == scheme,
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              (parts.port.map { (1...65535).contains($0) } ?? true),
              scheme != "smb" || (parts.query == nil && parts.fragment == nil) else { return nil }
        return parts.url
    }
}

enum ConnectionOptions {
    static func validValue(_ value: String) -> Bool { !value.contains(where: { $0.isNewline || $0.asciiValue == 0 }) }
    static func bracketed(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }
    static func validJumpHost(_ host: String) -> Bool {
        ConnectionURI.validHost(host) && (!host.contains("%") || host.contains(":")) &&
        host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-%:".contains($0)) }
    }
}

struct SessionCredentials {
    var password: String?
    var gatewayPassword: String?
}
