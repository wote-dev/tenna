import Foundation

enum NetworkInterface {

    /// Every IPv4 address a phone could plausibly reach this Mac on, best first.
    ///
    /// All of them are published rather than one best guess: on a hotspot the address
    /// that works is on the tether or `bridge` interface, not on `en0`, and nothing here
    /// can tell which network the phone is currently sitting on. The phone tries the
    /// whole list, so a wrong entry costs one short connect timeout.
    static func allIPv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var candidates: [(rank: Int, order: Int, addr: String)] = []

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard isReachableInterface(name) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let addr = String(cString: host)

            // 169.254.x.x means DHCP failed. Nothing will ever answer there.
            guard !addr.hasPrefix("169.254."), addr != "0.0.0.0" else { continue }
            candidates.append((rank(name), candidates.count, addr))
        }

        // `sorted` is not stable, so the discovery order is carried explicitly.
        let ordered = candidates
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .map(\.addr)

        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    /// Best-guess LAN address to embed in the pairing QR, so pairing works even
    /// where mDNS is blocked. Bonjour remains the primary discovery path.
    static func primaryIPv4() -> String? { allIPv4().first }

    /// en0 is Wi-Fi on Apple silicon laptops; `bridge*` is where Internet Sharing puts
    /// the phone's side of a Mac-hosted hotspot.
    private static func rank(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        if name.hasPrefix("bridge") { return 2 }
        return 3
    }

    /// Interfaces a phone can never reach us on: peer-to-peer radios, VPN tunnels and
    /// the various virtual adapters that carry addresses but route nothing useful.
    private static func isReachableInterface(_ name: String) -> Bool {
        let excluded = ["awdl", "llw", "utun", "ipsec", "ppp", "gif", "stf", "anpi", "XHC"]
        return !excluded.contains { name.hasPrefix($0) }
    }
}
