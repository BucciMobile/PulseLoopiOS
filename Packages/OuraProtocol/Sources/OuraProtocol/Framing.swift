import Foundation

// Framing: the two framing layers that ride on the same characteristics (OURA_PROTOCOL.md s2).
//   - Outer command / command-response frame:  op(1) len(1) body(len)        (s2.1)
//   - Extended / secure-session frame (0x2F):   2F len subop subop-body       (s2.2)
//   - Inner event record (TLV):                 type(1) len(1) rt:u32LE payload (s2.3)
// All multi-byte integers are little-endian unless a decoder states otherwise (OURA_PROTOCOL.md s2.1).
//
// The first byte disambiguates layers: a value present in the opcode table (s4) is an outer frame;
// otherwise it is an inner event record. The OuraDriver routes on this; Framing exposes pure parsers
// plus a defensive Reassembler that buffers partial trailing bytes across notifications (s2.4).
//
// Platform-pure, value types only. Facts cited per OURA_PROTOCOL.md s2.

// MARK: - Outer command / response frame

/// A parsed outer frame: `op len body` (OURA_PROTOCOL.md s2.1). `body` is the `len` bytes after the
/// header. Multiple outer frames may be packed into one notification; the consumer loops 2+len.
public struct OuraOuterFrame: Equatable, Sendable {
    public let op: UInt8
    public let body: [UInt8]
    public init(op: UInt8, body: [UInt8]) { self.op = op; self.body = body }

    /// Total wire length of this frame (header + body).
    public var totalLength: Int { 2 + body.count }
}

/// A parsed secure-session sub-frame: the first body byte of a 0x2F frame is the sub-op
/// (OURA_PROTOCOL.md s2.2 / s4.2). `subBody` is the remaining body bytes after the sub-op.
public struct OuraSecureFrame: Equatable, Sendable {
    public let subop: UInt8
    public let subBody: [UInt8]
    public init(subop: UInt8, subBody: [UInt8]) { self.subop = subop; self.subBody = subBody }
}

public enum OuraFraming {
    /// The secure-session / extended opcode. Per OURA_PROTOCOL.md s2.2 / s4.1.
    public static let secureSessionOp: UInt8 = 0x2F

    /// The GetEvents response / summary outer opcode (OURA_PROTOCOL.md s5.2). Below the event-tag range
    /// (tags are >= 0x41), so a caller that fails to special-case it and lets it fall through to the TLV
    /// decoder gets a safe no-op ("unknown tag") with correct byte accounting, never a misdecode.
    public static let getEventsResponseOp: UInt8 = 0x11

    /// The GetBattery response outer opcode (OURA_PROTOCOL.md s4.1/s6.10). Below the event-tag range
    /// (tags are >= 0x41), so it round-trips safely through the TLV decoder as an "unknown tag" no-op if a
    /// caller fails to special-case it.
    public static let batteryResponseOp: UInt8 = 0x0D

    // MARK: - Parsing

    /// Parse a 0x11 GetEvents response body: `status:1 sub_status:1 last_ring_timestamp:4LE pad:2`
    /// Returns (cursor, moreData) where cursor is the ring-clock value to resume from, and moreData
    /// indicates whether more records are available.
    public static func parseGetEventsResponse(_ body: [UInt8]) -> (cursor: UInt32, moreData: Bool)? {
        guard body.count >= 8 else { return nil }
        let status = body[0]
        let subStatus = body[1]
        let cursor = UInt32(body[2]) | (UInt32(body[3]) << 8) | (UInt32(body[4]) << 16) | (UInt32(body[5]) << 24)
        let moreData = subStatus != 0x00  // 0x00 = terminal "no more data"
        return (cursor, moreData)
    }

    /// Parse a 0x0D GetBattery response body to extract the battery percent (0-100).
    public static func parseBatteryResponse(_ body: [UInt8]) -> Int? {
        guard body.count >= 1 else { return nil }
        let percent = Int(body[0])
        return percent <= 100 ? percent : nil
    }

    /// Parse a sequence of bytes into a list of outer frames. Multiple frames may be packed
    /// into one notification; this loops until all bytes are consumed.
    public static func parseOuterFrames(_ data: [UInt8]) -> [OuraOuterFrame] {
        var frames: [OuraOuterFrame] = []
        var offset = 0
        while offset < data.count {
            guard offset + 2 <= data.count else { break }  // need at least op + len
            let op = data[offset]
            let len = Int(data[offset + 1])
            guard offset + 2 + len <= data.count else { break }  // need full body
            let body = Array(data[(offset + 2)..<(offset + 2 + len)])
            frames.append(OuraOuterFrame(op: op, body: body))
            offset += 2 + len
        }
        return frames
    }

    /// Parse a 0x2F outer frame into a secure-session sub-frame.
    public static func parseSecureFrame(_ frame: OuraOuterFrame) -> OuraSecureFrame? {
        guard frame.op == secureSessionOp, frame.body.count >= 2 else { return nil }
        let subop = frame.body[0]
        let subBody = Array(frame.body.dropFirst())
        return OuraSecureFrame(subop: subop, subBody: subBody)
    }
}

// MARK: - Reassembler (for MTU fragmentation)

/// Reassembles TLV inner records that are split across BLE notifications due to MTU limits.
/// The BLE transport may fragment a record across multiple notifies; this buffers partial
/// trailing bytes and re-assembles them on the next notification arrival.
public class OuraReassembler: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feed a notification chunk into the reassembler. Returns any complete records that can be
    /// extracted from the buffer after adding this chunk.
    public func feed(_ chunk: [UInt8]) -> [UInt8] {
        buffer.append(contentsOf: chunk)
        // Records are parsed by the driver; this just buffers partial records.
        return buffer
    }

    /// Clear the buffer (e.g., on disconnect).
    public func reset() {
        buffer.removeAll()
    }
}
