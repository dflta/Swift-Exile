import SwiftExileCore
import SwiftUI

/// Upstream's item editor (ItemEditorV2.vue), inline in the price check: try runes or soul cores
/// in the item's sockets, or a catalyst's quality on rings, amulets, and jewels. The filters are
/// rebuilt for the edited item, so you can price it as it would be.
struct ItemEditorSection: View {
    let editor: ItemEditorState
    let model: PriceCheckModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    summaryIcon
                    Text(summary).font(.callout)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(editor.type == "catalyst" ? "Try a catalyst's quality on this item" : "Try runes or other augments in this item's sockets")
            if expanded {
                if editor.type == "catalyst" {
                    CatalystEditor(editor: editor, model: model)
                } else {
                    AugmentEditor(editor: editor, model: model)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }

    @ViewBuilder
    private var summaryIcon: some View {
        if editor.type == "catalyst" {
            if let selected = editor.catalysts?.first(where: { $0.refName == editor.selected }), (editor.quality ?? 0) > 0 {
                EditorIcon(url: selected.icon, size: 22)
            } else {
                Image(systemName: "questionmark.circle").font(.title3).foregroundStyle(.secondary)
            }
        } else if let first = editor.sockets?.compactMap({ $0 }).first {
            EditorIcon(url: first.icon, size: 22)
        } else {
            Image(systemName: "circle.dashed").font(.title3).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        if editor.type == "catalyst" {
            guard let selected = editor.catalysts?.first(where: { $0.refName == editor.selected }),
                  let quality = editor.quality, quality > 0
            else { return "Catalyst: none" }
            return "\(selected.name) · \(quality)% quality"
        }
        let sockets = editor.sockets ?? []
        let filled = sockets.compactMap { $0 }
        if filled.isEmpty { return sockets.count == 1 ? "1 empty socket" : "\(sockets.count) empty sockets" }
        let names = filled.map(\.name)
        let empty = sockets.count - filled.count
        return names.joined(separator: ", ") + (empty > 0 ? " · \(empty) empty" : "")
    }
}

// MARK: Augments

private struct AugmentEditor: View {
    let editor: ItemEditorState
    let model: PriceCheckModel
    @State private var activeSocket = 0
    @State private var tab = "Rune"
    @State private var group = "Greater"

    private var tabs: [EditorTab] { editor.tabs ?? [] }
    private var tabNames: [String] { tabs.map(\.tab).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    private var groups: [EditorTab] { tabs.filter { $0.tab == tab } }
    private var entries: [EditorEntry] {
        (groups.first { $0.group == group } ?? groups.first)?.items ?? []
    }

    var body: some View {
        let sockets = editor.sockets ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Sockets").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(sockets.enumerated()), id: \.offset) { index, entry in
                    SocketButton(entry: entry, active: index == activeSocket) {
                        activeSocket = index
                    }
                    .contextMenu {
                        if let entry, entry.bound != true {
                            Button("Empty this socket") { Task { await model.setAugment(socket: index, nil) } }
                        }
                    }
                }
                Spacer()
            }
            if tabNames.count > 1 {
                Picker("Type", selection: $tab) {
                    ForEach(tabNames, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: tab) { _, _ in
                    if !groups.contains(where: { $0.group == group }) { group = groups.first?.group ?? "" }
                }
            }
            if groups.count > 1 {
                Picker("Grade", selection: $group) {
                    ForEach(groups) { Text($0.group).tag($0.group) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            EditorRow(entry: entry, selected: sockets.indices.contains(activeSocket) && sockets[activeSocket]?.refName == entry.refName) {
                                Task { await model.setAugment(socket: activeSocket, entry.refName) }
                            }
                            .id(entry.refName)
                        }
                    }
                }
                .frame(height: min(220, CGFloat(max(entries.count, 1)) * 44))
                .onAppear { reveal(proxy) }
                .onChange(of: activeSocket) { _, _ in reveal(proxy) }
            }
            Text("Pick a socket, then an augment to put in it. Right-click a socket to empty it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear {
            activeSocket = sockets.firstIndex { $0 == nil } ?? sockets.firstIndex { $0?.bound != true } ?? 0
            if !tabNames.contains(tab) { tab = tabNames.first ?? "" }
            if !groups.contains(where: { $0.group == group }) { group = groups.first?.group ?? "" }
        }
    }

    /// Shows the active socket's augment: switches to its tab and grade and scrolls to it.
    private func reveal(_ proxy: ScrollViewProxy) {
        let sockets = editor.sockets ?? []
        guard sockets.indices.contains(activeSocket), let current = sockets[activeSocket],
              let home = tabs.first(where: { $0.items.contains { $0.refName == current.refName } })
        else { return }
        tab = home.tab
        group = home.group
        // After the list switches to that tab.
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(current.refName, anchor: .center) }
        }
    }
}

private struct SocketButton: View {
    let entry: EditorEntry?
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.black.opacity(0.35))
                if let entry {
                    EditorIcon(url: entry.icon, size: 26)
                } else {
                    Circle().strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .padding(5)
                }
            }
            .frame(width: 34, height: 34)
            .overlay(Circle().strokeBorder(active ? Color.accentColor : .white.opacity(0.12), lineWidth: active ? 2 : 1))
            .opacity(entry?.bound == true ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(entry?.bound == true)
        .help(entry.map { "\($0.name)\n\($0.text)" + ($0.bound == true ? "\n(can't be changed)" : "") } ?? "Empty socket")
    }
}

// MARK: Catalysts

private struct CatalystEditor: View {
    let editor: ItemEditorState
    let model: PriceCheckModel
    @State private var amount = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Quality", selection: $amount) {
                    ForEach(editor.amounts ?? [0, 20], id: \.self) { Text("\($0)%").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                if let price = editor.price, editor.selected != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.right").font(.caption2)
                        Text(price.min == price.max ? NumberText.short(price.min) : "\(NumberText.short(price.min))–\(NumberText.short(price.max))")
                            .font(.callout.weight(.semibold).monospacedDigit())
                        EditorIcon(url: price.currencyIcon ?? "", size: 16)
                    }
                    .foregroundStyle(.secondary)
                    .help("poe.ninja cost of the catalysts for this quality")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(editor.catalysts ?? []) { entry in
                        EditorRow(entry: entry, selected: entry.refName == editor.selected && (editor.quality ?? 0) > 0) {
                            Task { await model.setCatalyst(entry.refName, quality: amount) }
                        }
                    }
                }
            }
            .frame(height: min(220, CGFloat(max(editor.catalysts?.count ?? 1, 1)) * 44))
        }
        .onAppear {
            if let quality = editor.quality, quality > 0, editor.selected != nil { amount = quality }
        }
        .onChange(of: amount) { _, newAmount in
            if let selected = editor.selected { Task { await model.setCatalyst(selected, quality: newAmount) } }
        }
    }
}

// MARK: Shared

private struct EditorRow: View {
    let entry: EditorEntry
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                EditorIcon(url: entry.icon, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.caption).foregroundStyle(.secondary)
                    Text(entry.text).font(.callout).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EditorIcon: View {
    let url: String
    let size: CGFloat

    var body: some View {
        if url.isEmpty {
            // An augment Exiled Exchange 2's data doesn't know.
            Image(systemName: "questionmark.circle")
                .font(.system(size: size * 0.7))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        } else {
            AsyncImage(url: URL(string: url)) { image in
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } placeholder: {
                Color.clear
            }
            .frame(width: size, height: size)
        }
    }
}
