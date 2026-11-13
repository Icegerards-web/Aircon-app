import Foundation
import Wgbridge      // WireGuard that runs inside the app (built from /wgbridge by CI)

/// "Away from home" support. When the phone is not on the same network as an aircon adapter, requests are sent
/// through a WireGuard tunnel to your home WireGuard server instead. The tunnel lives inside this app only:
/// no system VPN (no icon in the status bar), no effect on the rest of the phone's internet, and it is only up
/// while the app is open.
final class TunnelManager {
    static let shared = TunnelManager()

    private let gate = AsyncGate()
    private var running = false
    private let fileURL: URL

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("wireguard.conf")
    }

    // MARK: the saved config

    var config: String? {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    var isConfigured: Bool { return config != nil }

    /// Returns nil when saved, or a readable problem.
    func save(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = WgbridgeValidate(clean)
        if !problem.isEmpty { return problem }
        do {
            try clean.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: fileURL.path)
        } catch {
            return "Couldn't save the config: \(error.localizedDescription)"
        }
        stop()
        return nil
    }

    func remove() {
        stop()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: when to use it

    /// Use the tunnel only when a config exists and the phone is *not* on the aircon's own network.
    func shouldUse(host: String) -> Bool {
        return isConfigured && !TunnelManager.onSameNetwork(host: host)
    }

    /// Is the phone on the same /24 network as this address? (Host names are assumed to be local.)
    static func onSameNetwork(host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        return Discovery.localPrefixes().contains(prefix)
    }

    // MARK: running it

    private func ensureStarted() async throws {
        await gate.acquire()
        defer { Task { await gate.release() } }
        if running && WgbridgeIsRunning() { return }
        guard let conf = config else { throw WfRacError.connection("No home connection is set up (Settings, Away from home).") }
        do {
            try await Task.detached { () throws -> Void in
                var err: NSError?
                let ok = WgbridgeStart(conf, &err)
                if let e = err { throw e }
                if !ok { throw WfRacError.connection("the tunnel did not start") }
            }.value
            running = true
        } catch {
            throw WfRacError.connection("Couldn't start the home connection: \(error.localizedDescription)")
        }
    }

    func post(url: String, body: Data, timeout: TimeInterval) async throws -> (status: Int, data: Data) {
        try await ensureStarted()
        do {
            return try await Task.detached { () -> (Int, Data) in
                var err: NSError?
                let reply: WgbridgeReply? = WgbridgePost(url, body, Int(timeout), &err)
                if let e = err { throw e }
                guard let r = reply else { throw WfRacError.connection("no answer through the home connection") }
                return (r.status(), r.body() ?? Data())
            }.value
        } catch {
            throw WfRacError.connection("No answer through your home connection (\(error.localizedDescription)). Check that your home WireGuard server is on and reachable.")
        }
    }

    func stop() {
        running = false
        WgbridgeStop()
    }
}
