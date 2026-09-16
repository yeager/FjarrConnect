import Foundation

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
