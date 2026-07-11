//
//  OuraProtocolDecoder.swift
//  PulseLoopIOS - Oura Ring Extension
//
//  Interpret layer (decode step): packet framing, AES-based App-Auth
//  handshake, and event-to-sample decoding.
//  Ported conceptually from open_oura's oura-protocol crate
//  (https://github.com/Th0rgal/open_oura).
//
//  IMPORTANT: The exact AES mode, key derivation, and byte layouts below
//  are PLACEHOLDERS. Before use, they must be replaced with the precise
//  values documented in open_oura's oura-protocol source/docs, since any
//  deviation will make the ring reject the handshake or corrupt decoded
//  samples.
//

import Foundation
import CryptoKit

enum OuraDecoderError: Error {
    case malformedFrame
    case unsupportedEventType(UInt8)
    case authFailed
    case incompleteFrame
}

enum OuraEventType: UInt8 {
    case heartRate = 0x01
    case hrv = 0x02
    case spo2 = 0x03
    case sleepStage = 0x04
    case activity = 0x05
    case temperature = 0x06
    // TODO: extend with all event types documented in open_oura oura-protocol
}

struct OuraRawEvent {
    let type: OuraEventType
    let timestamp: Date
    let payload: Data
}

enum OuraDecodedSample {
    case heartRate(bpm: Int, timestamp: Date)
    case hrv(rmssd: Double, timestamp: Date)
    case spo2(percentage: Double, timestamp: Date)
    case sleepStage(stage: SleepStage, timestamp: Date)
    case activity(steps: Int, calories: Double, timestamp: Date)
    case temperature(celsius: Double, timestamp: Date)
}

enum SleepStage: UInt8 {
    case awake = 0
    case light = 1
    case deep = 2
    case rem = 3
}

final class OuraProtocolDecoder {

    private var sessionKey: SymmetricKey?
    private var lastCursor: UInt32 = 0

    // MARK: - Authentication (AES App-Auth handshake)

    /// Builds the initial challenge request sent to the ring's auth
    /// characteristic. Mirrors the first step of open_oura's App-Auth flow.
    func buildAuthChallengeRequest() throws -> Data {
        // TODO: replace with the actual challenge frame structure from
        // open_oura oura-protocol (opcode + nonce + device id, etc.)
        var frame = Data()
        frame.append(0xA1) // placeholder opcode for "auth request"
        let nonce = generateNonce()
        frame.append(nonce)
        return frame
    }

    /// Completes the handshake: derives the AES session key from the
    /// ring's challenge response using the shared App-Auth secret.
    func completeAuthHandshake(responseData: Data) throws -> SymmetricKey {
        guard responseData.count >= 16 else { throw OuraDecoderError.authFailed }

        // TODO: replace with the real key derivation from open_oura.
        // open_oura documents an AES-based derivation combining a
        // device-specific secret with the ring's challenge nonce.
        let derivedKeyMaterial = SHA256.hash(data: responseData)
        return SymmetricKey(data: Data(derivedKeyMaterial))
    }

    func setSessionKey(_ key: SymmetricKey) {
        self.sessionKey = key
    }

    private func generateNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    // MARK: - History request / cursor

    func buildHistoryRequest(sinceCursor cursor: UInt32) throws -> Data {
        var frame = Data()
        frame.append(0xB1) // placeholder opcode for "history request"
        withUnsafeBytes(of: cursor.bigEndian) { frame.append(contentsOf: $0) }
        return frame
    }

    func isEndOfHistoryMarker(_ frame: Data) -> Bool {
        // TODO: replace with the real end-of-history marker byte(s)
        return frame.first == 0xFF
    }

    func latestCursor() -> UInt32 {
        return lastCursor
    }

    // MARK: - Frame extraction (handles BLE MTU fragmentation)

    /// Extracts one complete, length-prefixed frame from the buffer if
    /// available, returning the frame and the remaining unconsumed bytes.
    func extractCompleteFrame(from buffer: Data) -> (frame: Data, remaining: Data)? {
        guard buffer.count >= 2 else { return nil }
        let lengthPrefix = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
        let headerSize = 2
        guard buffer.count >= headerSize + lengthPrefix else { return nil }

        let frameEnd = buffer.startIndex + headerSize + lengthPrefix
        let frame = buffer.subdata(in: (buffer.startIndex + headerSize)..<frameEnd)
        let remaining = buffer.subdata(in: frameEnd..<buffer.endIndex)
        return (frame, remaining)
    }

    // MARK: - Frame decryption + event decoding

    func decodeFrame(_ frame: Data) throws -> [OuraRawEvent] {
        guard let key = sessionKey else { throw OuraDecoderError.authFailed }
        let decrypted = try decryptFrame(frame, using: key)
        return try parseEvents(from: decrypted)
    }

    private func decryptFrame(_ frame: Data, using key: SymmetricKey) throws -> Data {
        // TODO: replace with the real AES mode used by the ring
        // (open_oura documents the exact mode/IV handling in oura-protocol).
        guard frame.count > 12 else { throw OuraDecoderError.malformedFrame }
        let nonceData = frame.prefix(12)
        let ciphertext = frame.suffix(from: frame.startIndex + 12)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(combined: nonce.withUnsafeBytes { Data($0) } + ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private func parseEvents(from data: Data) throws -> [OuraRawEvent] {
        var events: [OuraRawEvent] = []
        var offset = data.startIndex

        while offset < data.endIndex {
            guard offset + 9 <= data.endIndex else { break } // 1 type + 4 timestamp + 4 length (example layout)
            let typeByte = data[offset]
            guard let eventType = OuraEventType(rawValue: typeByte) else {
                throw OuraDecoderError.unsupportedEventType(typeByte)
            }
            let tsRange = (offset + 1)..<(offset + 5)
            let timestampRaw = data.subdata(in: tsRange).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampRaw))

            let lenRange = (offset + 5)..<(offset + 9)
            let payloadLength = Int(data.subdata(in: lenRange).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })

            let payloadStart = offset + 9
            let payloadEnd = payloadStart + payloadLength
            guard payloadEnd <= data.endIndex else { break }
            let payload = data.subdata(in: payloadStart..<payloadEnd)

            events.append(OuraRawEvent(type: eventType, timestamp: timestamp, payload: payload))
            offset = payloadEnd
        }
        return events
    }

    // MARK: - Event -> typed sample interpretation

    func interpret(event: OuraRawEvent) -> OuraDecodedSample {
        switch event.type {
        case .heartRate:
            let bpm = Int(event.payload.first ?? 0)
            return .heartRate(bpm: bpm, timestamp: event.timestamp)
        case .hrv:
            let raw = event.payload.prefix(2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            return .hrv(rmssd: Double(raw) / 10.0, timestamp: event.timestamp)
        case .spo2:
            let raw = event.payload.first ?? 0
            return .spo2(percentage: Double(raw), timestamp: event.timestamp)
        case .sleepStage:
            let raw = event.payload.first ?? 0
            let stage = SleepStage(rawValue: raw) ?? .awake
            return .sleepStage(stage: stage, timestamp: event.timestamp)
        case .activity:
            let steps = Int(event.payload.prefix(2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
            let calories = Double(event.payload.suffix(2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }) / 10.0
            return .activity(steps: steps, calories: calories, timestamp: event.timestamp)
        case .temperature:
            let raw = event.payload.prefix(2).withUnsafeBytes { $0.load(as: Int16.self).bigEndian }
            return .temperature(celsius: Double(raw) / 100.0, timestamp: event.timestamp)
        }
    }
}
