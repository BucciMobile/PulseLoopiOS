# PulseLoopiOS × NOOP Integration Roadmap

## Executive Summary
Diese Roadmap zeigt konkret, wie du NOOP's produktionsreife Oura-Integration (1200+ Zeilen, 18 Monate Entwicklung) in PulseLoopiOS übernehmen kannst. NOOP folgt einer **clean-room, modularen Architektur**, die sich 1:1 auf dein Projekt portieren lässt.

---

## 🎯 Priorität 1: Modul-Separation (FOUNDATION)

### Problem in PulseLoopiOS heute
```swift
// OuraBLEManager.swift: ~600 Zeilen, alles vermischt
class OuraBLEManager {
    // CoreBluetooth + Protokoll + Persistierung + Crypto ALLE hier
    func handleBLENotification() { ... }  // BLE
    func decodeEvent() { ... }            // Protokoll
    func persistData() { ... }            // Storage
    // AES/ECB als Platzhalter ⚠️
}
```

### NOOP-Lösung: Separierte Packages
```
Packages/
├── OuraProtocol/                    ← PURE, headless-testbar (KEINE CoreBluetooth)
│   ├── OuraGatt.swift               # UUIDs + MTU facts
│   ├── Framing.swift                # Outer/Secure/TLV frame parsing
│   ├── Auth.swift                   # AES/ECB crypto (CommonCrypto)
│   ├── Commands.swift               # Opcode builders
│   ├── EventTags.swift              # Event-tag dictionary
│   ├── Decoders.swift               # Per-tag byte→value decoders
│   ├── OuraDriver.swift             # State machine (auth→stream→history)
│   ├── OuraEvents.swift             # Decoded structs (OuraHR, OuraIBI, etc.)
│   └── Tests/                       # Swift test suite (no BLE!)
│
└── StrandImport/                    ← (Optional: Oura file import if needed)
```

**Vorteil:** Protocol-Package kann unter Linux gebaut + getestet werden, ohne physisches iPhone/Ring.

### Implementation Steps
1. **Neue Package erstellen** (mirroring `Packages/WhoopProtocol`):
   ```bash
   cd Packages
   swift package create --type library OuraProtocol
   ```

2. **CoreBluetooth-freie Module**:
   - `OuraGatt.swift` → UUIDs als String (NOOP: `OuraGatt.serviceUUID = "98ED..."`), nicht `CBUUID`
   - `Auth.swift` → Pure Crypto (`import CommonCrypto`, nicht `import CoreBluetooth`)
   - `Framing.swift` → Raw byte parsing (keine Callbacks)

3. **Tests schreiben** (NOOP: 80+ Unit Tests):
   ```swift
   import XCTest
   import OuraProtocol
   
   class AuthTests: XCTestCase {
       func testAESECBEncryption() {
           let nonce: [UInt8] = [...15 bytes...]
           let key: [UInt8] = [...16 bytes...]
           let proof = OuraAuth.encryptNonce(nonce, with: key)
           XCTAssertEqual(proof.count, 16)  // ✅ No BLE, just crypto
       }
   }
   ```

---

## 🎯 Priorität 2: AES/ECB Crypto Implementation

### Problem heute
```swift
// OuraProtocolDecoder.swift
// ⚠️ AES/ECB implementation: Currently a placeholder
// CryptoKit doesn't support raw ECB mode
// Must use CommonCrypto or third-party library
```

### NOOP-Lösung: CommonCrypto ECB Wrapper

```swift
// OuraProtocol/Auth.swift
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

public enum OuraAuth {
    /// AES-128/ECB with PKCS#7 full-block padding (OURA_PROTOCOL.md s3.4)
    public static func encryptNonce(_ nonce: [UInt8], 
                                    with key: [UInt8]) throws -> [UInt8] {
        guard key.count == 16 else { throw OuraAuthError.badKeyLength }
        guard nonce.count == 15 else { throw OuraAuthError.badNonceLength }
        
        // Plaintext: nonce(15) || 0x01
        var plaintext = nonce + [0x01]
        
        // PKCS#7 full-block pad: append 0x10 (16 bytes)
        let padByte: UInt8 = 0x10
        plaintext.append(contentsOf: [UInt8](repeating: padByte, count: 16))
        // Now plaintext = 32 bytes (nonce + marker + full-block pad)
        
        // AES-128/ECB encrypt
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        var encryptedCount = 0
        
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),  // ← ECB mode (no IV)
            key,
            key.count,
            nil,  // no IV for ECB
            plaintext,
            plaintext.count,
            &ciphertext,
            ciphertext.count,
            &encryptedCount
        )
        
        guard status == kCCSuccess else { throw OuraAuthError.encryptionFailed }
        
        // Return ONLY the first 16 bytes (first ciphertext block)
        return Array(ciphertext.prefix(16))
    }
}
```

**CommonCrypto einbinden:**
```swift
// Package.swift
.target(
    name: "OuraProtocol",
    dependencies: [],
    linkerSettings: [
        .linkedFramework("CommonCrypto", .when(platforms: [.iOS, .macOS]))
    ]
)
```

**Test:**
```swift
func testAESECB() {
    let nonce: [UInt8] = [0x01, 0x02, ..., 0x0F]  // 15 bytes
    let key: [UInt8] = [0xAA, 0xBB, ..., 0xFF]    // 16 bytes
    
    let proof = try OuraAuth.encryptNonce(nonce, with: key)
    XCTAssertEqual(proof.count, 16)  // ✅
}
```

---

## 🎯 Priorität 3: OuraDriver State Machine

### Problem heute
```swift
// OuraBLEManager: linear handshake, hard to test
func authenticateRing() {
    // Step 1: send nonce request
    // Step 2: receive nonce
    // Step 3: compute proof
    // Step 4: send proof
    // Step 5: ...
    // No state recovery, no history tracking
}
```

### NOOP-Lösung: Pure State Machine
```swift
// OuraProtocol/OuraDriver.swift
public enum OuraPhase: Equatable {
    case idle
    case discovering
    case awaitingNonce
    case awaitingAuthStatus
    case needsKeyInstall
    case authFailed(OuraAuthStatus)
    case streaming
}

public class OuraDriver {
    public private(set) var phase: OuraPhase = .idle
    private let authKey: [UInt8]?
    private let allowKeyInstall: Bool
    
    /// Progress through the state machine on a transition.
    /// PURE: returns the next commands to write; NO side effects.
    public func nextStep(after transition: OuraTransition) -> [OuraCommand] {
        switch (phase, transition) {
        case (.idle, .ready):
            phase = .awaitingNonce
            return [OuraCommands.getAuthNonce()]  // ← Byte sequence, no BLE
            
        case (.awaitingNonce, .nonceReceived(let nonce)):
            do {
                let proof = try OuraAuth.encryptNonce(nonce, with: authKey ?? [])
                phase = .awaitingAuthStatus
                return [OuraCommands.authenticate(proof: proof)]
            } catch {
                phase = .authFailed(.authError)
                return []
            }
            
        case (.awaitingAuthStatus, .authCompleted(let status)):
            if status.isSuccess {
                phase = .streaming
                return OuraCommands.enableLiveHR()  // ← 3-step enable sequence
            } else {
                phase = .authFailed(status)
                return []
            }
            
        // ... handle history fetch, re-auth on key install, etc.
        default:
            return []
        }
    }
}
```

**Vorteil:** Unit-testbar ohne CoreBluetooth:
```swift
func testAuthenticationFlow() {
    let driver = OuraDriver(authKey: [...16 bytes...])
    
    // Step 1: Request nonce
    var commands = driver.nextStep(after: .ready)
    XCTAssertEqual(commands.first?.label, "get_auth_nonce")
    XCTAssertEqual(driver.phase, .awaitingNonce)
    
    // Step 2: Receive nonce → compute proof
    commands = driver.nextStep(after: .nonceReceived([...15 bytes...]))
    XCTAssertEqual(commands.first?.label, "authenticate")
    XCTAssertEqual(driver.phase, .awaitingAuthStatus)
    
    // Step 3: Auth OK → enable HR
    commands = driver.nextStep(after: .authCompleted(.success))
    XCTAssertEqual(driver.phase, .streaming)
    XCTAssert(commands.contains { $0.label == "enable_live_hr" })
}
```

---

## 🎯 Priorität 4: History Fetch Cursor Tracking

### Problem heute
```swift
// OuraStore.swift
// Sync cursor stored in UserDefaults (temporary)
// No handling of ring-time regression
// No periodic re-fetch for sleep data
```

### NOOP-Lösung: Robust Cursor Management

```swift
// OuraProtocol/OuraHistoryCursor.swift
public struct OuraHistoryFetch {
    /// Ring-clock value (ringTimestamp = (session << 16) | counter)
    /// NOOP handles session shifts: if a cursor comes back SMALLER on a new
    /// connection, the session has shifted → reset to 0 (not a real resume).
    private var cursor: UInt32 = 0
    
    /// Detect ring-time regression (session component shifted).
    private func detectRegression(newCursor: UInt32) -> Bool {
        // ringTimestamp = (session << 16) | counter
        // If newCursor < cursor AND session bits differ, it's a regression
        let prevSession = cursor >> 16
        let newSession = newCursor >> 16
        return newCursor < cursor && newSession != prevSession
    }
    
    public mutating func advance(_ newCursor: UInt32, moreData: Bool) {
        if moreData {
            if detectRegression(newCursor: newCursor) {
                // Ring restarted → reset to 0 for full re-fetch
                cursor = 0
            } else {
                cursor = newCursor
            }
        }
        // On terminal response (moreData=false), cursor is zero-filled → ignore it
    }
}

// Persist to GRDB instead of UserDefaults
// Loads on connect: historyCursor = store.readCursor(deviceId: deviceId)
```

### Periodic Re-fetch (for sleep data arriving overnight)
```swift
// OuraLiveSource.swift in Strand/BLE/
private var historyFetchTimer: Timer?
private let historyFetchInterval: TimeInterval = 900  // 15 min

private func startHistoryFetchTimer() {
    stopHistoryFetchTimer()
    let t = Timer.scheduledTimer(withTimeInterval: historyFetchInterval, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.fetchHistoryIfIdle() }
    }
    historyFetchTimer = t
}

private func fetchHistoryIfIdle() {
    // ONLY fetch when driver is idle (not already fetching)
    guard let driver, driver.phase == .streaming else { return }
    log("Oura: fetching history from cursor \(historyCursor)")
    advance(.startHistoryFetch(cursor: historyCursor))
}

// On connect: immediately fetch
// Then: re-fetch every 15 min while connected
// ✅ Sleep data arrives without reconnect
```

---

## 🎯 Priorität 5: Multi-Device Registry Pattern

### Problem heute
```swift
// PulseLoopiOS: single Oura ring only
var ouraBLEManager: OuraBLEManager?
// Can't pair with multiple rings or WHOOP + Oura simultaneously
```

### NOOP-Lösung: Device Registry

```swift
// Strand/Data/DeviceRegistry.swift
public class DeviceRegistry: ObservableObject {
    @Published public var devices: [PairedDevice] = []
    @Published public var activeDeviceId: String?
    
    // Add new device (Oura ring, WHOOP strap, HR strap, Mi Band import, etc.)
    public func add(device: PairedDevice) { ... }
    
    // Switch active device
    public func setActive(_ deviceId: String) { ... }
    
    // Remove device
    public func remove(_ deviceId: String) { ... }
}

// Usage:
let registry = DeviceRegistry()
registry.add(PairedDevice(id: "my-oura", model: "Oura Ring 5", ...))
registry.add(PairedDevice(id: "my-whoop", model: "WHOOP 5.0", ...))
registry.setActive("my-oura")  // ← Only one active at a time
```

**Advantage:** In PulseLoopiOS später können Nutzer zwischen Oura rings wechseln oder Oura + einer anderen Quelle kombinieren.

---

## 🎯 Priorität 6: Storage Layer Upgrade

### Problem heute
```swift
// OuraStore.swift
// Core Data / SQLite integration not yet implemented
// Sync cursor stored in UserDefaults (temporary)
// Raw event bodies need lossless storage
```

### NOOP-Lösung: GRDB (Swift-native SQLite)

```swift
// Packages/WhoopStore/ (reuse NOOP's schema)
import GRDB

struct OuraRawEvent: Codable, PersistableRecord {
    var id: Int64?
    var deviceId: String           // "my-oura-ring-1", "my-oura-ring-2", etc.
    var ringTimestamp: UInt32      // ring's own clock
    var utcSeconds: Int?           // nil until anchor arrives
    var eventType: String          // "hr", "ibi", "hrv", "spo2", "temp", "sleep"
    var payload: String            // JSON-encoded event
    var createdAt: Date
}

// Usage:
let db = try DatabaseQueue(path: "oura.db")
try db.write { db in
    let event = OuraRawEvent(
        deviceId: "my-oura",
        ringTimestamp: 1234567,
        eventType: "hr",
        payload: #"{"bpm": 72, "ibi": 833}"#
    )
    try event.insert(db)
}
```

**Advantage:**
- ✅ Durable (survives app restart)
- ✅ Queryable (find all HR samples for a day)
- ✅ Per-device scoped (multiple rings, zero mixing)
- ✅ Cursor-safe (resume history from exact last point)

---

## 🎯 Priorität 7: Auto-Reconnect + Error Handling

### Problem heute
```swift
// OuraBLEManager: manual reconnect only
// If ring drops: user must manually re-pair
```

### NOOP-Lösung: Capped-Exponential Backoff

```swift
// OuraLiveSource.swift (#912 pattern)
private var reconnectID: UUID?
private var failedReconnectAttempts = 0

private func scheduleReconnect() {
    guard !intentionalDisconnect, let id = reconnectID else { return }
    failedReconnectAttempts += 1
    
    // Backoff: 3s, 6s, 12s, 24s, 48s, 60s (capped)
    let delay = min(60.0, 3.0 * pow(2.0, Double(max(0, failedReconnectAttempts - 1))))
    
    log("Oura: reconnecting in \(Int(delay))s (attempt \(failedReconnectAttempts))")
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, !self.intentionalDisconnect, self.reconnectID == id else { return }
        self.connect(id)  // ← Re-try
    }
}

// On involuntary disconnect: scheduleReconnect()
// On intentional stop: intentionalDisconnect = true → no retry
// ✅ Ring comes back on its own, user doesn't notice
```

---

## 🎯 Priorität 8: Honest Pairing State

### Problem heute
```swift
// OuraBLEManager: no public "needs pairing" state
// Unclear when ring is factory-reset or key is wrong
```

### NOOP-Lösung: Public Error State

```swift
// OuraLiveSource.swift
@Published public var needsPairing: String? = nil

// Set when:
// - Ring is factory-reset (auth status .inFactoryReset)
// - No install key available
// - Auth key was rejected

// UI displays:
let msg = needsPairing ?? "Connected – streaming HR"
Text(msg)  // ← Honest feedback to user
```

**Advantage:** User knows exactly why pairing failed, instead of silent failure.

---

## 🎯 Priorität 9: Data Mapping (Events → Streams)

### Problem heute
```swift
// Raw decoded events: [OuraHR, OuraIBI, OuraSpO2, ...]
// How do they become HealthKit-compatible values?
// No stream normalization
```

### NOOP-Lösung: OuraStreamMapping

```swift
// OuraProtocol/OuraStreamMapping.swift
public enum OuraStreamMapping {
    /// Pure mapping: decoded events → storage-ready Streams
    public static func streams(from events: [OuraEvent], at timestamp: Int) -> Streams {
        var result = Streams()
        
        for event in events {
            switch event {
            case .hr(let hr):
                result.hrSamples.append(HrSample(
                    ts: timestamp,
                    bpm: hr.bpm
                ))
            
            case .ibi(let ibi):
                result.rrIntervals.append(RrInterval(
                    ts: timestamp,
                    rrMs: ibi.ibiMs
                ))
            
            case .spo2(let s):
                result.spo2Samples.append(Spo2Sample(
                    ts: timestamp,
                    value: s.value
                ))
            
            // ... temp, hrv, sleep-phase mapped similarly
            }
        }
        
        return result
    }
}
```

---

## 📋 Implementation Checklist

### Phase 1: Foundation (Weeks 1–2)
- [ ] `Packages/OuraProtocol/` erstellen
- [ ] `OuraGatt.swift` → CoreBluetooth-freie UUIDs
- [ ] `Auth.swift` → CommonCrypto ECB
- [ ] `Tests/AuthTests.swift` → Unit Tests

### Phase 2: State Machine (Weeks 2–3)
- [ ] `OuraDriver.swift` → State machine
- [ ] `OuraTransition` enum definieren
- [ ] `OuraCommand` builders (auth, enable, history)
- [ ] Tests für jeden state transition

### Phase 3: BLE Integration (Weeks 3–4)
- [ ] `OuraLiveSource.swift` als App-Layer Wrapper
- [ ] CoreBluetooth connect/discover/notify
- [ ] Driver wiring (commands write, responses route)
- [ ] Auto-reconnect logic

### Phase 4: Storage + History (Weeks 4–5)
- [ ] GRDB migration (oder Core Data, wenn preferred)
- [ ] Cursor tracking (persistence + regression detection)
- [ ] Periodic history fetch timer
- [ ] Per-device scoping

### Phase 5: Testing + Validation (Weeks 5–6)
- [ ] Unit tests für Protocol Package (Linux-testbar)
- [ ] Integration tests mit captured Ring-Frames
- [ ] Hardware validation (echte Ring 3/4/5)
- [ ] Prod build + TestFlight

---

## 📊 Expected Outcome

| Aspekt | Vorher | Nachher |
|--------|--------|---------|
| **Krypto** | ⚠️ Platzhalter | ✅ CommonCrypto ECB |
| **Testbarkeit** | ~5% (BLE-only) | ✅ 80%+ (Protocol pure) |
| **Fehlerbehandlung** | Nicht robust | ✅ Honest states (needs pairing, reconnect backoff) |
| **History-Sync** | Manuell | ✅ Auto 15-min re-fetch |
| **Multi-Device** | Nicht möglich | ✅ Via DeviceRegistry |
| **Cursor Regression** | Nicht gehandhabt | ✅ Detected + auto-reset |
| **Code-Wiederverwendung** | 0% | ✅ 70%+ mit NOOP |
| **Dev Time to Prod** | ? | ~6 Wochen |

---

## 🔗 References

- NOOP's `OuraProtocol` Package: https://github.com/ryanbr/noop/tree/main/Packages/OuraProtocol
- NOOP's `OuraLiveSource.swift`: https://github.com/ryanbr/noop/blob/main/Strand/BLE/OuraLiveSource.swift
- open_oura Protocol Docs: https://github.com/Th0rgal/open_oura/blob/main/docs/horizon-ring3-protocol-cheatsheet.md
- CommonCrypto ECB Example: NOOP's `Auth.swift` line 45–85

---

## ⚠️ Critical Path Items

1. **AES/ECB Crypto ist BLOCKING** → ohne diese kein Auth
2. **OuraDriver State Machine ist FOUNDATION** → alles baut drauf auf
3. **Unit tests für Protocol Package early** → spart Tage im Debugging
4. **Hardware validation mit echtem Ring** → vor Production release nötig

**Estimated Effort:** 4–6 Wochen für einen Swift-Entwickler + 2–3 Tage Hardware-Testing.

