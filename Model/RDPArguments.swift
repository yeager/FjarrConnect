import Foundation

enum RDPArguments {
    static func input(profile: ConnectionProfile, password: String?, gatewayPassword: String? = nil) -> Data? {
        guard profile.isValid else { return nil }
        let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
        let title = profile.name.components(separatedBy: .controlCharacters).joined(separator: " ")
        var args = ["/v:\(host):\(profile.port)", "/size:1280x800",
                    "/title:FjärrConnect — \(title)", "/log-level:OFF"]
        // RemoteApp owns its window layout on the server; desktop resizing is
        // only valid for a full desktop session.
        if profile.rdp?.resizesRemoteDesktop ?? true, profile.transport == .rdp { args.append("/dynamic-resolution") }
        args.append(profile.sharesClipboard ? "+clipboard" : "-clipboard")
        if profile.rdp?.redirectsAudio == true { args.append("/sound:sys:mac") }
        if profile.rdp?.redirectsMicrophone == true { args.append("/microphone:sys:mac") }
        if profile.transport == .remoteApp, let remoteApp = profile.rdp?.remoteAppProgram { args.append("/app:\(remoteApp)") }
        for (index, path) in (profile.rdp?.sharedFolders ?? []).enumerated() {
            args.append("/drive:Shared\(index + 1),\(path)")
        }
        if let gateway = profile.rdp?.gatewayHost {
            var options = ["g:\(ConnectionOptions.bracketed(gateway)):\(profile.rdp?.gatewayPort ?? 443)"]
            if let user = profile.rdp?.gatewayUsername {
                options.append("u:" + escapeGatewayValue(user))
                if let gatewayPassword { options.append("p:" + escapeGatewayValue(gatewayPassword)) }
            }
            args.append("/gateway:" + options.joined(separator: ","))
        }
        if let username = profile.username, !username.isEmpty { args.append("/u:\(username)") }
        if let password { args.append("/p:\(password)") }
        // In-memory bridge format: one argument per line, with no quoting.
        guard args.allSatisfy({ !$0.contains(where: { $0.isNewline || $0.asciiValue == 0 }) }) else { return nil }
        return Data((args.joined(separator: "\n") + "\n").utf8)
    }

    private static func escapeGatewayValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
    }
}
