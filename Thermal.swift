import Foundation
import IOKit

// The thermal guard's two inputs.
//
// The decision rides ProcessInfo.thermalState, the public signal macOS itself
// throttles on: nominal, fair, serious, critical. It needs no privileges, it
// moves only when the pressure genuinely moves (a single hot second cannot
// flap the sleep flag), and it means the same thing on every Mac, which no
// raw degree figure does. The degree figure is for the panel: read from the
// SMC the way every temperature utility does, through the AppleSMC user
// client, no root needed.

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// CPU die temperatures from the SMC.
///
/// Sensor keys differ by chip: Apple Silicon publishes per-core sensors under
/// Tp (M1, M2) and Te/Tf (M3, M4); Intel Macs under TC. The set is discovered
/// once by walking the key table, after which every read is one IOKit call
/// per sensor. The figure reported is the hottest sensor: for "is it
/// overheating" an average hides exactly the number that matters.
final class SMCTemperature: @unchecked Sendable {
    // Wire layout of SMCKeyData_t, 80 bytes. Field order and sizes matter.
    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    private struct Limits {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0
    }
    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var attributes: UInt8 = 0
    }
    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var limits = Limits()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var selector: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private struct Sensor {
        let key: UInt32
        let info: KeyInfo
    }

    private enum Selector: UInt8 {
        case readKey = 5, keyFromIndex = 8, keyInfo = 9
    }

    private static let float32 = fourCC("flt ")
    private static let fixed78 = fourCC("sp78")
    private static let appleSiliconPrefixes = ["Tp", "Te", "Tf"]
    private static let intelPrefixes = ["TC"]

    private let connection: io_connect_t
    private let sensors: [Sensor]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard opened == kIOReturnSuccess else { return nil }

        let sensors = Self.discover(connection)
        guard !sensors.isEmpty else {
            IOServiceClose(connection)
            return nil
        }
        self.connection = connection
        self.sensors = sensors
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Hottest CPU sensor in °C, nil if nothing read sanely.
    func hottestCPU() -> Double? {
        sensors.compactMap { Self.read(connection, $0) }
            .filter { (1..<125).contains($0) }
            .max()
    }

    // MARK: - Discovery

    /// Walks the whole key table once. A couple of thousand calls, so callers
    /// run this off the main thread.
    private static func discover(_ connection: io_connect_t) -> [Sensor] {
        guard let countInfo = keyInfo(connection, fourCC("#KEY")),
              let raw = readBytes(connection, fourCC("#KEY"), countInfo)
        else { return [] }
        let count = UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3])

        var appleSilicon: [Sensor] = []
        var intel: [Sensor] = []
        for index in 0..<count {
            var param = Param()
            param.selector = Selector.keyFromIndex.rawValue
            param.index = index
            guard let out = call(connection, &param) else { continue }
            let name = string(out.key)
            let isAppleSilicon = appleSiliconPrefixes.contains { name.hasPrefix($0) }
            let isIntel = intelPrefixes.contains { name.hasPrefix($0) }
            guard isAppleSilicon || isIntel,
                  let info = keyInfo(connection, out.key),
                  info.dataType == float32 && info.dataSize == 4
                    || info.dataType == fixed78 && info.dataSize == 2
            else { continue }
            let sensor = Sensor(key: out.key, info: info)
            if isAppleSilicon { appleSilicon.append(sensor) } else { intel.append(sensor) }
        }
        // A chip family publishes one set or the other; mixing them would let
        // an unrelated TC* sensor on Apple Silicon masquerade as a core.
        return appleSilicon.isEmpty ? intel : appleSilicon
    }

    // MARK: - Calls

    private static func call(_ connection: io_connect_t, _ input: inout Param) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.size
        let status = IOConnectCallStructMethod(
            connection, 2, &input, MemoryLayout<Param>.size, &output, &size)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func keyInfo(_ connection: io_connect_t, _ key: UInt32) -> KeyInfo? {
        var param = Param()
        param.key = key
        param.selector = Selector.keyInfo.rawValue
        return call(connection, &param)?.keyInfo
    }

    private static func readBytes(_ connection: io_connect_t, _ key: UInt32, _ info: KeyInfo) -> [UInt8]? {
        var param = Param()
        param.key = key
        param.keyInfo = info
        param.selector = Selector.readKey.rawValue
        guard let out = call(connection, &param) else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
    }

    private static func read(_ connection: io_connect_t, _ sensor: Sensor) -> Double? {
        guard let bytes = readBytes(connection, sensor.key, sensor.info) else { return nil }
        switch sensor.info.dataType {
        case float32:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case fixed78:
            // Signed 8.7 fixed point, big-endian: the Intel SMC's temperature type.
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256
        default:
            return nil
        }
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
