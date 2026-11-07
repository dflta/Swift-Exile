import SwiftExileCore
import SwiftUI

/// Native price check. Content comes from Exiled Exchange 2's own logic via the headless engine.
struct PriceCheckView: View {
    let model: PriceCheckModel
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.check?.item.name ?? "Price check")
                    .font(.headline)
                    .foregroundStyle(rarityColor)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let item = model.check?.item {
                        if let category = item.category { Text(category) }
                        if let level = item.itemLevel { Text("ilvl \(level)") }
                        if let quality = item.quality, quality > 0 { Text("+\(quality)%") }
                        if item.corrupted { Text("Corrupted").foregroundStyle(.red) }
                        if item.unidentified { Text("Unidentified") }
                    } else if model.phase == .checking {
                        Text("Reading item…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let league = model.check?.league {
                Text(league)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
        .padding(14)
    }

    private var rarityColor: Color {
        switch model.check?.item.rarity {
        case "Unique": return Color(red: 0.69, green: 0.38, blue: 0.15)
        case "Rare": return Color(red: 1.0, green: 1.0, blue: 0.47)
        case "Magic": return Color(red: 0.53, green: 0.53, blue: 1.0)
        default: return .primary
        }
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
                if let ninja = model.check?.ninja { NinjaPriceRow(price: ninja) }
                if !model.stats.isEmpty { filters }
                searchSection
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Filters").font(.subheadline.weight(.semibold))
            ForEach(model.stats.filter { $0.hidden == nil }) { stat in
                StatFilterRow(stat: stat, model: model)
            }
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await model.search() }
                } label: {
                    Label(model.api == "bulk" ? "Search bulk exchange" : "Search trade", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.isSearching)
                if model.isSearching { ProgressView().controlSize(.small) }
                Spacer()
                if case .trade(let total, let inexact, _) = model.results {
                    Text("\(inexact ? "≈" : "")\(total) matched").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.searchError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            switch model.results {
            case .trade(_, _, let listings):
                TradeResultsList(listings: listings)
            case .bulk(let groups):
                BulkResultsList(groups: groups)
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: Rows

private struct NinjaPriceRow: View {
    let price: NinjaPrice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.secondary)
            Text("poe.ninja").foregroundStyle(.secondary)
            Spacer()
            Text(priceText).font(.title3.weight(.semibold).monospacedDigit())
            Text(CurrencyName.display(price.currency)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var priceText: String {
        price.min == price.max ? NumberText.short(price.min) : "\(NumberText.short(price.min))–\(NumberText.short(price.max))"
    }
}

private struct StatFilterRow: View {
    let stat: StatFilter
    let model: PriceCheckModel
    @State private var minimumText = ""

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { !stat.disabled }, set: { enabled in
                Task { await model.setEnabled(stat, enabled) }
            })) {
                Text(stat.display)
                    .font(.callout)
                    .foregroundStyle(stat.disabled ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 4)
            if let roll = stat.roll {
                TextField("min", text: $minimumText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospacedDigit())
                    .frame(width: 54)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { commitMinimum() }
                    .onAppear { minimumText = roll.min.map(NumberText.short) ?? "" }
                    .onChange(of: stat.roll?.min) { _, newValue in minimumText = newValue.map(NumberText.short) ?? "" }
                // The mod's possible roll range, like the bounds on upstream's filter slider.
                Text("\(NumberText.short(roll.boundsMin ?? roll.defaultMin))–\(NumberText.short(roll.boundsMax ?? roll.defaultMax))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 48, alignment: .leading)
            }
        }
    }

    private func commitMinimum() {
        let trimmed = minimumText.trimmingCharacters(in: .whitespaces)
        let value = trimmed.isEmpty ? nil : Double(trimmed.replacingOccurrences(of: ",", with: "."))
        Task { await model.setMinimum(stat, value) }
    }
}

private struct TradeResultsList: View {
    let listings: [TradeListing]

    var body: some View {
        if listings.isEmpty {
            Text("No listings found.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(listings) { listing in
                    HStack(spacing: 8) {
                        Text("\(NumberText.short(listing.price)) \(CurrencyName.display(listing.currency))")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .frame(width: 130, alignment: .leading)
                        if listing.listedTimes > 1 {
                            Text("×\(listing.listedTimes)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(listing.listed).font(.caption).foregroundStyle(.secondary)
                        StatusDot(status: listing.status)
                        Text(listing.account).font(.caption).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .background(listing.isMine ? Color.accentColor.opacity(0.15) : .clear)
                    Divider().opacity(0.4)
                }
            }
        }
    }
}

private struct BulkResultsList: View {
    let groups: [BulkGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups.filter { !$0.listings.isEmpty }) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pay with \(CurrencyName.display(group.have)) · \(group.total) offers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.listings.prefix(8)) { listing in
                        HStack(spacing: 8) {
                            Text("\(NumberText.short(listing.pricePerItem)) \(CurrencyName.display(group.have))")
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .frame(width: 130, alignment: .leading)
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

private struct StatusDot: View {
    let status: String
    var body: some View {
        Circle()
            .fill(status == "online" ? Color.green : (status == "afk" ? Color.orange : Color.gray))
            .frame(width: 7, height: 7)
            .help(status)
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
