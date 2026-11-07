import SwiftExileCore
import SwiftUI

/// Settings ▸ Map Check (Exiled Exchange 2's settings-maps.vue): rate any map modifier ahead of time
/// for the current profile. Ratings are shared with the map check panel and Exiled Exchange 2's own.
struct MapCheckPage: View {
    let store: OverlaySettingsStore
    let actions: AppDelegate

    @State private var modifiers: [MapModifier] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var onlyRated = false

    private var settings: MapCheckSettings { store.settings?.mapCheck ?? .empty }

    /// Rated modifiers that aren't in the list (newer ones rated from a map, or renamed in a game
    /// update) come first, like upstream's "outdated" entries.
    private var outdated: [MapModifier] {
        let known = Set(modifiers.map(\.matcher))
        return settings.decisions.keys
            .filter { !known.contains($0) && isRated($0) }
            .sorted()
            .map { MapModifier(matcher: $0, tag: "outdated") }
    }

    private var shown: [MapModifier] {
        let words = search.lowercased().split(separator: " ")
        return (outdated + modifiers).filter { modifier in
            let text = modifier.matcher.lowercased()
            guard words.allSatisfy({ text.contains($0) }) else { return false }
            return !onlyRated || isRated(modifier.matcher)
        }
    }

    private func isRated(_ matcher: String) -> Bool {
        ["d", "w", "g"].contains(settings.decision(for: matcher))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search", text: $search, prompt: Text("Search modifiers"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Only rated", isOn: $onlyRated)
                Spacer()
                Picker("Profile", selection: Binding(
                    get: { settings.profile },
                    set: { profile in store.update { $0.setMapProfile(profile) } })) {
                    Text("I").tag(1)
                    Text("II").tag(2)
                    Text("III").tag(3)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Each profile keeps its own ratings")
            }
            .padding(12)
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { modifier in
                    MapModifierRow(modifier: modifier, decision: settings.decision(for: modifier.matcher)) { decision in
                        store.update { $0.setMapDecision(decision, for: modifier.matcher) }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Toggle("Mark modifiers I haven't rated", isOn: Binding(
                    get: { settings.showNewStats },
                    set: { value in store.update { $0.setMapShowNewStats(value) } }))
                    .help("The map check shows an eye on modifiers without a rating; click it to mark them seen")
                Spacer()
                Text("\(shown.count) of \(modifiers.count) modifiers")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(12)
        }
        .task {
            guard !loaded else { return }
            modifiers = await actions.mapModifiers()
            loaded = true
        }
    }
}

/// A modifier with its three rating buttons; clicking the active one clears it.
private struct MapModifierRow: View {
    let modifier: MapModifier
    let decision: Character
    let set: (Character) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(modifier.matcher.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tag = tagText {
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(modifier.tag == "outdated" ? .orange : .secondary)
                    .help(tagHelp)
            }
            rating("w", "exclamationmark.triangle.fill", Color(red: 0.92, green: 0.35, blue: 0.05), "Warning")
            rating("d", "xmark.octagon.fill", Color(red: 0.72, green: 0.11, blue: 0.11), "Dangerous")
            rating("g", "checkmark.circle.fill", Color(red: 0.08, green: 0.5, blue: 0.24), "Good")
        }
        .padding(.vertical, 2)
    }

    private func rating(_ value: Character, _ symbol: String, _ color: Color, _ label: String) -> some View {
        let active = decision == value
        return Button {
            set(active ? "-" : value)
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(active ? Color.white : Color.secondary)
                .frame(width: 30, height: 22)
                .background(active ? color : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(active ? "\(label) (click to clear)" : label)
    }

    private var tagText: String? {
        switch modifier.tag {
        case "uber": return "Uber"
        case "heist": return "Heist"
        case "poe2db": return "New"
        case "outdated": return "Not in list"
        default: return nil
        }
    }

    private var tagHelp: String {
        switch modifier.tag {
        case "poe2db": return "In the current game (poe2db) but not in Exiled Exchange 2's data yet; SwiftExile matches it by its text"
        case "outdated": return "Rated, but not in Exiled Exchange 2's modifier list: a newer modifier rated from a map, or one renamed in a game update"
        default: return ""
        }
    }
}
