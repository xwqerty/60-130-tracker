// Local-network helpers for adapter discovery on iOS.
//
// iOS won't let us UDP-broadcast for the gateway without Apple's multicast
// entitlement, so instead: read the phone's own WiFi IP, and if the known
// adapter IPs don't answer, TCP-sweep that /24 for something listening on
// the HSFZ port. Plain unicast — no entitlement needed.

import Foundation

/// The phone's IPv4 address on WiFi (en0), if any.
func wifiIPv4() -> String? {
    var result: String?
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
    defer { freeifaddrs(ifaddrPtr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              String(cString: ifa.ifa_name) == "en0" else { continue }
        var addrIn = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
        result = String(cString: inet_ntoa(addrIn.sin_addr))
    }
    return result
}

/// Sweep `prefix`.1-254 for a host accepting TCP on the HSFZ port.
/// Returns the first responder (there's realistically only the gateway).
func scanSubnet(prefix: String, excluding own: String) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        for i in 1...254 {
            let host = "\(prefix).\(i)"
            if host == own { continue }
            group.addTask {
                let client = HsfzClient(host: host, connectTimeout: 2.0)
                defer { client.close() }
                do {
                    try await client.connect()
                    return host
                } catch {
                    return nil
                }
            }
        }
        for await found in group where found != nil {
            group.cancelAll()
            return found
        }
        return nil
    }
}
