import SwiftExileCore
import SwiftUI

/// The map check (Exiled Exchange 2's MapCheck.vue): a waystone's (or tablet's, contract's)
/// properties and modifiers. Click a modifier to rate it: dangerous, warning, good, then seen. The
/// ratings live in Exiled Exchange 2's settings, one set per profile (I, II, III), so they match its
/// own map check.
struct MapCheckView: View {
    let map: MapCheck
    let store: OverlaySettingsStore?
    let close: () -> Void
    let moved: () -> Void

    private var settings: MapCheckSettings { store?.settings?.mapCheck ?? .empty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: ItemCheckController.maxHeight - 120)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if !map.item.icon.isEmpty { RemoteIcon(url: map.item.icon, size: 36) }
            VStack(alignment: .leading, spacing: 3) {
                Text(map.title ?? map.item.name)
                    .font(.headline)
                    .foregroundStyle(ItemColors.rarity(map.item.rarity))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if map.title != nil { Text(map.item.name).foregroundStyle(.primary.opacity(0.8)) }
                    if let tier = map.tier, !map.item.name.contains("\(tier)") { Text("Tier \(tier)") }
                    if let level = map.areaLevel { Text("Area level \(level)") }
                    if map.item.corrupted { Text("Corrupted").foregroundStyle(.red) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Picker("Profile", selection: Binding(
                get: { settings.profile },
                set: { profile in store?.update { $0.setMapProfile(profile) } })) {
                Text("I").tag(1)
                Text("II").tag(2)
                Text("III").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Map check profile: each keeps its own ratings")
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
        .padding(14)
        .dragsWindow(onEnded: moved)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !map.properties.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(Array(map.properties.enumerated()), id: \.offset) { _, property in
                        GridRow {
                            Text(property.label).foregroundStyle(.secondary)
                            Text(property.value).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
            }
            if map.stats.isEmpty && map.unknown.isEmpty {
                Text("No modifiers").foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(Array((map.stats + map.unknown).enumerated()), id: \.offset) { index, stat in
                    MapStatRow(stat: stat, decision: settings.decision(for: stat.matcher),
                               showNew: settings.showNewStats, isNew: index >= map.stats.count) { decision in
                        store?.update { $0.setMapDecision(decision, for: stat.matcher) }
                    }
                }
            }
            if !map.stats.isEmpty || !map.unknown.isEmpty {
                Text("Click a modifier to rate it: dangerous, warning, good, then seen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One modifier: a button that cycles its rating, and (with "mark new modifiers" on) an eye to mark
/// it seen without rating it.
private struct MapStatRow: View {
    let stat: MapCheck.Stat
    let decision: Character
    let showNew: Bool
    /// Not in Exiled Exchange 2's data (a newer modifier).
    var isNew = false
    let set: (Character) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                set(MapCheckSettings.next(after: decision))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon ?? "circle")
                        .opacity(icon == nil ? 0 : 1)
                        .frame(width: 16)
                    Text(stat.text)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isNew {
                        Image(systemName: "sparkle")
                            .foregroundStyle(.orange)
                            .help("A newer modifier Exiled Exchange 2 doesn't know yet; SwiftExile rates it by its text")
                    }
                }
                .font(.callout)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            if showNew {
                Button {
                    set(decision == "-" ? "s" : "-")
                } label: {
                    Image(systemName: decision == "-" ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .opacity(decision == "-" ? 1 : 0.35)
                        .frame(width: 24)
                }
                .buttonStyle(.plain)
                .help(decision == "-" ? "New modifier: mark it seen" : "Mark it new again")
                .opacity(decision == "-" || decision == "s" ? 1 : 0) // rated: nothing to mark
                .disabled(!(decision == "-" || decision == "s"))
            }
        }
    }

    private var icon: String? {
        switch decision {
        case "d": return "xmark.octagon.fill"
        case "w": return "exclamationmark.triangle.fill"
        case "g": return "checkmark.circle.fill"
        default: return nil
        }
    }

    private var background: Color {
        switch decision {
        case "d": return Color(red: 0.72, green: 0.11, blue: 0.11)
        case "w": return Color(red: 0.92, green: 0.35, blue: 0.05)
        case "g": return Color(red: 0.08, green: 0.5, blue: 0.24)
        default: return Color.white.opacity(0.06)
        }
    }

    private var help: String {
        switch decision {
        case "d": return "Dangerous. Click: warning"
        case "w": return "Warning. Click: good"
        case "g": return "Good. Click: seen (no rating)"
        default: return "Click to mark it dangerous"
        }
    }
}
