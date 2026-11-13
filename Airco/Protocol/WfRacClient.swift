import Foundation

// MARK: - Errors

enum WfRacError: Error {
    case connection(String)          // nothing answered
    case malformed(String)           // answered with something that isn't a proper response
    case command(String)             // answered, but refused
    case registration                // result 2 on a write: we aren't one of the adapter's remote controls
    case accountTableFull            // result 2 on registering: all 4 remote slots are taken
    case writeRefused                // result 1/11/12: the 60-second write lock is held by someone else
}

/// Turns any error into a sentence a person can act on (same wording as the web tool).
func friendlyError(_ error: Error) -> String {
    if let e = error as? WfRacError {
        switch e {
        case .accountTableFull:
            return "The adapter only remembers 4 remote controls (phones, apps, tools) and all 4 slots are taken, so it won't accept this app for changes. Reading works. Free a slot by removing this aircon from the Smart M-Air app on a phone you no longer use, then try again."
        case .writeRefused:
            return "The unit is busy: another app changed it less than a minute ago and the unit only accepts one controller at a time. Try again in a moment."
        case .registration:
            return "The adapter didn't accept this app as a remote control (result 2). Try again; if it keeps failing, see Details."
        case .connection(let s):
            return s
        case .malformed(let s), .command(let s):
            return s
        }
    }
    if let u = error as? URLError {
        switch u.code {
        case .timedOut:
            return "no answer (timed out). Check the IP address and that the adapter is powered and on your Wi-Fi."
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dnsLookupFailed:
            return "nothing answered at that address. Check the IP address and that your phone is on the same Wi-Fi (or connected to your home VPN)."
        default:
            return u.localizedDescription
        }
    }
    if let p = error as? ParserError { return p.errorDescription ?? "Unreadable answer" }
    return error.localizedDescription
}

// MARK: - Small helper: only one request at a time per adapter

actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

// MARK: - Accepting the adapter's self-signed certificate

/// The adapters speak HTTPS with a self-made certificate, so there is nothing to verify it against.
/// We only ever talk to addresses the user typed or the scan found on their own network.
final class AdapterTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Talking to one adapter

struct AdapterStatus {
    var state: AirconState
    var expires: Int?
}

/// Port of pywfrac's `Repository`: sends the JSON commands to `http(s)://<ip>:51443/beaver/command/<name>`.
/// The adapter is slow (10-20 seconds is normal) and fragile, so requests go one at a time with a pause between.
final class WfRacClient {
    let host: String
    let port: Int
    let operatorId: String
    let deviceId: String
    let timeZone: String

    private let session: URLSession
    private let gate = AsyncGate()
    private var nextRequestAfter = Date()
    private var method: String? = nil           // "http" or "https", remembered once one worked
    private(set) var resultCodes: [String: [String: Int]] = [:]

    static let requestTimeout: TimeInterval = 25
    static let minTimeBetweenRequests: TimeInterval = 1
    static let writeLockMaxWait: TimeInterval = 61
    static let writeLockRetryDelay: TimeInterval = 10

    init(host: String, port: Int = 51443, operatorId: String, deviceId: String, timeZone: String) {
        self.host = host
        self.port = port
        self.operatorId = operatorId
        self.deviceId = deviceId
        self.timeZone = timeZone
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = WfRacClient.requestTimeout
        cfg.timeoutIntervalForResource = WfRacClient.requestTimeout
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv10   // old adapters only know old TLS
        cfg.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: cfg, delegate: AdapterTrustDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: raw request

    private func post(_ command: String, contents: [String: Any]? = nil) async throws -> [String: Any] {
        await gate.acquire()
        let result: [String: Any]
        do {
            result = try await postLocked(command, contents: contents)
        } catch {
            nextRequestAfter = Date().addingTimeInterval(WfRacClient.minTimeBetweenRequests)
            await gate.release()
            throw error
        }
        nextRequestAfter = Date().addingTimeInterval(WfRacClient.minTimeBetweenRequests)
        await gate.release()
        record(command, result)
        return result
    }

    /// Runs while holding the gate. Tries the remembered protocol first, then the other one.
    private func postLocked(_ command: String, contents: [String: Any]?) async throws -> [String: Any] {
        let wait = nextRequestAfter.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        var body: [String: Any] = [
            "apiVer": "1.0",
            "command": command,
            "deviceId": deviceId,
            "operatorId": operatorId,
            "timestamp": Int(Date().timeIntervalSince1970.rounded())
        ]
        if let contents = contents { body["contents"] = contents }
        let data = try JSONSerialization.data(withJSONObject: body)

        var order = ["http", "https"]
        if let m = method { order = [m] + order.filter { $0 != m } }
        var firstError: Error? = nil
        for (index, proto) in order.enumerated() {
            do {
                let response = try await execute(proto: proto, command: command, body: data)
                method = proto
                return response
            } catch let e as WfRacError {
                // An answered refusal or garbled body from the protocol that worked before is the unit's problem.
                if index == 0, method != nil {
                    if case .command = e { throw e }
                    if case .malformed = e { throw e }
                }
                firstError = firstError ?? e
            } catch {
                firstError = firstError ?? error
            }
            if index == order.count - 1 {
                method = nil
                throw firstError ?? WfRacError.connection("no answer")
            }
            try await Task.sleep(nanoseconds: UInt64(WfRacClient.minTimeBetweenRequests * 1_000_000_000))
        }
        throw firstError ?? WfRacError.connection("no answer")
    }

    private func execute(proto: String, command: String, body: Data) async throws -> [String: Any] {
        guard let url = URL(string: "\(proto)://\(host):\(port)/beaver/command/\(command)") else {
            throw WfRacError.connection("'\(host)' is not a valid address")
        }
        var req = URLRequest(url: url, timeoutInterval: WfRacClient.requestTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError {
            throw WfRacError.connection(friendlyError(e))
        }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw WfRacError.command("The unit returned HTTP \(http.statusCode) for \(command).")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else {
            throw WfRacError.malformed("The unit answered \(command) with something that is not a proper response.")
        }
        return dict
    }

    private func resultCode(_ r: [String: Any]) -> Int? {
        if let i = r["result"] as? Int { return i }
        if let s = r["result"] as? String { return Int(s) }
        if let d = r["result"] as? Double { return Int(d) }
        return nil
    }

    private func record(_ command: String, _ r: [String: Any]) {
        guard let code = resultCode(r), code != 0 else { return }
        var counts = resultCodes[command] ?? [:]
        counts[String(code), default: 0] += 1
        resultCodes[command] = counts
    }

    // MARK: the commands

    /// "Who are you?" Returns the adapter's info (it holds `airconId`).
    func getInfo() async throws -> [String: Any] {
        let r = try await post("getDeviceInfo")
        guard let c = r["contents"] as? [String: Any] else { throw WfRacError.malformed("The adapter didn't say who it is.") }
        return c
    }

    func airconId() async throws -> String {
        let info = try await getInfo()
        guard let id = info["airconId"] as? String else { throw WfRacError.malformed("The adapter didn't give an id, so it is probably not an aircon adapter.") }
        return id
    }

    /// Become one of the adapter's (max 4) remote controls.
    func register(airconId: String) async throws {
        let r = try await post("updateAccountInfo", contents: [
            "accountId": operatorId, "airconId": airconId, "remote": 0, "timezone": timeZone
        ])
        guard let code = resultCode(r) else { throw WfRacError.malformed("The adapter answered the registration without a result.") }
        if code == 2 { throw WfRacError.accountTableFull }
        if code != 0 { throw WfRacError.command("The adapter refused the registration (result \(code)).") }
    }

    func status(airconId: String) async throws -> AdapterStatus {
        let r = try await post("getAirconStat", contents: ["airconId": airconId])
        guard let c = r["contents"] as? [String: Any], let stat = c["airconStat"] as? String else {
            if let code = resultCode(r), code != 0 {
                let why = code == 1 ? "the unit had no fresh data" : "result \(code)"
                throw WfRacError.command("The adapter couldn't give the state (\(why)).")
            }
            throw WfRacError.malformed("The adapter answered without a usable state.")
        }
        let state = try RacParser.decode(stat)
        return AdapterStatus(state: state, expires: c["expires"] as? Int)
    }

    /// Apply `edit` on top of `base` and return the state the unit reports back.
    /// Handles the two normal refusals: the 60-second write lock (wait, re-read, retry once)
    /// and "not registered" (register, retry once).
    func send(airconId: String, base: AirconState, edit: (inout AirconState) -> Void) async throws -> AirconState {
        var wanted = base
        edit(&wanted)
        let frame = try RacParser.encode(wanted)
        do {
            return try await setState(airconId: airconId, frame: frame)
        } catch WfRacError.writeRefused {
            var fresh = base
            var delay = WfRacClient.writeLockRetryDelay
            if let st = try? await status(airconId: airconId) {
                fresh = st.state
                if let exp = st.expires {
                    let remaining = Double(exp) - Date().timeIntervalSince1970 + 1
                    delay = max(0, min(remaining, WfRacClient.writeLockMaxWait))
                }
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // Re-encode from the fresh state, otherwise we'd undo what the other app just changed.
            var again = fresh
            edit(&again)
            return try await setState(airconId: airconId, frame: try RacParser.encode(again))
        } catch WfRacError.registration {
            try await register(airconId: airconId)
            return try await setState(airconId: airconId, frame: frame)
        }
    }

    private func setState(airconId: String, frame: String) async throws -> AirconState {
        let r = try await post("setAirconStat", contents: ["airconId": airconId, "airconStat": frame])
        let code = resultCode(r)
        if let code = code, code == 1 || code == 11 || code == 12 { throw WfRacError.writeRefused }
        if code == 2 { throw WfRacError.registration }
        if let code = code, code != 0 {
            let text: String
            switch code {
            case 10: text = "internal error in the air conditioner"
            case 20: text = "firmware update required"
            case 99: text = "the unit did not confirm the command within 30 seconds"
            case 429: text = "too many requests, wait a moment"
            default: text = "result \(code)"
            }
            throw WfRacError.command("The unit refused the command (\(text)).")
        }
        guard let c = r["contents"] as? [String: Any], let stat = c["airconStat"] as? String else {
            throw WfRacError.malformed("The unit answered the command without a usable state.")
        }
        return try RacParser.decode(stat)
    }
}
