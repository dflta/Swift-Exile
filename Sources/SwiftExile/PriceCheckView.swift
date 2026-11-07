import AppKit
import Charts
import SwiftExileCore
import SwiftUI

/// Native price check. Content comes from Exiled Exchange 2's own logic via the headless engine.
struct PriceCheckView: View {
    let model: PriceCheckModel
    var onClose: () -> Void = {}
    /// The header was dragged to a new place.
    var onMoved: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        // Clicking empty space ends editing a field (AppKit keeps it focused otherwise).
                        Color.clear.contentShape(Rectangle()).onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
                    }
            }
            .frame(maxHeight: 760)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon = model.check?.item.icon {
                RemoteIcon(url: icon, size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.check?.item.name ?? "Price check")
                    .font(.headline)
                    .foregroundStyle(ItemColors.rarity(model.check?.item.rarity))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let item = model.check?.item {
                        // Only the category shortens when space runs out.
                        if let category = item.category { Text(category).truncationMode(.tail) }
                        Group {
                            if let level = item.itemLevel { Text("ilvl \(level)") }
                            if let quality = item.quality, quality > 0 { Text("+\(quality)%") }
                            if let stack = item.stackSize, stack > 1 { Text("×\(stack)") }
                            if item.corrupted { Text("Corrupted").foregroundStyle(.red) }
                            if item.unidentified { Text("Unidentified") }
                        }
                        .fixedSize()
                    } else if model.phase == .checking {
                        Text("Reading item…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let league = model.check?.league {
                LeagueMenu(current: league, leagues: model.check?.leagues ?? []) { id in
                    Task { await model.selectLeague(id) }
                }
            }
            Button {
                model.isPinned.toggle()
            } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.callout)
                    .rotationEffect(.degrees(model.isPinned ? 0 : 45))
                    .foregroundStyle(model.isPinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Pinned: stays open when you click elsewhere. Click to unpin" : "Pin: keep open when you click elsewhere")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
        .padding(14)
        .dragsWindow(onEnded: onMoved)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .checking:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .ready:
            VStack(alignment: .leading, spacing: 14) {
                if let ninja = model.ninja {
                    NinjaPriceRow(price: ninja) { model.open(ninja.url) }
                }
                if let filters = model.filters {
                    scopeRow(filters)
                    if !filters.itemFilters.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(filters.itemFilters) { ItemFilterChipView(chip: $0, model: model) }
                        }
                    }
                    if let editor = model.editor, editor.type != "none" {
                        ItemEditorSection(editor: editor, model: model)
                    }
                    if !filters.stats.isEmpty { StatFilterList(stats: filters.stats, model: model) }
                    searchSection(filters)
                }
            }
        }
    }

    /// Exact name vs. any item of the category, and the filter presets (Pseudo / Exact / Base item).
    @ViewBuilder
    private func scopeRow(_ filters: FilterState) -> some View {
        let showName = filters.searchName.relaxed != nil
        let showPresets = filters.presets.count > 1
        if showName || showPresets {
            HStack(spacing: 8) {
                if let relaxed = filters.searchName.relaxed {
                    Picker("Search", selection: Binding(
                        get: { filters.searchName.relaxedEnabled },
                        set: { value in Task { await model.setRelaxed(value) } })) {
                        Text(filters.searchName.exact).tag(false)
                        Text(relaxed).tag(true)
                    }
                    .help("Search this exact item, or any item of its category")
                }
                if showPresets {
                    Picker("Filters", selection: Binding(
                        get: { filters.presets.first(where: \.active)?.id ?? "" },
                        set: { id in Task { await model.selectPreset(id) } })) {
                        ForEach(filters.presets) { Text($0.label).tag($0.id) }
                    }
                    .help("Filter preset")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func searchSection(_ filters: FilterState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TradeOptionsRow(options: filters.trade, isBulk: filters.api == "bulk", model: model)
            Button {
                Task { await model.search() }
            } label: {
                HStack(spacing: 8) {
                    if model.isSearching {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(filters.api == "bulk" ? "Search bulk exchange" : "Search trade")
                }
            }
            .buttonStyle(ProminentWideButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(model.isSearching)
            HStack(spacing: 8) {
                if case .trade(let total, let inexact, _) = model.results {
                    Text("\(inexact ? "≈" : "")\(total) matched").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.openTradeSite() }
                } label: {
                    Label("Open on trade site", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Open this search on the trade site in your browser")
            }
            if let error = model.searchError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            switch model.results {
            case .trade(_, _, let listings):
                TradeResultsList(listings: listings) { account in
                    Task { await model.openTradeSite(account: account) }
                }
            case .bulk(let groups):
                BulkResultsList(groups: groups) { have in Task { await model.openTradeSite(have: have) } }
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: Price

private struct NinjaPriceRow: View {
    let price: NinjaPrice
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(Self.range(price.min, price.max)).font(.title2.weight(.semibold).monospacedDigit())
                        CurrencyIcon(url: price.currencyIcon, id: price.currency, size: 24)
                        if price.stack != nil {
                            Text("each").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let stack = price.stack {
                        HStack(spacing: 4) {
                            Text("×\(stack.count) =").font(.caption).foregroundStyle(.secondary)
                            Text(Self.range(stack.min, stack.max)).font(.callout.weight(.semibold).monospacedDigit())
                            CurrencyIcon(url: stack.currencyIcon, id: stack.currency, size: 16)
                        }
                        .help("Price of \(stack.count) items (the Stock amount)")
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    if let points = price.trend, points.compactMap({ $0 }).count >= 2 {
                        HStack(spacing: 6) {
                            Sparkline(points: points, color: trendColor)
                                .frame(width: 60, height: 18)
                            if let change = price.totalChange {
                                Label(changeText(change), systemImage: trendSymbol)
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(trendColor)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .help("Price change over the last 7 days")
                    }
                    Text(price.trend == nil ? "poe.ninja" : "poe.ninja · last 7 days")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(price.url == nil)
        .help(price.url == nil ? "poe.ninja price" : "Open on poe.ninja")
    }

    static func range(_ min: Double, _ max: Double) -> String {
        min == max ? NumberText.short(min) : "\(NumberText.short(min))–\(NumberText.short(max))"
    }

    private func changeText(_ change: Double) -> String {
        "\(change > 0 ? "+" : "")\(Int(change.rounded()))%"
    }

    private var trendColor: Color {
        switch price.forecast {
        case .up: return .green
        case .down: return .red
        default: return .secondary
        }
    }

    private var trendSymbol: String {
        switch price.forecast {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        default: return "arrow.right"
        }
    }
}

private struct Sparkline: View {
    let points: [Double?]
    let color: Color

    var body: some View {
        let data = points.enumerated().compactMap { index, value in value.map { (day: index, value: $0) } }
        Chart(data, id: \.day) { point in
            LineMark(x: .value("Day", point.day), y: .value("Change", point.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(1, points.count - 1))
    }
}

// MARK: Item filters

private struct ItemFilterChipView: View {
    let chip: ItemFilterChip
    let model: PriceCheckModel
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                Task { await model.setEnabled(chip, chip.disabled) }
            } label: {
                Text(chip.kind == .numeric && chip.value != nil ? "\(chip.label):" : chip.label)
                    .font(.caption.weight(chip.disabled ? .regular : .semibold))
                    .padding(.leading, 8)
                    .padding(.trailing, chip.kind == .numeric && chip.value != nil ? 3 : 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .help(chip.disabled ? "Not searched; click to include" : "Searched; click to ignore")
            if chip.kind == .numeric, let value = chip.value {
                if !chip.disabled {
                    StepButton(systemImage: "minus") { Task { await model.setValue(chip, value - 1) } }
                        .disabled(value <= 0)
                }
                // Minimum value; typing a new one also turns the filter on.
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: max(18, CGFloat(text.count) * 7 + 8))
                    .padding(.vertical, 1)
                    .background(.black.opacity(editing ? 0.35 : 0.18), in: RoundedRectangle(cornerRadius: 4))
                    .focused($editing)
                    .onSubmit { commit() }
                    .onChange(of: editing) { _, now in if !now { commit() } }
                    .onAppear { sync() }
                    .onChange(of: chip.value) { _, _ in sync() }
                    .help("Minimum \(chip.label.lowercased()); type a value and press Return")
                if !chip.disabled {
                    StepButton(systemImage: "plus") { Task { await model.setValue(chip, value + 1) } }
                        .padding(.trailing, chip.max == nil ? 5 : 0)
                } else if chip.max == nil {
                    Spacer().frame(width: 8)
                }
                if let max = chip.max {
                    Text("–\(RollRange.format(max))").font(.caption).padding(.trailing, 8)
                }
            }
        }
        .foregroundStyle(chip.disabled ? Color.secondary : Color.primary)
        .background(chip.disabled ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(Color.accentColor.opacity(0.35)), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(chip.disabled ? 0.06 : 0.18)))
    }

    private func sync() {
        text = chip.value.map(RollRange.format) ?? ""
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed) else { sync(); return }
        guard value != chip.value || chip.disabled else { return }
        Task { await model.setValue(chip, value) }
    }
}

/// Small − / + button inside a filter chip.
private struct StepButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Lays children out in rows, wrapping like text.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

// MARK: Stat filters

private struct StatFilterList: View {
    let stats: [StatFilter]
    let model: PriceCheckModel
    @State private var showHidden = false
    @State private var collapsed = false

    var body: some View {
        let visible = stats.filter { $0.hidden == nil }
        let hidden = stats.filter { $0.hidden != nil }
        let groups = StatGroup.split(visible)
        let selected = stats.filter { !$0.disabled }.count
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(selected > 0 ? "\(selected) of \(stats.count) stats searched" : "No stats searched")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                statRows(groups: groups, hidden: hidden)
            }
        }
    }

    @ViewBuilder
    private func statRows(groups: [(group: StatGroup, stats: [StatFilter])], hidden: [StatFilter]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(groups.enumerated()), id: \.element.group) { index, entry in
                if index > 0 { Divider().opacity(0.35) }
                ForEach(entry.stats) { StatFilterRow(stat: $0, model: model) }
            }
            if !hidden.isEmpty {
                Button {
                    showHidden.toggle()
                } label: {
                    Label(showHidden ? "Hide \(hidden.count) hidden filters" : "Show \(hidden.count) hidden filters",
                          systemImage: showHidden ? "eye.slash" : "eye")
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Filters Exiled Exchange 2 hides by default; they can still be searched")
                if showHidden {
                    ForEach(hidden) { StatFilterRow(stat: $0, model: model) }
                }
            }
        }
    }
}

/// Order of stat sections, like the in-game tooltip: properties, runes and enchants, implicits,
/// then pseudo totals and explicit mods.
private enum StatGroup: Int, Comparable {
    case property, augment, implicit, pseudo, explicit

    init(tag: String) {
        switch tag {
        case "property": self = .property
        case "rune", "added-rune", "enchant", "skill", "corrupted": self = .augment
        case "implicit": self = .implicit
        case "pseudo": self = .pseudo
        default: self = .explicit
        }
    }

    static func < (a: StatGroup, b: StatGroup) -> Bool { a.rawValue < b.rawValue }

    /// Stats split into sections (keeping their order within a section); empty sections dropped.
    static func split(_ stats: [StatFilter]) -> [(group: StatGroup, stats: [StatFilter])] {
        Dictionary(grouping: stats) { StatGroup(tag: $0.tag) }
            .sorted { $0.key < $1.key }
            .map { (group: $0.key, stats: $0.value) }
    }
}

private struct StatFilterRow: View {
    let stat: StatFilter
    let model: PriceCheckModel
    @State private var minimumText = ""
    @State private var maximumText = ""
    @FocusState private var focused: Field?

    private enum Field { case min, max }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle(isOn: Binding(get: { !stat.disabled }, set: { enabled in
                    Task { await model.setEnabled(stat, enabled) }
                })) {
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(stat.disabled ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 4)
                ForEach(stat.tiers, id: \.self) { TierBadge(tier: $0) }
                if stat.tag != "explicit" { TagBadge(tag: stat.tag, sources: stat.sources ?? 1) }
                if stat.roll != nil, range == nil {
                    rangeField("min", text: $minimumText, field: .min)
                    rangeField("max", text: $maximumText, field: .max)
                }
            }
            if let reason = stat.hidden {
                Label(reason, systemImage: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let roll = stat.roll, let range {
                HStack(spacing: 6) {
                    RollSlider(range: range, active: !stat.disabled, kind: roll.boundsKind) { min, max in
                        Task { await model.setRange(stat, min: min, max: max) }
                    }
                    rangeField("min", text: $minimumText, field: .min)
                    rangeField("max", text: $maximumText, field: .max)
                }
                .padding(.leading, 20)
            }
        }
        .onAppear { syncFieldsFromStat() }
        .onChange(of: stat.roll) { _, newValue in if let newValue { syncFields(newValue) } }
        .onChange(of: focused) { old, _ in if old != nil { commitFields() } }
    }

    private var range: RollRange? { stat.roll.flatMap(RollRange.init(roll:)) }

    /// The stat text with this item's roll in bold, like upstream's ItemModifierText.
    private var label: AttributedString {
        guard let roll = stat.roll, stat.text.contains("#") else { return AttributedString(stat.display) }
        var result = AttributedString()
        for (index, part) in stat.text.components(separatedBy: "#").enumerated() {
            if index > 0 {
                var value = AttributedString(RollRange.format(roll.value))
                value.font = .callout.weight(.bold)
                result += value
            }
            result += AttributedString(part)
        }
        return result
    }

    private func rangeField(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 46)
            .focused($focused, equals: field)
            .onSubmit { commitFields() }
            .contextMenu { Button("Clear") { text.wrappedValue = ""; commitFields() } }
    }

    private func syncFieldsFromStat() {
        if let roll = stat.roll { syncFields(roll) }
    }

    private func syncFields(_ roll: StatRoll) {
        minimumText = roll.min.map(RollRange.format) ?? ""
        maximumText = roll.max.map(RollRange.format) ?? ""
    }

    private func commitFields() {
        var min = Self.number(minimumText)
        var max = Self.number(maximumText)
        if let low = min, let high = max, low > high { (min, max) = (high, low) }
        guard min != stat.roll?.min || max != stat.roll?.max else { syncFieldsFromStat(); return }
        Task { await model.setRange(stat, min: min, max: max) }
    }

    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}

private struct TierBadge: View {
    let tier: StatTier

    var body: some View {
        Text("T\(tier.tier)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(border))
            .help(tier.kind == "not-tier-1" ? "Tier \(tier.tier) (not the best tier)" : "Modifier tier \(tier.tier)")
    }

    // Colours follow upstream's FilterModifierTiers.vue: gold for T1, silver for T2.
    private var background: Color {
        switch tier.kind {
        case "tier-1": return Color(red: 0.98, green: 0.80, blue: 0.30)
        case "tier-2": return Color(white: 0.82)
        default: return .clear
        }
    }

    private var foreground: Color {
        switch tier.kind {
        case "tier-1", "tier-2": return .black
        case "not-tier-1": return .orange
        default: return .secondary
        }
    }

    private var border: Color {
        switch tier.kind {
        case "not-tier-1": return .orange.opacity(0.6)
        case "tier-3-plus": return .secondary.opacity(0.6)
        default: return .clear
        }
    }
}

private struct TagBadge: View {
    let tag: String
    /// Modifiers combined into this filter, shown as "pseudo ×2" like upstream.
    var sources = 1

    var body: some View {
        Text(tag.replacingOccurrences(of: "-", with: " ") + (sources > 1 ? " ×\(sources)" : ""))
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .help(sources > 1 ? "Combines \(sources) modifiers" : "")
    }

    private var color: Color {
        switch tag {
        case "pseudo": return .mint
        case "implicit": return .blue
        case "crafted", "enchant": return .cyan
        case "fractured": return Color(red: 0.75, green: 0.65, blue: 0.45)
        case "desecrated": return .purple
        case "rune", "augment": return .teal
        default: return .secondary
        }
    }
}

// MARK: Trade options

private struct TradeOptionsRow: View {
    let options: TradeOptions
    let isBulk: Bool
    let model: PriceCheckModel

    var body: some View {
        HStack(spacing: 6) {
            menu(icon: Image(systemName: "person.crop.circle.badge.checkmark"),
                 current: TradeOptions.listingTypes.first { $0.id == options.listingType }?.label ?? options.listingType,
                 choices: TradeOptions.listingTypes.map { ($0.id as String?, $0.label) },
                 selected: options.listingType) { await model.setTradeOption("listingType", $0) }
            if !isBulk {
                menu(icon: Image(systemName: "calendar"),
                     current: TradeOptions.listedOptions.first { $0.id == options.listed }?.label ?? "Any time",
                     choices: TradeOptions.listedOptions,
                     selected: options.listed) { await model.setTradeOption("listed", $0) }
                menu(icon: currencyImage(options.currency),
                     current: TradeOptions.currencies.first { $0.id == options.currency }?.label ?? "Any currency",
                     choices: TradeOptions.currencies,
                     selected: options.currency,
                     itemIcon: currencyImage) { await model.setTradeOption("currency", $0) }
            }
        }
        .font(.caption)
    }

    /// The currency's icon from the trade site, or a symbol for "any".
    private func currencyImage(_ id: String?) -> Image {
        if let id, let image = model.menuIcons[id] { return Image(nsImage: image) }
        return Image(systemName: "dollarsign.circle")
    }

    /// A menu with native checkmarks (an inline picker), so item titles don't shift.
    private func menu(icon: Image, current: String, choices: [(id: String?, label: String)], selected: String?,
                      itemIcon: ((String?) -> Image)? = nil,
                      onSelect: @escaping (String?) async -> Void) -> some View {
        Menu {
            Picker("", selection: Binding(
                get: { selected ?? "" },
                set: { value in Task { await onSelect(value.isEmpty ? nil : value) } })) {
                ForEach(choices, id: \.label) { choice in
                    if let itemIcon {
                        Label { Text(choice.label) } icon: { itemIcon(choice.id) }.tag(choice.id ?? "")
                    } else {
                        Text(choice.label).tag(choice.id ?? "")
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label { Text(current) } icon: { icon }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

// MARK: Results

private struct TradeResultsList: View {
    let listings: [TradeListing]
    /// Opens a seller's listing on the trade site.
    let onOpen: (String) -> Void

    var body: some View {
        if listings.isEmpty {
            Text("No listings found.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(listings) { listing in
                    ListingRow(onOpen: { onOpen(listing.account) }) {
                        HStack(spacing: 4) {
                            Text(NumberText.short(listing.price))
                                .font(.callout.weight(.semibold).monospacedDigit())
                            CurrencyIcon(url: listing.currencyIcon, id: listing.currency, size: 18)
                            if let normalized = listing.normalizedPrice, let currency = listing.normalizedCurrency,
                               CurrencyName.display(currency) != CurrencyName.display(listing.currency) {
                                Text("≈\(normalized) \(CurrencyName.display(currency))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 150, alignment: .leading)
                        if listing.listedTimes > 1 {
                            Text("×\(listing.listedTimes)").font(.caption).foregroundStyle(.secondary)
                                .help("Listed \(listing.listedTimes) times at this price")
                        }
                        if let stack = listing.stackSize, stack > 1 {
                            Text("stack \(stack)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let level = listing.itemLevel {
                            Text("ilvl \(level)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if listing.instantBuyout {
                            Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow).help("Instant buyout")
                        }
                        Text(listing.listed).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        StatusDot(status: listing.status)
                        Text(listing.account).font(.caption).lineLimit(1).frame(maxWidth: 90, alignment: .leading)
                    }
                    .background(listing.isMine ? Color.accentColor.opacity(0.15) : .clear)
                    Divider().opacity(0.4)
                }
            }
        }
    }
}

private struct BulkResultsList: View {
    let groups: [BulkGroup]
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups.filter { !$0.listings.isEmpty }) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Pay with").foregroundStyle(.secondary)
                        CurrencyIcon(url: group.haveIcon, id: group.have, size: 16)
                        Text("\(CurrencyName.display(group.have)) · \(group.total) offers").foregroundStyle(.secondary)
                        Spacer()
                        Button { onOpen(group.have) } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.borderless)
                            .help("Open on the trade site")
                    }
                    .font(.caption.weight(.semibold))
                    ForEach(group.listings.prefix(8)) { listing in
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Text(NumberText.short(listing.pricePerItem))
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                CurrencyIcon(url: group.haveIcon, id: group.have, size: 16)
                            }
                            .frame(width: 110, alignment: .leading)
                            Text("\(NumberText.short(listing.exchangeAmount)) : \(NumberText.short(listing.itemAmount))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("stock \(listing.stock)").font(.caption).foregroundStyle(.secondary)
                            StatusDot(status: listing.status)
                        }
                    }
                }
            }
            if groups.allSatisfy({ $0.listings.isEmpty }) {
                Text("No offers found.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A clickable result row: highlights on hover, opens the seller's listing on the trade site.
private struct ListingRow<Content: View>: View {
    let onOpen: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) { content }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(hovered ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open this seller's listing on the trade site")
    }
}

private struct StatusDot: View {
    let status: String
    var body: some View {
        Circle()
            .fill(status == "online" ? Color.green : (status == "afk" ? Color.orange : Color.gray))
            .frame(width: 7, height: 7)
            .help(status)
    }
}

// MARK: Shared

/// Full-width, 44 pt primary button.
private struct ProminentWideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentWideLabel(configuration: configuration)
    }

    private struct ProminentWideLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.accentColor.opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.6)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// League chip in the header; picks the trade league for this session.
private struct LeagueMenu: View {
    let current: String
    let leagues: [LeagueInfo]
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(leagues) { league in
                Button {
                    onSelect(league.id)
                } label: {
                    if league.id == current { Label(league.text, systemImage: "checkmark") } else { Text(league.text) }
                }
            }
        } label: {
            Text(current)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .disabled(leagues.isEmpty)
        .help("Trade league")
    }
}

/// An image from the PoE CDN (item art, currency icons).
private struct RemoteIcon: View {
    let url: String
    let size: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: url)) { image in
            image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } placeholder: {
            Color.clear
        }
        .frame(width: size, height: size)
    }
}

/// Currency icon from the trade site's data, with the currency's name when there's no icon.
private struct CurrencyIcon: View {
    let url: String?
    let id: String
    let size: CGFloat

    var body: some View {
        if let url {
            RemoteIcon(url: url, size: size).help(CurrencyName.display(id))
        } else {
            Text(CurrencyName.display(id)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum ItemColors {
    static func rarity(_ rarity: String?) -> Color {
        switch rarity {
        case "Unique": return Color(red: 0.69, green: 0.38, blue: 0.15)
        case "Rare": return Color(red: 1.0, green: 1.0, blue: 0.47)
        case "Magic": return Color(red: 0.53, green: 0.53, blue: 1.0)
        default: return .primary
        }
    }
}

enum CurrencyName {
    static func display(_ id: String) -> String {
        switch id {
        case "div", "divine": return "Divine"
        case "exalted", "exa": return "Exalted"
        case "chaos": return "Chaos"
        case "vaal": return "Vaal"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

enum NumberText {
    static func short(_ value: Double) -> String {
        if value >= 100 || value == value.rounded() { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}
