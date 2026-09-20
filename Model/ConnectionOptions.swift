import Foundation

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

    var isValid: Bool {
        (host.map(ConnectionURI.validHost) ?? true) && (port ?? 22) > 0 &&
        (username.map(ConnectionOptions.validValue) ?? true) &&
        (identityFile.map { $0.hasPrefix("/") && ConnectionOptions.validValue($0) } ?? true) &&
        (jumpHost.map(ConnectionOptions.validJumpHost) ?? true) && (jumpPort ?? 22) > 0 &&
        (jumpUsername.map { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } } ?? true) &&
        (forwards ?? []).allSatisfy(\.isValid) &&
        (startDirectory.map(ConnectionOptions.validValue) ?? true)
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
    var gatewayHost: String?
    var gatewayPort: UInt16?
    var gatewayUsername: String?
    var sharedFolders: [String]?
    var isValid: Bool {
        (gatewayHost.map(ConnectionURI.validHost) ?? true) && (gatewayPort ?? 443) > 0 &&
        (gatewayUsername.map(ConnectionOptions.validValue) ?? true) &&
        (sharedFolders ?? []).allSatisfy { $0.hasPrefix("/") && !$0.contains(",") && ConnectionOptions.validValue($0) }
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
