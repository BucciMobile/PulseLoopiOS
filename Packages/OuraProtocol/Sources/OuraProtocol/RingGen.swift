import Foundation

// RingGen: per-generation capability + command-set selection. One transport handles all gens by
// swapping command sets, not code paths (per the architecture plan s5). The framing/auth/event-tag
// dictionary are generation-invariant (per OURA_PROTOCOL.md s7.2), so RingGen only drives:
//   - MTU clamp (203 vs 247)
//   - which characteristics to discover (gen5 extra notify chars, currently unused)
//   - the live-HR enable command set (verified on gen3, expected-same on gen4/5)
//   - the registered capability set surfaced to the app
//
// Platform-pure value type. Facts cited per OURA_PROTOCOL.md s7.

public enum OuraRingGen: String, Sendable, CaseIterable, Codable {
    case gen3
    case gen4
    case gen5

    /// Human-facing model name carried on PairedDevice.model (no schema change). The app recovers
    /// the generation via from(model:). Per architecture plan s5.
    public var displayName: String {
        switch self {
        case .gen3: return "Oura Ring 3"
        case .gen4: return "Oura Ring 4"
        case .gen5: return "Oura Ring 5"
        }
    }

    /// Negotiated ATT MTU for this generation. Per OURA_PROTOCOL.md s1.2.
    public var mtu: Int {
        switch self {
        case .gen3: return OuraGatt.mtuGen3
        case .gen4, .gen5: return OuraGatt.mtuGen45
        }
    }

    /// Max writable payload after the 3-byte ATT overhead. Per OURA_PROTOCOL.md s1.3.
    public var maxWritePayload: Int { mtu - OuraGatt.attOverhead }

    /// Whether this generation advertises the extra ...0004/5/6 characteristics. Only gen5 does, and
    /// v1 never writes to them (roles unconfirmed). Per OURA_PROTOCOL.md s1.2 / s7.2.
    public var hasExtraNotifyChars: Bool {
        switch self {
        case .gen3, .gen4: return false
        case .gen5: return true
        }
    }

    /// The numeric generation marker. The feature-mode master gate (setFeatureMode) requires
    /// generation > 2 (gen3+); gen <= 2 reject all feature-mode changes. All three supported gens
    /// satisfy this. Per OURA_PROTOCOL.md s7.1.
    public var generationNumber: Int {
        switch self {
        case .gen3: return 3
        case .gen4: return 4
        case .gen5: return 5
        }
    }

    /// True when this generation accepts feature-mode writes (live-HR / SpO2 enable). All supported
    /// generations are gen3+, so always true here; kept explicit for the s7.1 master-gate rule.
    public var supportsFeatureMode: Bool { generationNumber > 2 }

    /// Metrics this generation can register. Gen3+ all expose the same event-tag dictionary, so the
    /// capability set is currently uniform; kept per-gen so a future gen-specific gate is a one-line
    /// change. Per OURA_PROTOCOL.md s7.2.
    public var capabilities: Set<OuraMetric> {
        switch self {
        case .gen3, .gen4, .gen5:
            return [.hr, .hrv, .spo2, .skinTemp, .sleep]
        }
    }

    /// Best-effort generation guess from the advertised name (e.g. "Oura Ring 5").
    /// Returns nil if the name doesn't match any known pattern.
    public static func recognise(advertisedName: String) -> OuraRingGen? {
        let lower = advertisedName.lowercased()
        if lower.contains("ring 5") || lower.contains("ring5") { return .gen5 }
        if lower.contains("ring 4") || lower.contains("ring4") { return .gen4 }
        if lower.contains("ring 3") || lower.contains("ring3") || lower.contains("oura") { return .gen3 }
        return nil
    }

    /// Recover generation from a display-name string (inverse of displayName).
    public static func from(model: String) -> OuraRingGen? {
        let allCases: [OuraRingGen] = [.gen3, .gen4, .gen5]
        return allCases.first { $0.displayName == model }
    }
}

/// Metrics the ring can report. Used for capability declaration + feature-mode gating.
public enum OuraMetric: String, Sendable, CaseIterable, Codable, Hashable {
    case hr = "hr"
    case hrv = "hrv"
    case spo2 = "spo2"
    case skinTemp = "skin_temp"
    case sleep = "sleep"
}
