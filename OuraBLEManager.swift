//
//  OuraBLEManager.swift
//  PulseLoopIOS - Oura Ring Extension
//
//  Fetch layer: BLE transport, pairing, authentication, and history/live sync
//  for Oura Ring (Gen 3/4/5), modeled after the fetch layer of open_oura
//  (https://github.com/Th0rgal/open_oura, crate: oura-link).
//
//  NOTE: Service/Characteristic UUIDs and exact byte offsets must be filled
//  in from the open_oura source (oura-link / oura-protocol crates) before
//  this compiles against a real device. Placeholders are marked TODO.
//

import CoreBluetooth
import Foundation
import Combine

enum OuraBLEError: Error {
    case notConnected
    case authenticationFailed
    case invalidResponse
    case timeout
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

    // TODO: Replace with the actual Oura service/characteristic UUIDs
    // as documented in open_oura's oura-link crate.
    private struct UUIDs {
        static let ouraService = CBUUID(string: "0000XXXX-0000-1000-8000-00805F9B34FB")
        static let authCharacteristic = CBUUID(string: "0000XXXX-0000-1000-8000-00805F9B34FB")
        static let historyCharacteristic = CBUUID(string: "0000XXXX-0000-1000-8000-00805F9B34FB")
        static let liveDataCharacteristic = CBUUID(string: "0000XXXX-0000-1000-8000-00805F9B34FB")
    }

    @Published private(set) var state: OuraSyncState = .idle
    @Published private(set) var discoveredDevices: [CBPeripheral] = []

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var authCharacteristic: CBCharacteristic?
    private var historyCharacteristic: CBCharacteristic?
    private var liveCharacteristic: CBCharacteristic?

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

    /// Kicks off the App-Auth handshake required before any history event
    /// can be read from the ring. Mirrors oura-protocol's AES-based
    /// authentication flow.
    private func startAuthentication() {
        guard let peripheral = connectedPeripheral,
              let authChar = authCharacteristic else {
            state = .error(.notConnected)
            return
        }
        state = .authenticating

        do {
            let challengeRequest = try decoder.buildAuthChallengeRequest()
            peripheral.writeValue(challengeRequest, for: authChar, type: .withResponse)
        } catch {
            state = .error(.authenticationFailed)
        }
    }

    private func handleAuthResponse(_ data: Data) {
        do {
            let sessionKey = try decoder.completeAuthHandshake(responseData: data)
            decoder.setSessionKey(sessionKey)
            beginHistorySync()
        } catch {
            state = .error(.authenticationFailed)
        }
    }

    private func beginHistorySync() {
        guard let peripheral = connectedPeripheral,
              let historyChar = historyCharacteristic else { return }
        state = .syncingHistory
        let cursor = store.lastSyncCursor()
        do {
            let request = try decoder.buildHistoryRequest(sinceCursor: cursor)
            peripheral.writeValue(request, for: historyChar, type: .withResponse)
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
        // TODO: handle poweredOff / unauthorized states with user-facing errors
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
                [UUIDs.authCharacteristic, UUIDs.historyCharacteristic, UUIDs.liveDataCharacteristic],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case UUIDs.authCharacteristic:
                authCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case UUIDs.historyCharacteristic:
                historyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case UUIDs.liveDataCharacteristic:
                liveCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        startAuthentication()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        switch characteristic.uuid {
        case UUIDs.authCharacteristic:
            handleAuthResponse(data)
        case UUIDs.historyCharacteristic:
            handleIncomingFrame(data, isLive: false)
        case UUIDs.liveDataCharacteristic:
            handleIncomingFrame(data, isLive: true)
        default:
            break
        }
    }
}
