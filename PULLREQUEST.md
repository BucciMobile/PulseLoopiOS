# Pull Request: Oura Ring (Gen 3/4/5) Support

## Overview

This PR adds experimental support for the Oura Ring (Gen 3/4/5) to PulseLoopIOS. The implementation follows the reverse-engineered protocol from [open_oura](https://github.com/Th0rgal/open_oura) and uses a clean three-layer architecture (fetch → interpret → apply).

## Changes

### New Files

- **`OuraBLEManager.swift`** – CoreBluetooth fetch layer
  - BLE service discovery and connection management
  - 3-step AES/ECB App-Auth handshake
  - History event sync and live data streaming
  - Uses real Oura Ring 3/4/5 UUIDs from open_oura docs

- **`OuraProtocolDecoder.swift`** – Protocol interpret layer
  - Packet framing and BLE MTU fragmentation handling
  - App-Auth nonce request/response/encryption
  - Event parsing with proper timestamp handling
  - Event type enums for all major metrics:
    * Heart rate (daytime `0x80`, overnight `0x60`)
    * HRV, SpO2 (R-ratio/PI `0x8b`), temperature
    * Sleep accelerometer (MAD), activity (MET), motion
  - Per-event-type sample interpretation

- **`OuraStore.swift`** – Persistence apply layer
  - Sync cursor management (UserDefaults)
  - Placeholder for Core Data / SQLite integration

- **`CHANGELOG.md`** – Project changelog
  - Documented all new features and known limitations
  - Notes on three-layer architecture
  - References to open_oura

- **`README_OURA_ADDENDUM.md`** – Fork addendum
  - Status overview (experimental, not production-ready)
  - Next steps for validation and integration
  - Credits and sources

### Protocol Details (from open_oura)

**Service & Characteristics:**
- Service: `98ed0001-a541-11e4-b6a0-0002a5d5c51b`
- Read/Notify: `98ed0003-a541-11e4-b6a0-0002a5d5c51b`
- Write: `98ed0002-a541-11e4-b6a0-0002a5d5c51b`
- MTU: 203 bytes

**App-Auth Flow:**
1. Request nonce: `0x2f 0x01 0x2b`
2. Receive nonce response: `0x2f 0x10 0x2c <15-byte nonce>`
3. Encrypt nonce with AES/ECB/PKCS5Padding (16-byte key)
4. Send encrypted nonce: `0x2f 0x11 0x2d <16-byte encrypted>`
5. Verify success: `0x2f 0x02 0x2e 0x00`

**Event Types Supported:**
- `0x01` Heart rate (basic)
- `0x80` Green IBI Quality (daytime HR)
- `0x60` IBI & Amplitude (overnight HR + PPG)
- `0x8b` SpO2 R-ratio + PI
- `0x02` HRV, `0x06` Temperature, `0x72` Sleep ACM, etc.

## Known Limitations & TODOs

### Security (Blocking)
- ⚠️ **AES/ECB implementation**: Currently a placeholder
  - CryptoKit doesn't support raw ECB mode
  - Must use CommonCrypto or third-party library
  - **This must be implemented before any production use**

### Data Persistence
- Core Data / SQLite integration not yet implemented
- Sync cursor stored in UserDefaults (temporary)
- Raw event bodies need lossless storage for future re-decoding

### Analysis
- Algorithm implementations deferred (HRV, sleep stages, readiness scores)
- Per-device SpO2 calibration coefficients not ported
- Sleep hypnogram generation not yet ported from open_oura

### Event Parsing
- Event-type-specific byte layouts need validation against real captures
- Bit-packed events (e.g., `0x71`, `0x6e`) deferred
- Debug data subtypes (~40 types) catalogued but not parsed

## Testing Recommendations

1. **Validate UUIDs** against a live Oura Ring 3/4/5
2. **Implement AES/ECB** with CommonCrypto
3. **Capture & validate** real event payloads against open_oura decoders
4. **Test auth handshake** with factory-reset and already-onboarded rings
5. **Incremental sync** with saved cursor across multiple sessions

## Branch & References

- Feature branch: `feature/oura-support`
- Base: open_oura (https://github.com/Th0rgal/open_oura)
  - Protocol cheatsheet: `docs/horizon-ring3-protocol-cheatsheet.md`
  - Event decoders: `crates/README.md` (event table)
  - Algorithms: `docs/algorithms/README.md`

## Credits

This implementation is based on the excellent reverse-engineering work in:
- **[open_oura](https://github.com/Th0rgal/open_oura)** – Oura Ring BLE protocol
- **[PulseLoopIOS](https://github.com/saksham2001/PulseLoopIOS)** – Base health tracker
- **[ringverse/protocol](https://github.com/ringverse/protocol)** – Early Ring 4 notes

## Next Steps

1. Merge to `main` for collaborative development
2. Implement AES/ECB crypto (security-critical)
3. Validate against real Oura Ring captures
4. Integrate Core Data persistence
5. Port analysis algorithms from open_oura
6. Add unit tests for protocol decoders
7. Test on Ring 3, 4, 5 hardware
