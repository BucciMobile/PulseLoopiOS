//
//  OuraStore.swift
//  PulseLoopIOS - Oura Ring Extension
//
//  Apply layer: persists raw events, decoded samples, and the sync cursor.
//  Mirrors open_oura's oura-store crate responsibilities, adapted to a
//  lightweight Core Data / SQLite-backed store for iOS.
//

import Foundation

final class OuraStore {

    private let cursorKey = "oura.sync.cursor"

    func lastSyncCursor() -> UInt32 {
        UInt32(UserDefaults.standard.integer(forKey: cursorKey))
    }

    func updateSyncCursor(_ cursor: UInt32) {
        UserDefaults.standard.set(Int(cursor), forKey: cursorKey)
    }

    /// Persists the raw, undecoded event so that future algorithm updates
    /// can redecode/recompute metrics without a new BLE sync.
    func persistRawEvent(_ event: OuraRawEvent) {
        // TODO: write to Core Data / SQLite raw_events table
        // (type, timestamp, payload blob)
    }

    /// Persists a typed, decoded sample (heart rate, HRV, sleep stage, etc.)
    func persistSample(_ sample: OuraDecodedSample) {
        // TODO: write to Core Data / SQLite typed sample tables,
        // matching the existing PulseLoopIOS data model for other rings
        // so the rest of the app (dashboards, coach, briefs) can consume
        // Oura data through the same interface.
    }
}
