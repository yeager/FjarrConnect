import Foundation

enum RDPArguments {
    static func input(profile: ConnectionProfile, password: String?) -> Data? {
        let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
        var args = ["/v:\(host):\(profile.port)", "/dynamic-resolution", "/size:1280x800",
                    "/title:FjärrConnect", "/log-level:ERROR"]
        if let username = profile.username, !username.isEmpty { args.append("/u:\(username)") }
        if let password { args.append("/p:\(password)") }
        // FreeRDP's args-from format is one argument per line, with no quoting.
        guard args.allSatisfy({ !$0.contains(where: { $0.isNewline || $0.asciiValue == 0 }) }) else { return nil }
        return Data((args.joined(separator: "\n") + "\n").utf8)
    }
}
