import Foundation

/// Math behind the native roll slider: a stat's search range (min…max) drawn inside the range the
/// modifier can roll (bounds), with the item's own roll marked. Mirrors upstream's
/// `StatRollSlider.vue` and `percentRoll` (price-check/filters/util.ts).
public struct RollRange: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// No limits.
        case none
        /// Only a minimum: everything from `min` up to the top bound.
        case min
        /// Only a maximum.
        case max
        case range
    }

    public var lower: Double
    public var upper: Double
    public var roll: Double
    public var min: Double?
    public var max: Double?
    public var decimal: Bool

    public init?(roll: StatRoll) {
        // Negative ranges like -1(-5--1) can arrive in either order; the track always runs from the
        // smaller value to the bigger one.
        guard let first = roll.boundsMin, let second = roll.boundsMax, first != second else { return nil }
        self.init(lower: Swift.min(first, second), upper: Swift.max(first, second), roll: roll.value,
                  min: roll.min, max: roll.max, decimal: roll.decimal)
    }

    public init(lower: Double, upper: Double, roll: Double, min: Double?, max: Double?, decimal: Bool) {
        self.lower = lower
        self.upper = upper
        self.roll = roll
        self.min = min
        self.max = max
        self.decimal = decimal
    }

    public var mode: Mode {
        switch (min, max) {
        case (nil, nil): return .none
        case (.some, nil): return .min
        case (nil, .some): return .max
        case (.some, .some): return .range
        }
    }

    /// Position of `value` on the track, 0…1.
    public func fraction(of value: Double) -> Double {
        Swift.min(1, Swift.max(0, (value - lower) / (upper - lower)))
    }

    /// The highlighted part of the track (what the search matches), as fractions.
    public var selection: ClosedRange<Double>? {
        switch mode {
        case .none: return nil
        case .min: return fraction(of: min!)...1
        case .max: return 0...fraction(of: max!)
        case .range:
            // Drawn between the two ends even if they were entered the wrong way round.
            let ends = [fraction(of: min!), fraction(of: max!)]
            return ends.min()!...ends.max()!
        }
    }

    /// Value at a track position. Minimums round down and maximums up, like upstream's slider, so
    /// dragging to the item's own roll never excludes the item.
    public func value(at fraction: Double, roundingUp: Bool) -> Double {
        let raw = (upper - lower) * Swift.min(1, Swift.max(0, fraction)) + lower
        return Self.round(raw, decimal: decimal, up: roundingUp)
    }

    /// Upstream's `percentRoll(value, 0, floor|ceil, dp)`.
    public static func round(_ value: Double, decimal: Bool, up: Bool) -> Double {
        let scale = pow(10, Double(decimalPlaces(value, decimal: decimal)))
        let scaled = (value + .ulpOfOne) * scale
        return (up ? scaled.rounded(.up) : scaled.rounded(.down)) / scale
    }

    /// Upstream's `decimalPlaces(value, dp)`.
    public static func decimalPlaces(_ value: Double, decimal: Bool) -> Int {
        if !decimal || abs(value) >= 10 { return 0 }
        return abs(value) < 2.3 ? 2 : 1
    }

    /// Short text for a value: "41", "1.25".
    public static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
