import Foundation

/// One parser for quick connect, profile validation and imported addresses.
/// Reject credentials in URLs: passwords belong in the Keychain or an auth prompt.
enum ConnectionURI {
    static func profile(from string: String) -> ConnectionProfile? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let normalized = text.contains("://") ? text : "vnc://\(text)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let transport = RemoteTransport(rawValue: scheme),
              let rawHost = components.host,
              components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        guard validHost(host) else { return nil }
        // URLComponents can represent integers beyond UInt16. Never use a trapping conversion.
        let rawPort = components.port ?? Int(transport.defaultPort)
        guard (1...65535).contains(rawPort) else { return nil }
        let username = components.user.flatMap { $0.isEmpty ? nil : $0 }
        guard username?.contains(where: { $0.isNewline || $0.asciiValue == 0 }) != true else { return nil }
        return ConnectionProfile(name: host, transport: transport, host: host,
                                 port: UInt16(rawPort), username: username)
    }

    static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.hasPrefix("/"),
              !host.contains(where: { $0.isWhitespace || $0.asciiValue == 0 }),
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\@?#[]")) == nil else { return false }
        return true
    }
}
