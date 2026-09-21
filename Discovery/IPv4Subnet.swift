import Foundation
import Darwin

struct IPv4Subnet: Equatable {
    let network: UInt32
    let prefix: Int
    var description: String { "\(Self.address(network))/\(prefix)" }
    var addressCount: Int { 1 << (32 - prefix) }
    var hostCount: Int { prefix < 31 ? addressCount - 2 : addressCount }
    var hosts: [String] {
        let first = prefix < 31 ? 1 : 0
        let end = prefix < 31 ? addressCount - 1 : addressCount
        return (first..<end).map { Self.address(network + UInt32($0)) }
    }

    /// A scan is deliberately bounded, including when a VPN supplies a very large subnet.
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = Self.number(String(parts[0])),
              let prefix = Int(parts[1]), (20...32).contains(prefix) else { return nil }
        let mask = UInt32.max << (32 - prefix)
        let network = address & mask
        guard network >> 24 > 0, (network + UInt32((1 << (32 - prefix)) - 1)) >> 24 < 224 else { return nil }
        self.network = network
        self.prefix = prefix
    }

    static func number(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard !octet.isEmpty, octet.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt8(octet) else { return nil }
            result = result << 8 | UInt32(value)
        }
        return result
    }
    static func address(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }

    static func localSuggestions() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var result = Set<String>()
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let pointer = interface.ifa_addr, pointer.pointee.sa_family == AF_INET,
                  let maskPointer = interface.ifa_netmask else { continue }
            let address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Keep small interface subnets intact; suggest just the local /24 on larger LANs.
            let prefix = max(24, mask.nonzeroBitCount)
            if let subnet = IPv4Subnet("\(Self.address(address))/\(prefix)") { result.insert(subnet.description) }
        }
        return result.sorted()
    }
}
