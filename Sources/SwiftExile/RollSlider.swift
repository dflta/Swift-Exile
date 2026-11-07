import SwiftExileCore
import SwiftUI

/// Exiled Exchange 2's stat roll slider, natively: the track is the range the modifier can roll,
/// the highlighted part is what the search matches, and the tick is this item's roll. Drag either
/// end to change the minimum or maximum (committed when the drag ends).
struct RollSlider: View {
    let range: RollRange
    /// The stat filter is on (colours the selection).
    var active: Bool = true
    /// "unique" or "tier": where the bounds come from (help text only).
    var kind: String?
    /// Called with the new (min, max) when a drag ends.
    let onCommit: (Double?, Double?) -> Void

    private enum Handle { case min, max }
    @State private var dragging: (handle: Handle, value: Double)?

    /// Same height as the min/max fields next to it.
    private static let height: CGFloat = 22
    private static let handleWidth: CGFloat = 5

    /// The range including the drag in progress.
    private var shown: RollRange {
        var shown = range
        switch dragging?.handle {
        case .min: shown.min = dragging?.value
        case .max: shown.max = dragging?.value
        case nil: break
        }
        return shown
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let shown = self.shown
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.08))
                if let selection = shown.selection {
                    selectionFill(selection, mode: shown.mode, width: width)
                }
                boundLabels(shown)
                rollTick(at: shown.fraction(of: shown.roll), width: width)
                if let min = shown.min { handle(at: shown.fraction(of: min), width: width) }
                if let max = shown.max { handle(at: shown.fraction(of: max), width: width) }
                if let dragging {
                    valueBubble(dragging.value, at: shown.fraction(of: dragging.value), width: width)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(width: width))
        }
        .frame(height: Self.height)
        .help(helpText)
        .accessibilityElement()
        .accessibilityLabel("Roll range")
        .accessibilityValue(accessibilityText)
    }

    // MARK: Parts

    private func selectionFill(_ selection: ClosedRange<Double>, mode: RollRange.Mode, width: CGFloat) -> some View {
        let color = active ? Color.accentColor : Color.gray
        let start = selection.lowerBound * width
        let length = max(Self.handleWidth * 2, (selection.upperBound - selection.lowerBound) * width)
        // One-sided limits fade out towards the open end, like upstream's slider.
        let fill: AnyShapeStyle = switch mode {
        case .min: AnyShapeStyle(LinearGradient(colors: [color.opacity(0.85), color.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
        case .max: AnyShapeStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
        default: AnyShapeStyle(color.opacity(0.85))
        }
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fill)
            .frame(width: min(length, width - start), height: Self.height)
            .offset(x: min(start, width - length))
    }

    private func boundLabels(_ shown: RollRange) -> some View {
        // A bound is "inclusive" when the search reaches it (bright text).
        let lowerIncluded = shown.mode == .max || (shown.min.map { $0 <= shown.lower } ?? false)
        let upperIncluded = shown.mode == .min || (shown.max.map { $0 >= shown.upper } ?? false)
        // Hide a bound's number when a handle or the roll mark sits on top of it.
        let marks = [shown.roll, shown.min, shown.max].compactMap { $0 }.map(shown.fraction(of:))
        let lowerCovered = marks.contains { $0 < 0.12 }
        let upperCovered = marks.contains { $0 > 0.88 }
        return HStack {
            Text(RollRange.format(shown.lower)).opacity(lowerCovered ? 0 : (lowerIncluded ? 0.95 : 0.45))
            Spacer()
            Text(RollRange.format(shown.upper)).opacity(upperCovered ? 0 : (upperIncluded ? 0.95 : 0.45))
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .allowsHitTesting(false)
    }

    private func rollTick(at fraction: Double, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.yellow)
            .frame(width: 2, height: Self.height)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .offset(x: Swift.min(Swift.max(0, fraction * width - 1), width - 2))
            .allowsHitTesting(false)
    }

    private func handle(at fraction: Double, width: CGFloat) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: Self.handleWidth, height: Self.height - 2)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
            .offset(x: Swift.min(Swift.max(0, fraction * width - Self.handleWidth / 2), width - Self.handleWidth))
            .allowsHitTesting(false)
    }

    private func valueBubble(_ value: Double, at fraction: Double, width: CGFloat) -> some View {
        Text(RollRange.format(value))
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.black.opacity(0.8), in: Capsule())
            .fixedSize()
            .frame(width: 44)
            .offset(x: Swift.min(Swift.max(-6, fraction * width - 22), width - 38), y: -Self.height)
            .allowsHitTesting(false)
    }

    // MARK: Dragging

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard width > 0 else { return }
                let fraction = gesture.location.x / width
                let handle = dragging?.handle ?? nearestHandle(to: gesture.startLocation.x / width)
                var value = range.value(at: fraction, roundingUp: handle == .max)
                // The ends can meet but not cross (min above max would match nothing).
                switch handle {
                case .min: if let max = range.max { value = Swift.min(value, max) }
                case .max: if let min = range.min { value = Swift.max(value, min) }
                }
                dragging = (handle, value)
            }
            .onEnded { _ in
                guard let dragging else { return }
                self.dragging = nil
                switch dragging.handle {
                case .min: onCommit(dragging.value, range.max)
                case .max: onCommit(range.min, dragging.value)
                }
            }
    }

    /// The end the drag moves. Without a maximum, the minimum is the end people adjust (and the
    /// other way round), unless they grab the far end of the track.
    private func nearestHandle(to fraction: Double) -> Handle {
        switch (range.min, range.max) {
        case let (min?, max?):
            return abs(fraction - range.fraction(of: min)) <= abs(fraction - range.fraction(of: max)) ? .min : .max
        case (_?, nil):
            return fraction > 0.92 ? .max : .min
        case (nil, _?):
            return fraction < 0.08 ? .min : .max
        case (nil, nil):
            return fraction <= range.fraction(of: range.roll) ? .min : .max
        }
    }

    private var helpText: String {
        let source = kind == "tier" ? "Tier range" : "Possible rolls"
        return "\(source) \(RollRange.format(range.lower))–\(RollRange.format(range.upper)); this item rolled \(RollRange.format(range.roll)). Drag to change the search range."
    }

    private var accessibilityText: String {
        let min = range.min.map(RollRange.format) ?? "none"
        let max = range.max.map(RollRange.format) ?? "none"
        return "minimum \(min), maximum \(max), this item \(RollRange.format(range.roll))"
    }
}
