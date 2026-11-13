import Foundation
import SwiftUI

struct UnitConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var awayAddress: String? = nil      // optional "my.public.address:port" used when away from home (no VPN)
}

/// The list of aircons, saved on the phone. Also owns the background refresh.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var units: [AirconUnit] = []
    @Published private(set) var demo = false

    private(set) var operatorId: String
    private(set) var deviceId: String
    private var pollTask: Task<Void, Never>? = nil
    private let defaults = UserDefaults.standard

    static let pollSeconds: UInt64 = 8
    static let maxUnits = 8

    init() {
        // Random ids that identify this phone to the adapters (the adapter keeps a list of up to 4 remote controls).
        if let o = defaults.string(forKey: "operatorId"), let d = defaults.string(forKey: "deviceId") {
            operatorId = o
            deviceId = d
        } else {
            operatorId = UUID().uuidString.lowercased()
            deviceId = UUID().uuidString.lowercased()
            defaults.set(operatorId, forKey: "operatorId")
            defaults.set(deviceId, forKey: "deviceId")
        }
        demo = defaults.bool(forKey: "demo")
        if let data = defaults.data(forKey: "units"), let list = try? JSONDecoder().decode([UnitConfig].self, from: data) {
            configs = list
        }
        rebuild()
    }

    /// The saved (real) aircons. Kept separately, so turning demo mode on never throws them away.
    private(set) var configs: [UnitConfig] = []

    // MARK: editing the list

    func save(_ list: [UnitConfig]) {
        demo = false
        defaults.set(false, forKey: "demo")
        configs = list
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: "units") }
        rebuild()
        refreshAllNow()
    }

    /// Demo mode shows two pretend aircons with random names and settings. Your real list is kept and comes back when you switch it off.
    func setDemo(_ on: Bool) {
        demo = on
        defaults.set(on, forKey: "demo")
        rebuild()
        refreshAllNow()
    }

    /// Roll new random demo aircons.
    func shuffleDemo() {
        guard demo else { return }
        rebuild(newDemo: true)
    }

    private func rebuild(newDemo: Bool = false) {
        if demo {
            if newDemo || !units.contains(where: { $0.isDemo }) {
                units = AirconUnitFactory.demoUnits(operatorId: operatorId, deviceId: deviceId)
            }
            return
        }
        // Keep a unit that didn't change: it is already registered with its adapter.
        var next: [AirconUnit] = []
        for c in configs {
            if let old = units.first(where: { !$0.isDemo && $0.config == c }) { next.append(old) }
            else { next.append(AirconUnit(config: c, operatorId: operatorId, deviceId: deviceId)) }
        }
        units = next
    }

    func validate(_ list: [UnitConfig]) -> String? {
        if list.count > Store.maxUnits { return "At most \(Store.maxUnits) aircons." }
        var seen = Set<String>()
        for (i, u) in list.enumerated() {
            let name = u.name.trimmingCharacters(in: .whitespaces)
            let host = u.host.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.count > 40 { return "Aircon \(i + 1): give it a name (max 40 characters)." }
            if !Store.isValidHost(host) { return "Aircon \(i + 1): '\(host)' is not a valid IP address or host name (no http://, no port)." }
            if seen.contains(host.lowercased()) { return "Aircon \(i + 1): the address \(host) is used twice." }
            if let a = u.awayAddress?.trimmingCharacters(in: .whitespaces), !a.isEmpty, Store.parseAway(a) == nil {
                return "Aircon \(i + 1): the away address must look like my-address.example.com:51444 (a name or IP, then : and a port)."
            }
            seen.insert(host.lowercased())
        }
        return nil
    }

    /// "host:port" -> (host, port). The port defaults to 51443.
    nonisolated static func parseAway(_ text: String) -> (String, Int)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return isValidHost(parts[0]) ? (parts[0], 51443) : nil }
        if parts.count == 2, isValidHost(parts[0]), let p = Int(parts[1]), (1...65535).contains(p) { return (parts[0], p) }
        return nil
    }

    nonisolated static func isValidHost(_ host: String) -> Bool {
        if host.isEmpty || host.count > 253 { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        if host.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }
        return !host.hasPrefix("-") && !host.hasPrefix(".") && !host.hasSuffix("-") && !host.hasSuffix(".")
    }

    // MARK: refreshing

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.refreshAll()
                try? await Task.sleep(nanoseconds: Store.pollSeconds * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshAll() async {
        let current = units
        await withTaskGroup(of: Void.self) { group in
            for u in current { group.addTask { await u.refresh() } }
        }
    }

    func refreshAllNow() {
        let current = units
        for u in current { Task { await u.refresh() } }
    }

    /// Test one address (the "Test connection" button): does an aircon adapter answer there?
    func test(host: String) async -> (ok: Bool, message: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        if !Store.isValidHost(h) { return (false, "That is not a valid IP address or host name.") }
        let client = WfRacClient(host: h, operatorId: operatorId, deviceId: deviceId, timeZone: TimeZone.current.identifier)
        do {
            _ = try await client.airconId()
            return (true, "Found it")
        } catch {
            return (false, friendlyError(error))
        }
    }
}

@MainActor
enum AirconUnitFactory {
    static func demoUnits(operatorId: String, deviceId: String) -> [AirconUnit] {
        return DemoSpec.randomPair().map { name, spec in
            AirconUnit(config: UnitConfig(name: name, host: "demo-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"),
                       operatorId: operatorId, deviceId: deviceId, demo: spec)
        }
    }
}
