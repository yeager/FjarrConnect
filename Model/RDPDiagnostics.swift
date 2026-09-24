import Foundation
import AppKit

/// Retains only known FreeRDP error categories, never backend log messages.
struct RDPDiagnostics {
    enum Failure: String {
        case network, authentication, certificate, account

        var priority: Int {
            switch self {
            case .network: return 0
            case .certificate: return 1
            case .authentication: return 2
            case .account: return 3
            }
        }
    }

    private(set) var failure: Failure?
    private var tail = Data()

    mutating func consume(_ data: Data) {
        // Match across pipe-read boundaries while keeping memory bounded.
        let text = String(decoding: tail + data, as: UTF8.self)
        let codes: [(Failure, [String])] = [
            (.network, ["ERRCONNECT_CONNECT_FAILED", "ERRCONNECT_DNS_NAME_NOT_FOUND",
                        "ERRCONNECT_CONNECT_TRANSPORT_FAILED"]),
            (.certificate, ["ERRCONNECT_TLS_CONNECT_FAILED"]),
            (.authentication, ["ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_AUTHENTICATION_FAILED",
                               "ERRCONNECT_WRONG_PASSWORD", "ERRCONNECT_ACCESS_DENIED"]),
            (.account, ["ERRCONNECT_PASSWORD_EXPIRED", "ERRCONNECT_PASSWORD_CERTAINLY_EXPIRED", "ERRCONNECT_PASSWORD_MUST_CHANGE",
                        "ERRCONNECT_ACCOUNT_LOCKED_OUT", "ERRCONNECT_ACCOUNT_DISABLED",
                        "ERRCONNECT_ACCOUNT_EXPIRED", "ERRCONNECT_LOGON_TYPE_NOT_GRANTED"])
        ]
        for (candidate, tokens) in codes where tokens.contains(where: text.contains) {
            if failure == nil || candidate.priority > failure!.priority { failure = candidate }
        }
        // No raw diagnostics escape this parser or get persisted.
        tail = Data((tail + data).suffix(96))
    }

    func message(host: String, port: UInt16, exitCode: Int32) -> String {
        let key = failure.map { "rdp.error.\($0.rawValue)" } ?? "rdp.ended"
        let detail = NSLocalizedString(key, comment: "")
        return "RDP \(host):\(port)\n\(detail)\n" +
            "\(NSLocalizedString("rdp.exitCode", comment: "")) \(exitCode)"
    }
}

/// A user-saveable connection report with no credentials or raw backend output.
enum DiagnosticReport {
    static func text(profile: ConnectionProfile, status: SessionStatus,
                     health: SessionHealth? = nil, now: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        let state: String
        switch status {
        case .disconnected(let reason): state = reason == nil ? "disconnected" : "failed"
        case .idle: state = "idle"
        case .connecting: state = "connecting"
        case .connected: state = "connected"
        case .running: state = "running"
        case .disconnecting: state = "disconnecting"
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let latency = health?.latencyMilliseconds.map(String.init) ?? "unavailable"
        let packetLoss = health?.packetLossPercent.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "unavailable"
        return [
            "FjarrConnect diagnostic report",
            "created: \(formatter.string(from: now))",
            "app-version: \(version)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "architecture: \(architecture)",
            "protocol: \(profile.transport.rawValue)",
            "state: \(state)",
            "tcp-handshake-ms: \(latency)",
            "packet-loss-percent: \(packetLoss)",
            "graphics-codec: \(health?.codec ?? "unavailable")",
            "endpoint: omitted",
            "credentials: omitted",
            "server-output: omitted",
            "failure-details: omitted"
        ].joined(separator: "\n") + "\n"
    }

    static func save(profile: ConnectionProfile, status: SessionStatus,
                     health: SessionHealth? = nil) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FjarrConnect-diagnostic.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try write(profile: profile, status: status, health: health, to: url)
    }

    static func write(profile: ConnectionProfile, status: SessionStatus,
                      health: SessionHealth? = nil, to url: URL, now: Date = .now) throws {
        try text(profile: profile, status: status, health: health, now: now)
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
