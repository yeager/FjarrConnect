import Foundation

enum ServiceHandshake {
    enum Result: Equatable { case incomplete, matched, invalid }
    // MS-RDPBCGR 2.2.1.1: X.224 Connection Request with TLS, CredSSP and HYBRID_EX.
    // Stop after Connection Confirm; never send credentials or start a desktop session.
    static let rdpRequest = Data([3, 0, 0, 19, 14, 0xe0, 0, 0, 0, 0, 0, 1, 0, 8, 0, 11, 0, 0, 0])
    static let maximumReply = 4096

    static func inspect(_ data: Data, transport: RemoteTransport) -> Result {
        guard data.count <= maximumReply else { return .invalid }
        let bytes = Array(data)
        switch transport {
        case .vnc:
            // RFC 6143 7.1.1: a 12-byte protocol banner precedes authentication.
            guard bytes.count >= 12 else { return .incomplete }
            return Array(bytes[0..<4]) == Array("RFB ".utf8) && bytes[7] == 46 && bytes[11] == 10 &&
                [4, 5, 6, 8, 9, 10].allSatisfy { (48...57).contains(bytes[$0]) } ? .matched : .invalid
        case .rdp, .remoteApp:
            guard bytes.count >= 4 else { return .incomplete }
            let length = Int(bytes[2]) << 8 | Int(bytes[3])
            guard bytes[0] == 3, bytes[1] == 0, (11...maximumReply).contains(length) else { return .invalid }
            guard bytes.count >= length else { return .incomplete }
            guard Int(bytes[4]) + 5 == length, bytes[5] == 0xd0, bytes[10] == 0 else { return .invalid }
            if length == 11 { return .matched } // Standard RDP Security.
            guard length == 19, bytes[11] == 2 || bytes[11] == 3, bytes[13] == 8, bytes[14] == 0 else { return .invalid }
            return .matched // Negotiation response OR refusal still identifies an RDP service.
        case .ssh:
            // RFC 4253 permits informational lines before the SSH identification line.
            let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
            for bytes in lines.dropLast() {
                let line = String(decoding: bytes, as: UTF8.self)
                guard line.hasPrefix("SSH-") else { continue }
                let valid = (line.hasPrefix("SSH-2.0-") || line.hasPrefix("SSH-1.99-")) && bytes.count > 8 &&
                    (33...126).contains(Array(bytes)[8]) && bytes.count <= 255
                return valid ? .matched : .invalid
            }
            return .incomplete
        case .sftp: return .invalid
        }
    }
}
