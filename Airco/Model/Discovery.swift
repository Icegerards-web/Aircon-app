import Foundation
import Network

struct FoundAdapter: Identifiable {
    var id: String { host }
    let host: String
    let airconId: String
}

struct ScanResult {
    var scanned = 0
    var networks: [String] = []
    var found: [FoundAdapter] = []
}

/// Finds the aircons' Wi-Fi adapters on the home network.
/// How: every adapter listens on TCP port 51443. We try to open that port on every address of the /24 networks
/// the phone is on (e.g. 192.168.1.1-254). Few devices have it open, so a hit is a good candidate; each candidate
/// is then asked "who are you?" (the same request the Smart M-Air app uses), and lookalikes are dropped.
enum Discovery {
    static let port: UInt16 = 51443

    /// The /24 networks this phone is on, as prefixes like "192.168.1."
    static func localPrefixes() -> [String] {
        var prefixes: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(sa.pointee.sa_len)
                if getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: buf)
                    let parts = ip.split(separator: ".").compactMap { Int($0) }
                    if parts.count == 4, isPrivate(parts) {
                        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
                        if !prefixes.contains(prefix) { prefixes.append(prefix) }
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return Array(prefixes.prefix(3))
    }

    private static func isPrivate(_ p: [Int]) -> Bool {
        if p[0] == 10 { return true }
        if p[0] == 192 && p[1] == 168 { return true }
        if p[0] == 172 && (16...31).contains(p[1]) { return true }
        return false
    }

    static func scan(operatorId: String, deviceId: String) async -> ScanResult {
        let prefixes = localPrefixes()
        var result = ScanResult()
        result.networks = prefixes.map { $0 + "0/24" }
        var hosts: [String] = []
        for p in prefixes { for i in 1...254 { hosts.append("\(p)\(i)") } }
        result.scanned = hosts.count

        // 1. Which addresses have port 51443 open? (in batches, so we don't open too many sockets at once)
        var candidates: [String] = []
        let batch = 100
        var start = 0
        while start < hosts.count {
            let slice = Array(hosts[start..<min(start + batch, hosts.count)])
            let open = await withTaskGroup(of: String?.self) { group -> [String] in
                for h in slice { group.addTask { await portOpen(h, timeout: 1.2) ? h : nil } }
                var hits: [String] = []
                for await r in group { if let h = r { hits.append(h) } }
                return hits
            }
            candidates.append(contentsOf: open)
            start += batch
        }

        // 2. Ask each candidate who it is.
        let tz = TimeZone.current.identifier
        let found = await withTaskGroup(of: FoundAdapter?.self) { group -> [FoundAdapter] in
            for h in candidates {
                group.addTask {
                    let client = WfRacClient(host: h, operatorId: operatorId, deviceId: deviceId, timeZone: tz)
                    if let id = try? await client.airconId() { return FoundAdapter(host: h, airconId: id) }
                    return nil
                }
            }
            var list: [FoundAdapter] = []
            for await r in group { if let f = r { list.append(f) } }
            return list
        }
        result.found = found.sorted { sortKey($0.host) < sortKey($1.host) }
        return result
    }

    private static func sortKey(_ host: String) -> Int {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count != 4 { return Int.max }
        return ((parts[0] * 256 + parts[1]) * 256 + parts[2]) * 256 + parts[3]
    }

    private final class Once {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    static func portOpen(_ host: String, timeout: TimeInterval) async -> Bool {
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            guard let p = NWEndpoint.Port(rawValue: port) else { cont.resume(returning: false); return }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let once = Once()
            let finish: (Bool) -> Void = { ok in
                if once.fire() {
                    conn.cancel()
                    cont.resume(returning: ok)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
