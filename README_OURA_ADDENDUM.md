# Oura Ring Support (Fork Addendum)

Dieser Fork von [PulseLoopIOS](https://github.com/saksham2001/PulseLoopIOS)
erweitert die App um experimentelle Unterstützung für den Oura Ring
(Gen 3/4/5), basierend auf dem reverse-engineerten Protokoll aus
[open_oura](https://github.com/Th0rgal/open_oura).

## Neue Dateien

- `OuraBLEManager.swift` - CoreBluetooth Fetch-Layer (Scan, Connect, Auth, Sync)
- `OuraProtocolDecoder.swift` - Paket-Framing, AES-Auth, Event-Decoding
- `OuraStore.swift` - Persistenz von Rohdaten, Samples und Sync-Cursor

## Status

Dies ist ein **Code-Gerüst**, kein fertiges, produktionsreifes Feature.
Vor dem produktiven Einsatz müssen folgende Punkte mit den Originaldaten
aus open_oura validiert werden:

1. Reale Service-/Characteristic-UUIDs des Oura Rings
2. Exakter AES-Modus und Schlüsselableitung für den App-Auth-Handshake
3. Reale Byte-Layouts der einzelnen Event-Typen
4. Integration in das bestehende PulseLoopIOS-Datenmodell (Core Data)
5. Portierung der Analyse-Algorithmen (HRV, Schlaf, Readiness) aus
   open_oura/oura-analysis

## Mitwirken

Beiträge und Korrektionen der Protokolldetails sind willkommen - siehe
CONTRIBUTING.md des Basisprojekts und CHANGELOG.md für den aktuellen Stand.

## Quellen / Danksagung

- [saksham2001/PulseLoopIOS](https://github.com/saksham2001/PulseLoopIOS) - Basisprojekt
- [foureight84/PulseLoopAndroid](https://github.com/foureight84/PulseLoopAndroid) - Android-Port
- [Th0rgal/open_oura](https://github.com/Th0rgal/open_oura) - Oura BLE-Protokoll-Reverse-Engineering
- [ryanbr/noop](https://github.com/ryanbr/noop) - Architektur-Inspiration (WHOOP, nicht Oura)
