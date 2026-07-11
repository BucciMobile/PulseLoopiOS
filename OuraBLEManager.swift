//
//  OuraBLEManager.swift
//  PulseLoopIOS - Oura Ring Extension
//
//  Fetch layer: BLE transport, pairing, authentication, and history/live sync
//  for Oura Ring (Gen 3/4/5), based on open_oura protocol documentation.
//  (https://github.com/Th0rgal/open_oura)
//
//  Service and characteristic UUIDs are from the Oura Ring 3 Horizon BLE protocol.
//  Reference: docs/horizon-ring3-protocol-cheatsheet.md in open_oura.
//

import CoreBluetooth
import Foundation
import Combine

enum OuraBLEError: Error {
    case notConnected
    case authenticationFailed
    case invalidResponse
    case timeout
    case bluetoothUnavailable
}

enum OuraSyncState {
    case idle
    case scanning
    case connecting
    case authenticating
    case syncingHistory
    case streamingLive
    case error(OuraBLEError)
}

final class OuraBLEManager: NSObject, ObservableObject {

    // Oura Ring 3/4/5 BLE UUIDs (from open_oura protocol cheatsheet)
    // Reference: https://github.com/Th0rgal/open_oura/docs/horizon-ring3-protocol-cheatsheet.md
    private struct UUIDs {
        // Main GATT service for Oura Ring
        static let ouraService = CBUUID(string: "98ed0001-a541-11e4-b6a0-0002a5d5c51b")
        
        // Characteristics for bidirectional communication
        static let readCharacteristic = CBUUID(string: "98ed0003-a541-11e4-b6a0-0002a5d5c51b")    // Notify
        static let writeCharacteristic = CBUUID(string: "98ed0002-a541-11e4-b6a0-0002a5d5c51b")   // Write
    }

    @Published private(set) var state: OuraSyncState = .idle
    @Published private(set) var discoveredDevices: [CBPeripheral] = []

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var readCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?

    private let decoder = OuraProtocolDecoder()
    private let store = OuraStore()

    // Buffers incoming fragmented BLE packets before handing them to the decoder.
    private var rawFrameBuffer = Data()

    var onHistorySample: ((OuraDecodedSample) -> Void)?
    var onLiveSample: ((OuraDecodedSample) -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard centralManager.state == .poweredOn else {
            state = .error(.bluetoothUnavailable)
            return
        }
        state = .scanning
        centralManager.scanForPeripherals(withServices: [UUIDs.ouraService], options: nil)
    }

    func stopScan() {
        centralManager.stopScan()
    }

    func connect(to peripheral: CBPeripheral) {
        state = .connecting
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    /// Starts the App-Auth handshake required before history events can be read.
    /// Protocol: request nonce → encrypt nonce with AES/ECB → authenticate
    /// Reference: horizon-ring3-protocol-cheatsheet.md, "App Auth" section
    private func startAuthentication() {
        guard let peripheral = connectedPeripheral,
              let writeChar = writeCharacteristic else {
            state = .error(.notConnected)
            return
        }
        state = .authenticating

        do {
            // Step 1: Request nonce (opcode 0x2f, extended tag 0x2b)
            let nonceRequest = try decoder.buildNonceRequest()
            peripheral.writeValue(nonceRequest, for: writeChar, type: .withResponse)
        } catch {
            state = .error(.authenticationFailed)
        }
    }

    private func handleNonceResponse(_ data: Data) {
        do {
            // Step 2: Extract nonce, encrypt it, and send auth challenge
            let nonce = try decoder.extractNonce(from: data)
            let encryptedChallenge = try decoder.buildAuthChallenge(with: nonce)
            
            guard let peripheral = connectedPeripheral,
                  let writeChar = writeCharacteristic else {
                state = .error(.notConnected)
                return
            }
            
            peripheral.writeValue(encryptedChallenge, for: writeChar, type: .withResponse)
        } catch {
            state = .error(.authenticationFailed)
        }
    }

    private func handleAuthResponse(_ data: Data) {
        do {
            // Step 3: Verify auth success, set decoder session state
            try decoder.completeAuthentication(responseData: data)
            beginHistorySync()
        } catch {
            state = .error(.authenticationFailed)
        }
    }

    private func beginHistorySync() {
        guard let peripheral = connectedPeripheral,
              let writeChar = writeCharacteristic else { return }
        state = .syncingHistory
        let cursor = store.lastSyncCursor()
        do {
            let request = try decoder.buildHistoryRequest(sinceCursor: cursor)
            peripheral.writeValue(request, for: writeChar, type: .withResponse)
        } catch {
            state = .error(.invalidResponse)
        }
    }

    private func handleIncomingFrame(_ data: Data, isLive: Bool) {
        rawFrameBuffer.append(data)

        while let (frame, remaining) = decoder.extractCompleteFrame(from: rawFrameBuffer) {
            rawFrameBuffer = remaining
            do {
                let events = try decoder.decodeFrame(frame)
                for event in events {
                    store.persistRawEvent(event)
                    let sample = decoder.interpret(event: event)
                    store.persistSample(sample)
                    if isLive {
                        onLiveSample?(sample)
                    } else {
                        onHistorySample?(sample)
                    }
                }
                if decoder.isEndOfHistoryMarker(frame) {
                    store.updateSyncCursor(decoder.latestCursor())
                    state = .idle
                }
            } catch {
                state = .error(.invalidResponse)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension OuraBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOff, .unsupported, .unauthorized:
            state = .error(.bluetoothUnavailable)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredDevices.contains(peripheral) {
            discoveredDevices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([UUIDs.ouraService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error(.notConnected)
    }
}

// MARK: - CBPeripheralDelegate

extension OuraBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == UUIDs.ouraService {
            peripheral.discoverCharacteristics(
                [UUIDs.readCharacteristic, UUIDs.writeCharacteristic],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case UUIDs.readCharacteristic:
                readCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case UUIDs.writeCharacteristic:
                writeCharacteristic = characteristic
            default:
                break
            }
        }
        startAuthentication()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        // BLE frames are tagged; interpret based on extended/basic tag
        if data.count >= 2 {
            let tag = data[0]
            let extTag = data.count >= 2 ? data[1] : UInt8(0)
            
            switch (tag, extTag) {
            case (0x2f, 0x10): // Nonce response (extended tag 0x2f, payload tag 0x10)
                handleNonceResponse(data)
            case (0x2f, 0x02): // Auth response (extended tag 0x2f, payload tag 0x02)
                handleAuthResponse(data)
            case (0x11, _): // History event summary or frame data
                handleIncomingFrame(data, isLive: false)
            default:
                // Other frames (e.g., live data, status)
                handleIncomingFrame(data, isLive: true)
            }
        }
    }
}
