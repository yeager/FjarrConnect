import Foundation
import AppKit
import RoyalVNCKit

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
                     health: SessionHealth? = nil, connectionPhase: String? = nil,
                     requestedSecurityProtocols: UInt32? = nil, selectedSecurityProtocol: UInt32? = nil,
                     vncSecurity: VNCNegotiatedSecurity? = nil,
                     vncTLSFailureCode: Int32? = nil,
                     inputState: UInt32? = nil,
                     now: Date = .now) -> String {
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
        let connectionTime = health?.tcpConnectionMilliseconds.map(String.init) ?? "unavailable"
        let roundTripTime = health?.roundTripMilliseconds.map(String.init) ?? "unavailable"
        let packetLoss = health?.packetLossPercent.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "unavailable"
        let knownPhases: Set<String> = ["CONNECTION_STATE_INITIAL", "CONNECTION_STATE_NEGO", "CONNECTION_STATE_NLA",
            "CONNECTION_STATE_AAD", "CONNECTION_STATE_MCS_CREATE_REQUEST", "CONNECTION_STATE_MCS_CREATE_RESPONSE",
            "CONNECTION_STATE_MCS_ERECT_DOMAIN", "CONNECTION_STATE_MCS_ATTACH_USER", "CONNECTION_STATE_MCS_ATTACH_USER_CONFIRM",
            "CONNECTION_STATE_MCS_CHANNEL_JOIN_REQUEST", "CONNECTION_STATE_MCS_CHANNEL_JOIN_RESPONSE",
            "CONNECTION_STATE_RDP_SECURITY_COMMENCEMENT", "CONNECTION_STATE_SECURE_SETTINGS_EXCHANGE",
            "CONNECTION_STATE_CONNECT_TIME_AUTO_DETECT_REQUEST", "CONNECTION_STATE_CONNECT_TIME_AUTO_DETECT_RESPONSE",
            "CONNECTION_STATE_LICENSING", "CONNECTION_STATE_MULTITRANSPORT_BOOTSTRAPPING_REQUEST",
            "CONNECTION_STATE_MULTITRANSPORT_BOOTSTRAPPING_RESPONSE", "CONNECTION_STATE_CAPABILITIES_EXCHANGE_DEMAND_ACTIVE",
            "CONNECTION_STATE_CAPABILITIES_EXCHANGE_MONITOR_LAYOUT", "CONNECTION_STATE_CAPABILITIES_EXCHANGE_CONFIRM_ACTIVE",
            "CONNECTION_STATE_FINALIZATION", "CONNECTION_STATE_ACTIVE"]
        let safePhase = connectionPhase.flatMap { knownPhases.contains($0) ? $0 : nil } ?? "unavailable"
        let hasNegotiatedProtocol = (requestedSecurityProtocols ?? 0) != 0 || (selectedSecurityProtocol ?? 0) != 0
        let negotiationInProgress = (safePhase == "CONNECTION_STATE_INITIAL" || safePhase == "CONNECTION_STATE_NEGO") &&
            !hasNegotiatedProtocol
        let safeRequestedProtocols = negotiationInProgress ? "unavailable" :
            (requestedSecurityProtocols.map { String(format: "0x%08X", $0) } ?? "unavailable")
        let safeSelectedProtocol: String
        switch negotiationInProgress ? nil : selectedSecurityProtocol {
        case .some(0): safeSelectedProtocol = "RDP"
        case .some(1): safeSelectedProtocol = "TLS"
        case .some(2): safeSelectedProtocol = "NLA"
        case .some(4): safeSelectedProtocol = "RDSTLS"
        case .some(8): safeSelectedProtocol = "NLA-Extended"
        case .some(16): safeSelectedProtocol = "RDS-AAD"
        case .none: safeSelectedProtocol = "unavailable"
        default: safeSelectedProtocol = "unknown"
        }
        func presence(_ bit: UInt32) -> String {
            guard let inputState else { return "unavailable" }
            return inputState & bit == bit ? "yes" : "no"
        }
        return [
            "FjarrConnect diagnostic report",
            "created: \(formatter.string(from: now))",
            "app-version: \(version)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "architecture: \(architecture)",
            "protocol: \(profile.transport.rawValue)",
            "state: \(state)",
            "tcp-connect-ms: \(connectionTime)",
            "rdp-round-trip-ms: \(roundTripTime)",
            "packet-loss-percent: \(packetLoss)",
            "graphics-codec: \(health?.codec ?? "unavailable")",
            "rdp-connection-phase: \(profile.transport == .rdp || profile.transport == .remoteApp ? safePhase : "unavailable")",
            "rdp-requested-security-protocols: \(profile.transport == .rdp || profile.transport == .remoteApp ? safeRequestedProtocols : "unavailable")",
            "rdp-selected-security-protocol: \(profile.transport == .rdp || profile.transport == .remoteApp ? safeSelectedProtocol : "unavailable")",
            "vnc-negotiated-security: \(profile.transport == .vnc ? vncSecurity?.rawValue ?? "unavailable" : "unavailable")",
            "vnc-tls-error-code: \(profile.transport == .vnc ? vncTLSFailureCode.map { String($0) } ?? "unavailable" : "unavailable")",
            "rdp-arguments-parsed: \(profile.transport == .rdp || profile.transport == .remoteApp ? presence(1) : "unavailable")",
            "rdp-username-configured: \(profile.transport == .rdp || profile.transport == .remoteApp ? presence(2) : "unavailable")",
            "rdp-password-configured: \(profile.transport == .rdp || profile.transport == .remoteApp ? presence(4) : "unavailable")",
            "endpoint: omitted",
            "credentials: omitted",
            "server-output: omitted",
            "failure-details: omitted"
        ].joined(separator: "\n") + "\n"
    }

    static func save(profile: ConnectionProfile, status: SessionStatus,
                     health: SessionHealth? = nil, connectionPhase: String? = nil,
                     requestedSecurityProtocols: UInt32? = nil, selectedSecurityProtocol: UInt32? = nil,
                     vncSecurity: VNCNegotiatedSecurity? = nil,
                     vncTLSFailureCode: Int32? = nil,
                     inputState: UInt32? = nil) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FjarrConnect-diagnostic.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try write(profile: profile, status: status, health: health, connectionPhase: connectionPhase,
                  requestedSecurityProtocols: requestedSecurityProtocols,
                  selectedSecurityProtocol: selectedSecurityProtocol, vncSecurity: vncSecurity,
                  vncTLSFailureCode: vncTLSFailureCode,
                  inputState: inputState, to: url)
    }

    static func write(profile: ConnectionProfile, status: SessionStatus,
                      health: SessionHealth? = nil, connectionPhase: String? = nil,
                      requestedSecurityProtocols: UInt32? = nil, selectedSecurityProtocol: UInt32? = nil,
                      vncSecurity: VNCNegotiatedSecurity? = nil,
                      vncTLSFailureCode: Int32? = nil,
                      inputState: UInt32? = nil,
                      to url: URL, now: Date = .now) throws {
        try text(profile: profile, status: status, health: health, connectionPhase: connectionPhase,
                 requestedSecurityProtocols: requestedSecurityProtocols,
                 selectedSecurityProtocol: selectedSecurityProtocol, vncSecurity: vncSecurity,
                 vncTLSFailureCode: vncTLSFailureCode,
                 inputState: inputState, now: now)
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
