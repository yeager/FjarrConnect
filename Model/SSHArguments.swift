import Foundation

enum SSHArguments {
    static func environment(from source: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var environment = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8"]
        for key in ["HOME", "USER", "LOGNAME", "PATH", "SSH_AUTH_SOCK", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"] {
            if let value = source[key] { environment[key] = value }
        }
        if environment["PATH"] == nil { environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    static func make(_ profile: ConnectionProfile) -> [String] {
        var args = ["-tt", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
                    "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=ask",
                    "-p", String(profile.port)]
        if let username = profile.username, !username.isEmpty { args += ["-l", username] }
        // A host can never become a local command-line option.
        args += ["--", profile.host]
        return args
    }
}
