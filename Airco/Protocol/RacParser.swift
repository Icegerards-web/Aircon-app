import Foundation

// MARK: - What the adapter tells us

/// One decoded "state block" from the adapter. This is a straight port of the `Aircon` object
/// in the Python reference tool (pywfrac), so the numbers mean exactly the same thing.
struct AirconState {
    var operation = false
    var operationMode = 0        // 0 auto, 1 cool, 2 heat, 3 fan, 4 dry
    var airFlow = 0              // 0 auto, 1 quiet ... 4 high (5 = something we can't read)
    var windUD = 0               // up/down louver: 0 swing, 1 wide ... 4 straight down
    var windLR = 0               // left/right louver: 0 swing, 1...7 fixed positions
    var presetTemp = 18.0
    var entrust = false          // "3D auto"
    var modelNr = 0              // grouping used by the wire format (0, 1, 2 or -1)
    var modelNrRaw = 0           // the model group byte the adapter reports
    var vacant = false
    var coolHotJudge = false     // true = the unit is heating right now (auto mode)
    var isSelfCleanOperation = false
    var indoorTemp: Double? = nil
    var outdoorTemp: Double? = nil
    var electric: Double? = nil
    var errorCode = "00"
}

/// What a model group can do (the same table the official app uses).
struct ModelCapabilities {
    var powerConsumption: Bool
    var windDirectionLR: Bool
    var entrust: Bool            // 3D auto
    var presetTempRange2: Bool

    func setpointRange(mode: Int) -> (Double, Double) {
        var low: Double = (mode == 1) ? 16 : 18
        var high: Double = 30
        if presetTempRange2 {
            if mode == 2 { low = 10 }
            else if mode == 1 || mode == 4 || mode == 0 { low = 16 }
            if mode == 1 || mode == 4 { high = 33 }
        }
        return (low, high)
    }

    static func forModel(_ raw: Int) -> ModelCapabilities {
        switch raw {
        case 1: return ModelCapabilities(powerConsumption: true, windDirectionLR: true, entrust: true, presetTempRange2: false)
        case 2: return ModelCapabilities(powerConsumption: true, windDirectionLR: true, entrust: true, presetTempRange2: false)
        case 3: return ModelCapabilities(powerConsumption: false, windDirectionLR: true, entrust: true, presetTempRange2: true)
        case 64: return ModelCapabilities(powerConsumption: false, windDirectionLR: false, entrust: false, presetTempRange2: false)
        default: return ModelCapabilities(powerConsumption: true, windDirectionLR: true, entrust: true, presetTempRange2: false)
        }
    }
}

enum ParserError: Error, LocalizedError {
    case badFrame(String)
    case noEncoding(String)
    var errorDescription: String? {
        switch self {
        case .badFrame(let s): return "The adapter sent a state block we couldn't read (\(s))."
        case .noEncoding(let s): return s
        }
    }
}

// MARK: - The binary format
//
// Every command and every answer is a short block of bytes, sent as base64 inside the JSON.
// A block holds: [18 bytes "what to set"] [trailer] [2-byte checksum] followed by
// [18 bytes "what the unit should now look like"] [trailer] [2-byte checksum].
// The unit only applies a value when its matching "set-bit" is present, which is why encoding a
// command always writes the *full* state, with the one changed value swapped in.

enum RacParser {
    static let variableSuffix: [UInt8] = [1, 255, 255, 255, 255]
    static let crcPolynomial = 4129
    static let crcInitial = 65535

    static let cmdModeMasks: [Int: Int] = [0: 32, 1: 40, 2: 48, 3: 44, 4: 36]
    static let cmdAirflowMasks: [Int: Int] = [0: 15, 1: 8, 2: 9, 3: 10, 4: 14]
    static let cmdWindUDMasks: [Int: (Int, Int)] = [0: (192, 128), 1: (128, 128), 2: (128, 144), 3: (128, 160), 4: (128, 176)]
    static let cmdWindLRMasks: [Int: (Int, Int)] = [0: (3, 16), 1: (2, 16), 2: (2, 17), 3: (2, 18), 4: (2, 19), 5: (2, 20), 6: (2, 21), 7: (2, 22)]
    static let rcvModeMasks: [Int: Int] = [0: 0, 1: 8, 2: 16, 3: 12, 4: 4]
    static let rcvAirflowMasks: [Int: Int] = [0: 7, 1: 0, 2: 1, 3: 2, 4: 6]
    static let airflowUnknown = 5

    private static func findMatch(_ value: Int, _ options: [Int]) -> Int {
        return options.firstIndex(of: value) ?? -1
    }

    private static func emptyBlock() -> [Int] {
        return [0, 0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    // MARK: checksum

    static func crc16(_ data: [Int]) -> Int {
        var crc = crcInitial
        for raw in data {
            let byte = raw & 0xFF
            for bit in 0..<8 {
                var shouldXor = ((byte >> (7 - bit)) & 1) == 1
                if ((crc >> 15) & 1) == 1 { shouldXor = !shouldXor }
                crc = (crc << 1) & 0xFFFF
                if shouldXor { crc ^= crcPolynomial }
            }
        }
        return crc
    }

    private static func addCrc(_ bytes: [Int]) -> [Int] {
        let crc = crc16(bytes)
        return bytes + [crc & 255, (crc >> 8) & 255]
    }

    // MARK: decoding (adapter -> us)

    static func decode(_ base64: String) throws -> AirconState {
        guard let data = Data(base64Encoded: base64) else { throw ParserError.badFrame("not base64") }
        // The format treats bytes as signed numbers; keep that, so the masks below behave identically.
        let signed: [Int] = data.map { Int(Int8(bitPattern: $0)) }
        guard signed.count > 19 else { throw ParserError.badFrame("too short") }
        let start = signed[18] * 4 + 21
        guard start >= 0, signed.count >= start + 19 else { throw ParserError.badFrame("wrong length") }
        let c = Array(signed[start..<(start + 18)])

        var s = AirconState()
        s.operation = (3 & c[2]) == 1
        s.presetTemp = Double(c[4]) / 2
        s.operationMode = findMatch(60 & c[2], [8, 16, 12, 4]) + 1
        let flow = findMatch(15 & c[3], [7, 0, 1, 2, 6])
        s.airFlow = flow < 0 ? airflowUnknown : flow
        s.windUD = (c[2] & 192) == 64 ? 0 : findMatch(240 & c[3], [0, 16, 32, 48]) + 1
        // On many units the adapter pins the left/right louver and 3D auto bits, so reading them back is unreliable.
        s.windLR = (c[12] & 3) == 1 ? 0 : findMatch(31 & c[11], [0, 1, 2, 3, 4, 5, 6]) + 1
        s.entrust = 4 == (12 & c[12])
        s.coolHotJudge = (c[8] & 8) <= 0
        s.modelNrRaw = c[0] & 127
        if s.modelNrRaw == 3 { s.modelNr = 2 } else { s.modelNr = findMatch(s.modelNrRaw, [0, 1, 2]) }
        s.vacant = (c[10] & 1) != 0
        if s.modelNr == 1 || s.modelNr == 2 { s.isSelfCleanOperation = (c[15] & 1) != 0 }
        let code = c[6] & 127
        s.errorCode = c[6] < 0 ? String(format: "M%02d", code) : (code == 0 ? "00" : "E\(code)")

        // Variable part: 4-byte segments (tag, sub, value, value) holding temperatures and energy.
        let tail = signed.count - 2
        let from = start + 19
        if from < tail {
            let vals = Array(signed[from..<tail])
            var i = 0
            while i + 3 < vals.count {
                if vals[i] == -128 {
                    let idx = vals[i + 2] & 0xFF
                    if vals[i + 1] == 16 { s.outdoorTemp = TempTables.outdoor[idx] }
                    else if vals[i + 1] == 32 { s.indoorTemp = TempTables.indoor[idx] }
                } else if vals[i] == -108 && vals[i + 1] == 16 {
                    let lo = (vals[i + 2] + 256) % 256
                    let hi = (vals[i + 3] + 256) % 256
                    s.electric = Double(lo + hi * 256) * 0.25
                }
                i += 4
            }
        }
        return s
    }

    // MARK: encoding (us -> adapter)

    private static func commandBlock(_ a: AirconState) throws -> [Int] {
        var b = emptyBlock()
        b[2] |= a.operation ? 3 : 2
        b[2] |= cmdModeMasks[a.operationMode] ?? 0
        guard let flow = cmdAirflowMasks[a.airFlow] else {
            throw ParserError.noEncoding("no encoding for fan speed \(a.airFlow)")
        }
        b[3] |= flow
        let ud = cmdWindUDMasks[a.windUD] ?? (0, 0)
        b[2] |= ud.0
        b[3] |= ud.1
        let lr = cmdWindLRMasks[a.windLR] ?? (0, 0)
        b[12] |= lr.0
        b[11] |= lr.1
        b[4] |= Int(a.presetTemp / 0.5) + 128
        b[12] |= a.entrust ? 12 : 8
        if !a.coolHotJudge { b[8] |= 8 }
        if a.modelNr == 1 { b[10] |= a.vacant ? 1 : 0 }
        if a.modelNr != 1 && a.modelNr != 2 { return b }
        b[12] |= a.isSelfCleanOperation ? 144 : 128
        return b
    }

    private static func receiveBlock(_ a: AirconState) throws -> [Int] {
        var b = emptyBlock()
        if a.operation { b[2] |= 1 }
        b[2] |= rcvModeMasks[a.operationMode] ?? 0
        guard let flow = rcvAirflowMasks[a.airFlow] else {
            throw ParserError.noEncoding("no encoding for fan speed \(a.airFlow)")
        }
        b[3] |= flow
        if a.windUD == 0 { b[2] |= 64 }
        else if a.windUD >= 2 && a.windUD <= 4 { b[3] |= (a.windUD - 1) * 16 }
        if a.windLR == 0 { b[12] |= 1 }
        else if a.windLR >= 1 && a.windLR <= 7 { b[11] |= a.windLR - 1 }
        b[4] |= Int(a.presetTemp / 0.5)
        if a.entrust { b[12] |= 4 }
        if !a.coolHotJudge { b[8] |= 8 }
        // The unit echoes its own model byte back; a mismatch there is rejected.
        b[0] |= (a.modelNrRaw >= 0 && a.modelNrRaw <= 127) ? a.modelNrRaw : 0
        if a.modelNr == 1 { b[10] |= a.vacant ? 1 : 0 }
        if a.modelNr != 1 && a.modelNr != 2 { return b }
        b[12] |= a.isSelfCleanOperation ? 144 : 128
        return b
    }

    static func encode(_ a: AirconState) throws -> String {
        let suffix = variableSuffix.map { Int($0) }
        let command = addCrc(try commandBlock(a) + suffix)
        let receive = addCrc(try receiveBlock(a) + suffix)
        let bytes = (command + receive).map { UInt8($0 & 0xFF) }
        return Data(bytes).base64EncodedString()
    }
}
