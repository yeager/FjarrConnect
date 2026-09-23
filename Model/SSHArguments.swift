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
        var arguments = ["-tt"] + connection(profile, includeForwards: true) + ["--", profile.host]
        if let command = profile.ssh?.startCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            arguments.append(command)
        }
        return arguments
    }

    static func connection(_ profile: ConnectionProfile, includeForwards: Bool = false) -> [String] {
        var args = ["-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=ask",
                    "-p", String(profile.port)]
        if profile.ssh?.usesKeepAlive ?? true {
            // OpenSSH sends encrypted protocol keep-alives only; nothing is written to the shell or command log.
            args += ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        }
        if let username = profile.username, !username.isEmpty { args += ["-l", username] }
        if let identity = profile.ssh?.identityFile { args += ["-i", identity] }
        if let jump = profile.ssh?.jumpDestination { args += ["-J", jump] }
        if includeForwards {
            for forward in profile.ssh?.forwards ?? [] { args += forward.arguments }
            if profile.ssh?.forwards?.isEmpty == false { args += ["-o", "ExitOnForwardFailure=yes"] }
        }
        return args
    }
}
