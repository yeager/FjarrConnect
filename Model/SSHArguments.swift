import Foundation

enum SSHArguments {
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
