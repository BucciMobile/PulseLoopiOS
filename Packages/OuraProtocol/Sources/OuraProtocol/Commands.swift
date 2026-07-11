import Foundation

// Commands: byte-exact opcode builders (OURA_PROTOCOL.md s4 / s5). Pure functions returning the
// wire bytes to write to ...0002. The live-HR enable path (s5.6) is the feature-0x02 (0x2F) path,
// NOT the 0x06 path. Dangerous opcodes (reboot, factory reset, key install, DFU) are quarantined in
// OuraDangerousCommands and never produced by the normal builders.
//
// Platform-pure value types. Facts cited per OURA_PROTOCOL.md s4 / s5.

/// A built command plus a short label for the strap log (statuses/UUIDs/counts only, never an
/// address). The OuraDriver returns these from nextStep(after:).
public struct OuraCommand: Equatable, Sendable {
    public let label: String
    public let bytes: [UInt8]
    public init(label: String, bytes: [UInt8]) { self.label = label; self.bytes = bytes }
}

public enum OuraCommands {
    // The live daytime-HR feature id. Per OURA_PROTOCOL.md s5.6 / s7.1.
    public static let featureDaytimeHR: UInt8 = 0x02
    // The SpO2 feature id. Per OURA_PROTOCOL.md s7.1.
    public static let featureSpO2: UInt8 = 0x04

    // MARK: - Pre-auth / identity (unauthenticated OK)

    /// GetFirmwareVersion: `08 03 00 00 00`. Pre-auth readable. Per OURA_PROTOCOL.md s4.1 / s3.6.
    public static func getFirmwareVersion() -> OuraCommand {
        OuraCommand(label: "get_firmware", bytes: [0x08, 0x03, 0x00, 0x00, 0x00])
    }

    /// GetProductInfo serial page: `18 03 08 00 10`. Pre-auth readable; used for generation detection.
    /// Per OURA_PROTOCOL.md s4.1 / s7.3.
    public static func getProductSerial() -> OuraCommand {
        OuraCommand(label: "get_serial", bytes: [0x18, 0x03, 0x08, 0x00, 0x10])
    }

    /// GetProductInfo hardware page: `18 03 18 00 10`. Pre-auth readable; hardware id (e.g. BLB_03)
    /// maps to the generation. Per OURA_PROTOCOL.md s4.1 / s7.3.
    public static func getProductHardware() -> OuraCommand {
        OuraCommand(label: "get_hardware", bytes: [0x18, 0x03, 0x18, 0x00, 0x10])
    }

    // MARK: - Notifications / state

    /// SetNotification (enable all): `1c 01 3f`. `00`=none, `3f`/`bf`=all. Per OURA_PROTOCOL.md s4.1.
    public static func enableAllNotifications() -> OuraCommand {
        OuraCommand(label: "notify_all", bytes: [0x1C, 0x01, 0x3F])
    }

    /// SetNotification (disable): `1c 01 00`. Per OURA_PROTOCOL.md s4.1.
    public static func disableNotifications() -> OuraCommand {
        OuraCommand(label: "notify_off", bytes: [0x1C, 0x01, 0x00])
    }

    // MARK: - Live HR enable (s5.6)

    /// SetFeatureMode (enable daytime HR, feature 0x02): `2f 02 02 00 01`. Per OURA_PROTOCOL.md s5.6.
    public static func enableLiveHR() -> [OuraCommand] {
        [
            OuraCommand(label: "enable_notify", bytes: [0x1C, 0x01, 0x3F]),
            OuraCommand(label: "enable_hr_feature", bytes: [0x2F, 0x02, 0x02, 0x00, 0x01]),
            OuraCommand(label: "subscribe_events", bytes: [0x2F, 0x03, 0x02, 0x00, 0x00]),
        ]
    }

    // MARK: - History fetch (s5)

    /// GetEvents (GetEvents summary): `2f 05 20 <cursor:4LE>`. Per OURA_PROTOCOL.md s5.1.
    public static func getEvents(cursor: UInt32) -> OuraCommand {
        let cursorBytes: [UInt8] = [
            UInt8(cursor & 0xFF),
            UInt8((cursor >> 8) & 0xFF),
            UInt8((cursor >> 16) & 0xFF),
            UInt8((cursor >> 24) & 0xFF),
        ]
        return OuraCommand(label: "get_events", bytes: [0x2F, 0x05, 0x20] + cursorBytes)
    }

    // MARK: - Battery

    /// GetBattery: `0c 03 00 00 10`. Per OURA_PROTOCOL.md s4.1 / s6.10.
    public static func getBattery() -> OuraCommand {
        OuraCommand(label: "get_battery", bytes: [0x0C, 0x03, 0x00, 0x00, 0x10])
    }
}
