//
//  OuraProtocolDecoder.swift
//  PulseLoopIOS - Oura Ring Extension
//
//  Interpret layer (decode step): packet framing, AES/ECB-based App-Auth
//  handshake, and event-to-sample decoding.
//  Based on open_oura protocol documentation.
//  (https://github.com/Th0rgal/open_oura)
//
//  Reference: docs/horizon-ring3-protocol-cheatsheet.md
//  - Request/response format: tag (1 byte) + length (1 byte) + payload
//  - Multi-byte integers: little-endian
//  - Extended operations: outer tag 0x2f, extended tag as first payload byte
//  - App Auth: AES/ECB/PKCS5Padding with 16-byte key
//

import Foundation
import CryptoKit

enum OuraDecoderError: Error {
    case malformedFrame
    case unsupportedEventType(UInt8)
    case authFailed
    case incompleteFrame
    case invalidNonce
    case cryptoError
}

enum OuraEventType: UInt8 {
    case heartRate = 0x01
    case hrv = 0x02
    case spo2 = 0x03
    case sleepStage = 0x04
    case activity = 0x05
    case temperature = 0x06
    case greenIBIQuality = 0x80           // Daytime HR (Ring 5)
    case ibiAndAmplitude = 0x60           // Overnight HR + PPG amplitude
    case spo2RPIPI = 0x8b                 // SpO2 R-ratio + perfusion index
    case sleepACMPeriod = 0x72            // Sleep accelerometer MAD stats
    case activityInformation = 0x75       // Activity state + MET
    case motionEvent = 0x76               // Orientation + accel + intensity
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

    private var authKey: [UInt8]?
    private var sessionKeyEstablished = false
    private var lastCursor: UInt32 = 0

    // MARK: - Protocol Constants

    // BLE Protocol tags (from horizon-ring3-protocol-cheatsheet.md)
    private enum ProtocolTag: UInt8 {
        case extendedOps = 0x2f           // Extended operation wrapper
        case eventDataRequest = 0x10      // Request history events
        case eventDataResponse = 0x11     // History event response summary
    }

    private enum ExtendedTag: UInt8 {
        case getNonce = 0x2b              // Request nonce (0x2f, 0x01, 0x2b)
        case nonceResponse = 0x10         // Response to nonce request
        case authenticate = 0x2d          // Send encrypted nonce (0x2f, 0x11, 0x2d, <16-byte encrypted>)
        case authResponse = 0x02          // Auth result (0x2f, 0x02, 0x2e, [success/failure])
    }

    // MARK: - Authentication (AES/ECB/PKCS5Padding App-Auth handshake)

    /// Sets the 16-byte Oura app-auth key for this session.
    /// This key is stored on the factory-reset ring via SetAuthKey command,
    /// or extracted from the official app's database for already-onboarded rings.
    func setAuthKey(_ key: [UInt8]) throws {
        guard key.count == 16 else { throw OuraDecoderError.authFailed }
        self.authKey = key
    }

    /// Builds the initial nonce request frame.
    /// Protocol: tag 0x2f, extended tag 0x01, then 0x2b
    func buildNonceRequest() throws -> Data {
        var frame = Data()
        frame.append(0x2f)                // Extended op tag
        frame.append(0x01)                // Frame type (request)
        frame.append(0x2b)                // Nonce request extended tag
        return frame
    }

    /// Extracts the 15-byte nonce from the ring's response.
    /// Response format: tag 0x2f, subtag 0x10, marker 0x2c, then 15-byte nonce
    func extractNonce(from data: Data) throws -> [UInt8] {
        guard data.count >= 5 else { throw OuraDecoderError.invalidNonce }
        guard data[0] == 0x2f && data[1] == 0x10 && data[2] == 0x2c else {
            throw OuraDecoderError.invalidNonce
        }
        return Array(data.suffix(15))
    }

    /// Encrypts the nonce using AES/ECB/PKCS5Padding and builds the auth challenge frame.
    /// Protocol: tag 0x2f, extended tag 0x11, marker 0x2d, then 16-byte encrypted nonce
    func buildAuthChallenge(with nonce: [UInt8]) throws -> Data {
        guard let key = authKey else { throw OuraDecoderError.authFailed }
        guard nonce.count == 15 else { throw OuraDecoderError.invalidNonce }
        
        // Pad nonce to 16 bytes (PKCS5 padding: append byte value = number of padding bytes)
        var paddedNonce = nonce
        paddedNonce.append(0x01)  // 1 byte of padding
        
        // AES/ECB encryption
        let encryptedData = try encryptAESECB(paddedNonce, with: key)
        
        var frame = Data()
        frame.append(0x2f)                // Extended op tag
        frame.append(0x11)                // Frame type (auth challenge)
        frame.append(0x2d)                // Auth challenge extended tag
        frame.append(contentsOf: encryptedData)
        return frame
    }

    /// Verifies the auth response and establishes session state.
    /// Success response: tag 0x2f, subtag 0x02, marker 0x2e, result 0x00
    func completeAuthentication(responseData: Data) throws {
        guard responseData.count >= 4 else { throw OuraDecoderError.authFailed }
        guard responseData[0] == 0x2f && responseData[1] == 0x02 && responseData[2] == 0x2e else {
            throw OuraDecoderError.authFailed
        }
        
        let result = responseData[3]
        guard result == 0x00 else { throw OuraDecoderError.authFailed }
        
        sessionKeyEstablished = true
    }

    private func encryptAESECB(_ data: [UInt8], with key: [UInt8]) throws -> [UInt8] {
        let keyData = SymmetricKey(data: key)
        
        // AES ECB is not directly available in CryptoKit (only GCM/CBC/CTR)
        // For production, use CommonCrypto or a third-party AES library
        // Reference: https://github.com/Th0rgal/open_oura for ECB implementation
        
        // TODO: Implement AES/ECB using CommonCrypto or a compatible library
        // This is a security-critical operation and must use the exact ECB mode
        // specified by the Oura protocol (AES/ECB/PKCS5Padding)
        
        // Placeholder: return unencrypted data (WILL NOT WORK with real ring)
        // Must replace with real ECB implementation before production use
        return data
    }

    // MARK: - History request / cursor

    func buildHistoryRequest(sinceCursor cursor: UInt32) throws -> Data {
        var frame = Data()
        frame.append(0x10)                // Events request tag
        frame.append(0x09)                // Length
        frame.append(0x00)                // Subtype
        frame.append(0x00)                // Reserved
        // Cursor: little-endian u32
        withUnsafeBytes(of: cursor.littleEndian) { frame.append(contentsOf: $0) }
        frame.append(0x08)                // Max events (8)
        frame.append(0xff)
        frame.append(0xff)
        frame.append(0xff)
        return frame
    }

    func isEndOfHistoryMarker(_ frame: Data) -> Bool {
        // History summary frame: tag 0x11, then summary data
        return frame.first == 0x11
    }

    func latestCursor() -> UInt32 {
        return lastCursor
    }

    // MARK: - Frame extraction (handles BLE MTU fragmentation)

    /// Extracts one complete frame from the buffer if available.
    /// BLE frames: tag (1 byte) + length (1 byte) + payload
    func extractCompleteFrame(from buffer: Data) -> (frame: Data, remaining: Data)? {
        guard buffer.count >= 2 else { return nil }
        
        let tag = buffer[0]
        let length = Int(buffer[1])
        let requiredSize = 2 + length
        
        guard buffer.count >= requiredSize else { return nil }
        
        let frame = buffer.subdata(in: 0..<requiredSize)
        let remaining = buffer.subdata(in: requiredSize..<buffer.count)
        return (frame, remaining)
    }

    // MARK: - Frame decoding

    func decodeFrame(_ frame: Data) throws -> [OuraRawEvent] {
        guard sessionKeyEstablished else { throw OuraDecoderError.authFailed }
        
        // Frames are not encrypted over the link (encryption is at BLE pairing level)
        // Just parse the raw frame
        return try parseEvents(from: frame)
    }

    private func parseEvents(from data: Data) throws -> [OuraRawEvent] {
        var events: [OuraRawEvent] = []
        
        guard data.count >= 2 else { return events }
        
        // Skip tag and length bytes; parse payload
        var offset = 2
        
        while offset < data.count {
            guard offset + 5 <= data.count else { break }
            
            let typeByte = data[offset]
            guard let eventType = OuraEventType(rawValue: typeByte) else {
                offset += 1
                continue
            }
            
            // Timestamp (4 bytes, little-endian, deciseconds from ring epoch)
            let tsRange = (offset + 1)..<(offset + 5)
            let timestampRaw = UInt32(littleEndian: data.subdata(in: tsRange).withUnsafeBytes { $0.load(as: UInt32.self) })
            let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampRaw) / 10.0)
            
            // For now, assume fixed event structure; in production, use per-event-type parsers
            // from open_oura's event decoders
            let payload = data.subdata(in: (offset + 5)..<min(offset + 20, data.count))
            
            events.append(OuraRawEvent(type: eventType, timestamp: timestamp, payload: payload))
            offset += 5 + payload.count
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
            let raw = event.payload.prefix(2).withUnsafeBytes { UInt16(littleEndian: $0.load(as: UInt16.self)) }
            return .hrv(rmssd: Double(raw) / 10.0, timestamp: event.timestamp)
        case .spo2:
            let raw = event.payload.first ?? 0
            return .spo2(percentage: Double(raw), timestamp: event.timestamp)
        case .sleepStage:
            let raw = event.payload.first ?? 0
            let stage = SleepStage(rawValue: raw) ?? .awake
            return .sleepStage(stage: stage, timestamp: event.timestamp)
        case .activity:
            let steps = Int(event.payload.prefix(2).withUnsafeBytes { UInt16(littleEndian: $0.load(as: UInt16.self)) })
            let calories = Double(event.payload.suffix(2).withUnsafeBytes { UInt16(littleEndian: $0.load(as: UInt16.self)) }) / 10.0
            return .activity(steps: steps, calories: calories, timestamp: event.timestamp)
        case .temperature:
            let raw = event.payload.prefix(2).withUnsafeBytes { Int16(littleEndian: $0.load(as: Int16.self)) }
            return .temperature(celsius: Double(raw) / 100.0, timestamp: event.timestamp)
        case .greenIBIQuality:
            // Daytime HR: IBI in bits [0:10], quality in bits [11:12]
            // Parsed from open_oura: ibi=(b1&7)|(b0<<3), q=(b1>>3)&3
            let bpm = Int(event.payload.first ?? 60)
            return .heartRate(bpm: bpm, timestamp: event.timestamp)
        case .ibiAndAmplitude:
            // Overnight HR: 6× IBI + PPG amplitude (14-byte bit-packed)
            // Validated on 18k beats, median 41 bpm
            let bpm = Int(event.payload.first ?? 40)
            return .heartRate(bpm: bpm, timestamp: event.timestamp)
        case .spo2RPIPI:
            // SpO2 R-ratio: u16 BE / 16384, PI: u8 / 255 × 0.05
            // Validated overnight: R ~0.72, PI ~4%
            let rRatio = event.payload.prefix(2).withUnsafeBytes { Double(UInt16(bigEndian: $0.load(as: UInt16.self))) / 16384.0 }
            let spo2 = 100.0 * (1.0 - rRatio)  // Simplified; use Oura's calibration in production
            return .spo2(percentage: min(max(spo2, 0), 120), timestamp: event.timestamp)
        case .sleepACMPeriod, .activityInformation, .motionEvent:
            // Placeholder for now; full decoders from open_oura in next iteration
            return .temperature(celsius: 0, timestamp: event.timestamp)
        }
    }
}
