import Foundation
import SwiftUI

let modeKeys = ["auto", "cool", "heat", "fan", "dry"]      // index == the protocol's mode number
let modeNames = ["Auto", "Cool", "Heat", "Fan", "Dry"]
let fanNames = ["Auto", "Quiet", "Low", "Med", "High"]
let vaneNames = ["Swing", "Wide", "Mid", "Steep", "Down"]
let lrNames = ["Swing", "Left", "Left-center", "Center", "Right-center", "Right", "Spread", "Focus"]

/// A set of changes the user asked for. Only the fields that are set get sent.
struct Change: Equatable {
    var power: Bool?
    var mode: Int?
    var temp: Double?
    var fan: Int?
    var vane: Int?
    var lr: Int?
    var entrust: Bool?

    var isEmpty: Bool { power == nil && mode == nil && temp == nil && fan == nil && vane == nil && lr == nil && entrust == nil }

    mutating func merge(_ o: Change) {
        if let v = o.power { power = v }
        if let v = o.mode { mode = v }
        if let v = o.temp { temp = v }
        if let v = o.fan { fan = v }
        if let v = o.vane { vane = v }
        if let v = o.lr { lr = v }
        if let v = o.entrust { entrust = v }
    }

    var summary: String {
        var parts: [String] = []
        if let v = power { parts.append("power \(v ? "on" : "off")") }
        if let v = mode { parts.append("mode \(modeNames[safe: v] ?? "?")") }
        if let v = temp { parts.append("temperature \(v)°C") }
        if let v = fan { parts.append("fan \(fanNames[safe: v] ?? "?")") }
        if let v = vane { parts.append("up/down \(vaneNames[safe: v] ?? "?")") }
        if let v = lr { parts.append("left/right \(lrNames[safe: v] ?? "?")") }
        if let v = entrust { parts.append("3D auto \(v ? "on" : "off")") }
        return parts.joined(separator: ", ")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { return (i >= 0 && i < count) ? self[i] : nil }
}

/// One aircon as the screens see it. It remembers what the unit last reported, what we just asked for,
/// and whether the unit actually did it. (Port of `RealUnit` / `BaseUnit` from the Python tool.)
@MainActor
final class AirconUnit: ObservableObject, Identifiable {
    let config: UnitConfig
    nonisolated var id: UUID { config.id }
    var name: String { config.name }
    var host: String { config.host }
    let isDemo: Bool

    // What the unit reports
    @Published private(set) var online = false
    @Published private(set) var error: String? = nil        // why we can't reach it
    @Published private(set) var notice: String? = nil       // a warning while it still works
    @Published private(set) var power = false
    @Published private(set) var mode = 1
    @Published private(set) var temp = 22.0
    @Published private(set) var fan = 0
    @Published private(set) var vane = 0
    @Published private(set) var lr = 0
    @Published private(set) var entrust = false
    @Published private(set) var roomTemp: Double? = nil
    @Published private(set) var outdoorTemp: Double? = nil
    @Published private(set) var energy: Double? = nil
    @Published private(set) var heatingNow = false
    @Published private(set) var caps = ModelCapabilities.forModel(0)
    @Published private(set) var modelCode: Int? = nil
    @Published private(set) var hasReading = false

    // What we are in the middle of
    @Published private(set) var optimistic = Change()       // asked for, not sent / answered yet
    @Published private(set) var sending = 0
    @Published var commandError: String? = nil
    @Published private(set) var lastCommand: String? = nil
    @Published private(set) var lastCommandOK: Bool? = nil

    private var pending = Change()
    private var pendingUntil = Date.distantPast
    private var expected = Change()
    private var expectedAt = Date.distantPast
    @Published private(set) var mismatchNote: String? = nil

    private var client: WfRacClient? = nil
    private var airconId: String? = nil
    private var registered = false
    private var lastState: AirconState? = nil
    private var adapterInfo: [String: Any] = [:]
    private var lockExpires: Int? = nil
    private let lock = AsyncGate()
    private var sendTask: Task<Void, Never>? = nil
    private var recheckTask: Task<Void, Never>? = nil

    static let pendingSeconds: TimeInterval = 20

    init(config: UnitConfig, operatorId: String, deviceId: String, demoIndex: Int? = nil) {
        self.config = config
        if let d = demoIndex {
            isDemo = true
            online = true
            hasReading = true
            power = d == 0
            mode = d == 0 ? 1 : 2
            temp = d == 0 ? 21 : 23
            roomTemp = d == 0 ? 25.3 : 19.2
            outdoorTemp = 29.0
            fan = d == 0 ? 0 : 2
            vane = d == 0 ? 2 : 4
            lr = 3
        } else {
            isDemo = false
            client = WfRacClient(host: config.host, operatorId: operatorId, deviceId: deviceId,
                                 timeZone: TimeZone.current.identifier, awayAddress: config.awayAddress)
        }
    }

    // MARK: what the screens show

    var shownPower: Bool { shown { $0.power } ?? power }
    var shownMode: Int { shown { $0.mode } ?? mode }
    var shownTemp: Double { shown { $0.temp } ?? temp }
    var shownFan: Int { shown { $0.fan } ?? fan }
    var shownVane: Int { shown { $0.vane } ?? vane }
    var shownLR: Int { shown { $0.lr } ?? lr }
    var shownEntrust: Bool { shown { $0.entrust } ?? entrust }

    private func shown<T>(_ pick: (Change) -> T?) -> T? {
        if let v = pick(optimistic) { return v }
        if Date() < pendingUntil, let v = pick(pending) { return v }
        return nil
    }

    var tempRange: (Double, Double) { caps.setpointRange(mode: shownMode) }
    var isSending: Bool { sending > 0 || !optimistic.isEmpty }

    /// "cool" / "heat" / "fan" / "dry" / nil when off. In Auto the unit itself decides what it is doing.
    var airKind: String? {
        if !shownPower { return nil }
        if shownMode == 0 { return heatingNow ? "heat" : "cool" }
        return modeKeys[shownMode]
    }

    var statusText: String {
        if !online { return "Offline" }
        if isSending { return "Sending…" }
        if !shownPower { return "Off" }
        switch shownMode {
        case 0: return heatingNow ? "Auto, heating" : "Auto, cooling"
        case 1: return "Cooling"
        case 2: return "Heating"
        case 3: return "Fan only"
        default: return "Drying"
        }
    }

    var warning: String? { commandError ?? notice ?? mismatchNote }
    var modelName: String? { nil }

    // MARK: reading

    func refresh() async {
        if isDemo { demoDrift(); return }
        guard let client = client else { return }
        await lock.acquire()
        defer { Task { await lock.release() } }
        do {
            try await identify(client)
        } catch {
            fail(error)
            return
        }
        do { try await register(client) } catch { notice = friendlyError(error) }
        do {
            let st = try await client.status(airconId: airconId ?? "")
            lockExpires = st.expires
            absorb(st.state)
        } catch {
            fail(error)
        }
    }

    private func identify(_ client: WfRacClient) async throws {
        if airconId == nil {
            let info = try await client.getInfo()
            adapterInfo = info
            guard let id = info["airconId"] as? String else {
                throw WfRacError.malformed("The adapter didn't give an id, so it is probably not an aircon adapter.")
            }
            airconId = id
        }
    }

    private func register(_ client: WfRacClient) async throws {
        if !registered {
            try await client.register(airconId: airconId ?? "")
            registered = true
            notice = nil
        }
    }

    private func fail(_ error: Error) {
        online = false
        self.error = friendlyError(error)
    }

    private func absorb(_ a: AirconState) {
        let first = lastState == nil
        lastState = a
        power = a.operation
        mode = (0...4).contains(a.operationMode) ? a.operationMode : 0
        temp = a.presetTemp
        fan = (0...4).contains(a.airFlow) ? a.airFlow : 0
        vane = (0...4).contains(a.windUD) ? a.windUD : 0
        caps = ModelCapabilities.forModel(a.modelNrRaw)
        modelCode = a.modelNrRaw
        // On some units the adapter pins the left/right louver and 3D auto bits, so only the first reading counts.
        if first {
            lr = (0...7).contains(a.windLR) ? a.windLR : 0
            entrust = a.entrust
        }
        roomTemp = a.indoorTemp
        outdoorTemp = a.outdoorTemp
        energy = a.electric
        heatingNow = a.coolHotJudge
        online = true
        error = nil
        hasReading = true
        settlePending()
        checkExpected()
    }

    private func reported() -> Change {
        return Change(power: power, mode: mode, temp: temp, fan: fan, vane: vane, lr: nil, entrust: nil)
    }

    private func settlePending() {
        if Date() >= pendingUntil { pending = Change(); return }
        let r = reported()
        if pending.power == r.power { pending.power = nil }
        if pending.mode == r.mode { pending.mode = nil }
        if pending.temp == r.temp { pending.temp = nil }
        if pending.fan == r.fan { pending.fan = nil }
        if pending.vane == r.vane { pending.vane = nil }
    }

    private func checkExpected() {
        if expected.isEmpty { mismatchNote = nil; return }
        let r = reported()
        var bad: [String] = []
        if let w = expected.power, w != r.power { bad.append("power (asked for \(w ? "on" : "off"), the unit reports \(r.power == true ? "on" : "off"))") }
        if let w = expected.mode, w != r.mode { bad.append("mode (asked for \(modeNames[safe: w] ?? "?"), the unit reports \(modeNames[safe: r.mode ?? 0] ?? "?"))") }
        if let w = expected.temp, let g = r.temp, abs(w - g) > 0.01 { bad.append("temperature (asked for \(w)°C, the unit reports \(g)°C)") }
        if let w = expected.fan, w != r.fan { bad.append("fan speed (asked for \(fanNames[safe: w] ?? "?"), the unit reports \(fanNames[safe: r.fan ?? 0] ?? "?"))") }
        if let w = expected.vane, w != r.vane { bad.append("up/down air direction (asked for \(vaneNames[safe: w] ?? "?"), the unit reports \(vaneNames[safe: r.vane ?? 0] ?? "?"))") }
        let age = Date().timeIntervalSince(expectedAt)
        if bad.isEmpty || age > 90 {
            expected = Change()
            mismatchNote = nil
        } else if age < 6 {
            mismatchNote = nil          // give the unit a moment to apply it
        } else {
            mismatchNote = "The unit hasn't applied everything: " + bad.joined(separator: "; ")
                + ". It may ignore this in its current mode (for example while 3D auto is on), or another remote or app changed it."
        }
    }

    // MARK: changing

    /// Called by the screens. Shows the change at once, then sends it (temperature taps are batched).
    func ask(_ change: Change, debounce: Bool = false) {
        optimistic.merge(change)
        commandError = nil
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { return }
            }
            await self?.flush()
        }
    }

    private func flush() async {
        let body = optimistic
        if body.isEmpty { return }
        sending += 1
        defer { sending -= 1 }
        do {
            try await perform(body)
            if optimistic == body { optimistic = Change() }
        } catch {
            optimistic = Change()
            commandError = "Couldn't change that: " + friendlyError(error)
            await refresh()
        }
    }

    private func perform(_ changes: Change) async throws {
        if isDemo {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let v = changes.power { power = v }
            if let v = changes.mode { mode = v }
            if let v = changes.temp { temp = v }
            if let v = changes.fan { fan = v }
            if let v = changes.vane { vane = v }
            if let v = changes.lr { lr = v }
            if let v = changes.entrust { entrust = v }
            let r = caps.setpointRange(mode: mode)
            temp = min(r.1, max(r.0, temp))
            lastCommand = changes.summary
            lastCommandOK = true
            return
        }
        guard let client = client else { return }
        await lock.acquire()
        defer { Task { await lock.release() } }
        do {
            try await identify(client)
            try await register(client)
            if lastState == nil {
                let st = try await client.status(airconId: airconId ?? "")
                absorb(st.state)
            }
            guard let base = lastState else { throw WfRacError.connection("no reading from the unit yet") }
            if changes.lr != nil && !caps.windDirectionLR { throw WfRacError.command("this unit has no left/right louvers") }
            if changes.entrust != nil && !caps.entrust { throw WfRacError.command("this unit has no 3D auto") }
            var ch = changes
            // Choosing a louver position switches 3D auto off, as in the official app.
            if caps.entrust && entrust && (ch.vane != nil || ch.lr != nil) && ch.entrust == nil { ch.entrust = false }

            let modeNow = ch.mode ?? shownMode
            let range = caps.setpointRange(mode: modeNow)
            let sentTemp: Double? = ch.temp.map { min(range.1, max(range.0, $0)) }
            let hasLR = caps.windDirectionLR
            let hasEntrust = caps.entrust
            let believedLR = lr
            let believedEntrust = entrust
            let edit: (inout AirconState) -> Void = { s in
                if let p = ch.power { s.operation = p }
                if let m = ch.mode { s.operationMode = m }
                if let t = sentTemp { s.presetTemp = t }
                if let f = ch.fan { s.airFlow = f }
                if let v = ch.vane { s.windUD = v }
                // Louver position and 3D auto can't be read back on all units, so every frame carries what we believe is set.
                if hasLR { s.windLR = ch.lr ?? believedLR }
                if hasEntrust { s.entrust = ch.entrust ?? believedEntrust }
            }
            let newState = try await client.send(airconId: airconId ?? "", base: base, edit: edit)

            var exp = ch
            exp.lr = nil
            exp.entrust = nil
            if let t = sentTemp { exp.temp = t }
            expected = exp
            expectedAt = Date()
            absorb(newState)
            // Remember what we asked for: the adapter can take a few seconds to report it.
            pending.merge(ch)
            pendingUntil = Date().addingTimeInterval(AirconUnit.pendingSeconds)
            if let v = ch.lr { lr = v }
            if let v = ch.entrust { entrust = v }
            lastCommand = changes.summary
            lastCommandOK = true
            scheduleRecheck()
        } catch {
            lastCommand = changes.summary
            lastCommandOK = false
            throw error
        }
    }

    private func scheduleRecheck() {
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if Task.isCancelled { return }
            await self?.refresh()
        }
    }

    // MARK: demo

    private func demoDrift() {
        if power && (mode == 0 || mode == 1 || mode == 2), let r = roomTemp {
            roomTemp = ((r + max(-0.1, min(0.1, (temp - r) * 0.05))) * 10).rounded() / 10
        }
    }

    // MARK: diagnostics

    func diagnosticsText() async -> String {
        func j(_ v: Any?) -> Any { return v ?? NSNull() }
        var d: [String: Any] = [
            "name": name, "host": host, "demo": isDemo, "online": online,
            "error": j(error), "notice": j(notice),
            "adapterId": j(airconId), "registeredWithAdapter": registered,
            "modelCode": j(modelCode),
            "supported": ["leftRightLouver": caps.windDirectionLR, "threeDAuto": caps.entrust, "energyReading": caps.powerConsumption],
            "reading": ["power": power, "mode": modeKeys[safe: mode] ?? "?", "temp": temp, "fan": fan, "vane": vane,
                        "lr": lr, "entrust": entrust, "room": j(roomTemp), "outdoor": j(outdoorTemp)] as [String: Any],
            "lastCommand": j(lastCommand),
            "lastCommandOK": j(lastCommandOK),
            "writeLockExpiresAt": j(lockExpires),
            "mismatch": j(mismatchNote)
        ]
        if let c = client { d["adapterAnswerCounts"] = c.resultCodes }
        d["adapterInfo"] = redact(adapterInfo)
        if isDemo { d["note"] = "This is a pretend unit; there is no real adapter." }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "No details available." }
        return text
    }

    private func redact(_ value: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in value {
            if ["operatorId", "accountId", "deviceId"].contains(k) { out[k] = "**redacted**" }
            else if let nested = v as? [String: Any] { out[k] = redact(nested) }
            else { out[k] = v }
        }
        return out
    }
}
