# Changelog

Alle nennenswerten Änderungen an diesem Fork von PulseLoopIOS werden hier
dokumentiert. Format angelehnt an [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
Versionierung angelehnt an [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

### Added
- Neues `OuraBLEManager.swift`: CoreBluetooth-Fetch-Layer für Oura Ring (Gen 3/4/5),
  inkl. Scan, Connect, AES-App-Auth-Handshake, History-Sync und Live-Streaming.
  Architektur orientiert an open_oura (https://github.com/Th0rgal/open_oura),
  Crate `oura-link`.
- Neues `OuraProtocolDecoder.swift`: Interpret-Layer mit Paket-Framing,
  AES-Session-Key-Handshake und Event-zu-Sample-Dekodierung
  (Herzfrequenz, HRV, SpO2, Schlafphasen, Aktivität, Temperatur).
  Orientiert an open_oura, Crate `oura-protocol`.
- Neues `OuraStore.swift`: Apply-Layer zur persistenten Ablage von
  Rohereignissen, dekodierten Samples und Sync-Cursor, analog zu
  open_oura, Crate `oura-store`.
- Grundgerüst für zukünftiges `OuraAnalysisEngine.swift` zur Berechnung
  von HRV-, Schlaf- und Readiness-Scores (in Planung, noch nicht enthalten).

### Known Limitations / TODO
- Alle Service-/Characteristic-UUIDs in `OuraBLEManager.swift` sind
  Platzhalter und müssen durch die tatsächlichen, in open_oura dokumentierten
  Werte ersetzt werden.
- AES-Schlüsselableitung und Verschlüsselungsmodus in
  `OuraProtocolDecoder.swift` sind vereinfachte Platzhalter und müssen
  gegen die exakte Implementierung aus open_oura (oura-protocol) validiert werden.
- Event-Byte-Layouts (Offsets, Feldlängen) sind Beispielannahmen und müssen
  mit den realen Oura-Paketstrukturen abgeglichen werden.
- `OuraStore.swift` enthält noch keine konkrete Core Data / SQLite-Anbindung
  an das bestehende PulseLoopIOS-Datenmodell.
- Analyse-Algorithmen (HRV, Schlaf, Readiness, SleepNet) aus
  open_oura/oura-analysis wurden noch nicht portiert.

### Notes
- Die Portierung erfolgt konzeptionell entlang der Drei-Schichten-Architektur
  von open_oura (fetch -> interpret -> apply), angepasst an Swift/CoreBluetooth
  statt Rust.
- Das Projekt ryanbr/noop (WHOOP-Companion-App, nicht Oura) diente lediglich
  als grobe Inspiration für einen offline-first App-Aufbau, nicht für die
  eigentliche Protokoll-Dekodierung.

## Referenzen
- Basisprojekt: https://github.com/saksham2001/PulseLoopIOS
- Android-Port (Referenz): https://github.com/foureight84/PulseLoopAndroid
- Protokoll-Referenz Oura: https://github.com/Th0rgal/open_oura
- Architektur-Inspiration (offline-first, nicht Oura-Protokoll): https://github.com/ryanbr/noop
