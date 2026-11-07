// Headless price-check engine.
//
// Runs Exiled Exchange 2's own parser, filter, trade, and price code (imported unchanged from
// upstream/) without any UI. SwiftExile loads it in a hidden WKWebView and draws the price check in
// SwiftUI. Every function returns a JSON string so Swift can decode it with Codable.
//
// It follows the same steps as upstream's CheckedItem.vue, FiltersBlock.vue, FilterName.vue,
// FilterModifierTiers.vue, OnlineFilter.vue, PriceTrend.vue, and PriceCheckWindow.vue.
import { toRaw } from "vue";
import { initConfig, AppConfig } from "@/web/Config";
import * as Data from "@/assets/data";
import { Host } from "@/web/background/IPC";
import { parseClipboard, ItemCategory, ItemRarity, type ParsedItem } from "@/parser";
import { __testExports as parserInternals } from "@/parser/Parser";
import { buildEditorItems } from "@/parser/augment-builder";
import { ModifierType as ModType, type StatCalculated } from "@/parser/modifiers";
import { createPresets } from "@/web/price-check/filters/create-presets";
import { createFilters } from "@/web/price-check/filters/create-item-filters";
import { calculatedStatToFilter } from "@/web/price-check/filters/create-stat-filters";
import { ModifierType } from "@/parser/modifiers";
import {
  FilterTag,
  type FilterPreset,
  type ItemFilters,
  type StatFilter,
} from "@/web/price-check/filters/interfaces";
import { apiToSatisfySearch, getTradeEndpoint } from "@/web/price-check/trade/common";
import {
  CATEGORY_TO_TRADE_ID,
  createTradeRequest,
} from "@/web/price-check/trade/pathofexile-trade";
import { createTradeRequest as createBulkRequest } from "@/web/price-check/trade/pathofexile-bulk";
import { useTradeApi } from "@/web/price-check/trade/trade-api";
import { useBulkApi } from "@/web/price-check/trade/bulk-api";
import { useLeagues } from "@/web/background/Leagues";
import { usePoeninja } from "@/web/background/Prices";
import { getDetailsId } from "@/web/price-check/trends/getDetailsId";
import {
  AUGMENT_DATA_BY_AUGMENT,
  AUGMENT_DATA_BY_TRADE_ID,
  CATALYST_TO_TAG,
  CATALYST_TYPES,
  GROUPED_AUGMENTS,
  ITEM_BY_REF,
  type AugmentLineData,
  type BaseType,
} from "@/assets/data";
import augmentSupplement from "./augment-supplement.json";
import mapModsSupplement from "./map-mods-supplement.json";
import { applyCatalyst, getItemEditorType } from "@/web/price-check/item-editor/item-editor";
import { getCategoryGroups, useAugment } from "@/web/price-check/item-editor/augment";
import { ARMOUR } from "@/parser/meta";
import { prepareMapStats } from "@/web/map-check/prepare-map-stats";
import { itemIsModifiable } from "@/parser/ParsedItem";
import {
  groupLinesByMod,
  isModInfoLine,
  parseModInfoLine,
  parseModType,
} from "@/parser/advanced-mod-desc";
import { ARMOUR, ItemEditorType, WEAPON } from "@/parser/meta";
import { itemIsModifiable, type EditorItem } from "@/parser/ParsedItem";

interface PriceCheckWidgetConfig {
  collapseListings: "app" | "api";
  activateStockFilter: boolean;
  searchStatRange: number;
  defaultAllSelected: boolean;
  smartInitialSearch: boolean;
  lockedInitialSearch: boolean;
  alwaysShowTier: boolean;
}

interface State {
  item: ParsedItem;
  presets: { active: string; presets: FilterPreset[] };
  api: "trade" | "bulk";
}

let state: State | null = null;
let tradeApi: ReturnType<typeof useTradeApi> | null = null;
let bulkApi: ReturnType<typeof useBulkApi> | null = null;
/** Trade site currency id → icon URL, from /api/trade2/data/static. */
let currencyIcons: Record<string, string> = {};
/** Upstream's UI strings (app_i18n.json), for hidden-filter reasons. */
let strings: Record<string, unknown> = {};

const json = (value: unknown) => JSON.stringify(value);
// Used when the saved config has no price-check widget (upstream's defaults live in
// PriceCheckWindow.vue, which the engine doesn't load).
const WIDGET_DEFAULTS: PriceCheckWidgetConfig = {
  collapseListings: "api",
  activateStockFilter: false,
  searchStatRange: 10,
  defaultAllSelected: false,
  smartInitialSearch: true,
  lockedInitialSearch: true,
  alwaysShowTier: false,
};
const widget = () => ({
  ...WIDGET_DEFAULTS,
  ...(AppConfig("price-check") as unknown as Partial<PriceCheckWidgetConfig> | undefined),
});
const activePreset = (s: State) => s.presets.presets.find((p) => p.id === s.presets.active)!;

// Item-level filters, in FiltersBlock.vue order, with its English labels (app_i18n.json).
const NUMERIC_FILTERS: Array<[path: string, label: string]> = [
  ["socketNumber", "Sockets"],
  ["linkedSockets", "Links"],
  ["mapTier", "Map Tier"],
  ["awardedAscendancyPoints", "Points"],
  ["areaLevel", "Area Level"],
  ["heistWingsRevealed", "Wings Revealed"],
  ["sentinelCharge", "Charge"],
  ["itemLevel", "Item Level"],
  ["requires.level", "Req. Level"],
  ["stackSize", "Stock"],
  ["whiteSockets", "White"],
  ["augmentSockets", "Sockets"],
  ["gemLevel", "Level"],
  ["quality", "Quality"],
  ["unidentifiedTier", "Unidentified"],
];
const LOGICAL_FILTERS: Array<[path: string, label: (item: ParsedItem) => string]> = [
  ["unidentified", () => "Unidentified"],
  ["veiled", () => "Veiled"],
  ["foil", () => "Foil Unique"],
  ["mirrored", (item) => (item.isMirrored ? "Mirrored" : "Not Mirrored")],
  ["sanctified", (item) => ((item as { isSanctified?: boolean }).isSanctified ? "Sanctified" : "Not Sanctified")],
];
/** SwiftExile's extra preset: every modifier as its own filter (e.g. cold resistance on its own
 *  instead of only inside the pseudo resistance totals). */
const EACH_MOD_PRESET = "swiftexile.preset_each_mod";
const PRESET_LABELS: Record<string, string> = {
  "filters.preset_exact": "Exact",
  "filters.preset_pseudo": "Pseudo",
  "filters.preset_base_item": "Base item",
  [EACH_MOD_PRESET]: "Each mod",
};

/** Loads settings, item data, leagues, poe.ninja prices, and currency icons. Call once. */
export async function init(): Promise<string> {
  // The engine never talks to the overlay's event socket (it would steal item events).
  Host.sendEvent = () => {};
  await initConfig();
  await Data.init(AppConfig().language);
  applyAugmentSupplement();
  const leagues = useLeagues();
  await leagues.load();
  usePoeninja().queuePricesFetch();
  tradeApi = useTradeApi();
  bulkApi = useBulkApi();
  void loadCurrencyIcons();
  await loadI18n(AppConfig().language);
  return json({ language: AppConfig().language, league: leagues.selectedId.value ?? null });
}

/** Parses copied item text and builds the filters, like CheckedItem.vue. */
export async function check(clipboard: string, advancedCheck: boolean): Promise<string> {
  const parsed = parseClipboard(clipboard);
  if (parsed.isErr()) {
    state = null;
    return json({ error: String(parsed.error) });
  }
  const item = parsed.value;
  detectAugments(item);
  // Same rejection as PriceCheckWindow.vue's handleItemPaste.
  if (
    (item.category === ItemCategory.HeistContract || item.category === ItemCategory.Sentinel) &&
    item.rarity !== ItemRarity.Unique
  ) {
    state = null;
    return json({ error: "item.unknown" });
  }
  const w = widget();
  const leagues = useLeagues();
  state = buildState(item);
  editorCache = null;

  const searchByDefault =
    !((!advancedCheck && !w.smartInitialSearch) || (advancedCheck && !w.lockedInitialSearch)) &&
    Boolean(
      item.rarity === ItemRarity.Unique ||
        item.category === ItemCategory.HeistBlueprint ||
        item.category === ItemCategory.SanctumRelic ||
        item.category === ItemCategory.Charm ||
        !CATEGORY_TO_TRADE_ID.has(item.category!) ||
        item.isUnidentified ||
        item.isVeiled,
    );

  return json({
    item: describeItem(item),
    searchByDefault,
    league: leagues.selectedId.value ?? null,
    leagues: leagues.list.value.map((league) => ({ id: league.id, text: league.text ?? league.id })),
    ninja: await ninjaPrice(item, item.stackSize?.value ?? 1),
    editor: describeEditor(item),
    currencyIcons: coreCurrencyIcons(),
    ...filterState(state),
  });
}

// MARK: Augment data supplement

/** refName → effects SwiftExile adds (Engine/augment-supplement.json). */
const SUPPLEMENT = new Map<string, AugmentLineData[]>();

/** `base` with the supplement's effects added (upstream re-reads items from its data each time). */
function withSupplement(base: BaseType): BaseType {
  const extra = SUPPLEMENT.get(base.refName);
  if (!extra?.length) return base;
  const have = new Set((base.augment ?? []).map((line) => `${line.string}|${line.categories.join(",")}`));
  const add = extra.filter((line) => !have.has(`${line.string}|${line.categories.join(",")}`));
  return add.length ? { ...base, augment: [...(base.augment ?? []), ...add] } : base;
}

/** Adds effects missing from upstream's data to its augment lookups and editor groups. */
function applyAugmentSupplement() {
  for (const entry of augmentSupplement.augments) {
    const base = ITEM_BY_REF("ITEM", entry.refName)?.[0];
    if (!base) {
      console.warn(`augment supplement: ${entry.refName} is not in the item data`);
      continue;
    }
    const lines = entry.add as AugmentLineData[];
    SUPPLEMENT.set(entry.refName, lines);
    const merged = withSupplement(base);
    const added = (merged.augment ?? []).filter((line) => !(base.augment ?? []).includes(line));
    for (const line of added) {
      const data = {
        augment: base.name,
        refName: base.refName,
        baseStat: line.string,
        values: line.values,
        id: line.tradeId![0],
        categories: line.categories,
        icon: base.icon,
      };
      (AUGMENT_DATA_BY_AUGMENT[base.refName] ??= []).push(data);
      (AUGMENT_DATA_BY_TRADE_ID[line.tradeId![0]] ??= []).push(data);
    }
    // The editor's lists hold their own copies.
    const groups = GROUPED_AUGMENTS;
    const lists = [...Object.values(groups.Rune), ...Object.values(groups.SoulCore), groups.Idol, groups.Legacy, groups.Other];
    const listed = lists.flat().find((b) => b.refName === base.refName);
    if (listed) {
      listed.augment = merged.augment;
    } else if (base.refName.startsWith("Legacy")) {
      groups.Legacy.push(merged);
    } else if (base.tags?.includes("idol")) {
      groups.Idol.push(merged);
    } else {
      groups.Other.push(merged);
    }
  }
}

// MARK: Socketed augments

/** "#% increased effect of Socketed Runes" and similar: how much stronger the socketed lines are. */
const SOCKET_EFFECT_REFS = ["#% increased effect of Socketed Runes", "#% increased effect of Socketed Augment Items"];

function socketEffectMultiplier(item: ParsedItem): number {
  let percent = 0;
  for (const calc of item.statsByType) {
    if (!SOCKET_EFFECT_REFS.includes(calc.stat.ref)) continue;
    for (const source of calc.sources) percent += source.contributes?.value ?? source.stat.roll?.value ?? 0;
  }
  return 1 + percent / 100;
}

/** Non-empty subsets, biggest first (upstream's `combinations`, sorted like applyAugmentSockets). */
function subsets<T>(list: T[]): T[][] {
  if (list.length > 10) return list.map((x) => [x]);
  const out: T[][] = [];
  for (let mask = 1; mask < 1 << list.length; mask++) out.push(list.filter((_, i) => mask & (1 << i)));
  return out.sort((a, b) => b.length - a.length);
}

/**
 * Works out which augments sit in the item's sockets, like upstream's applyAugmentSockets, plus:
 * - lines boosted by "increased effect of Socketed Runes" (e.g. Runeseeker's Call, 200 % → ×3) are
 *   scaled back before matching, so 84 % crit is one Perfect Vision Rune, not three;
 * - lines that match no known augment show as "Unknown augment" instead of an empty socket.
 */
function detectAugments(item: ParsedItem) {
  const sockets = item.augmentSockets;
  if (!sockets) return;
  const augmentMods = item.newMods.filter((mod) => mod.info.type === ModType.Augment);
  if (!augmentMods.length) return; // nothing socketed: keep upstream's result
  const multiplier = socketEffectMultiplier(item);
  const scale = (value: number) => Math.round((value / multiplier) * 100) / 100;
  const calcs: StatCalculated[] = item.statsByType
    .filter((calc) => calc.type === ModType.Augment && !calc.stat.ref.startsWith("Bonded"))
    .map((calc) => ({
      ...calc,
      sources: calc.sources.map((source) => ({
        ...source,
        contributes: source.contributes ? { ...source.contributes, value: scale(source.contributes.value) } : undefined,
      })),
    }));

  let remaining = subsets(calcs);
  const used = new Set<StatCalculated>();
  const found: BaseType[][] = [];
  for (let i = 0; i < remaining.length; ) {
    const augments = parserInternals.determineAugments(augmentMods[0], remaining[i]);
    if (augments.length) {
      found.push(augments);
      for (const calc of remaining[i]) used.add(calc);
      remaining = remaining.filter((combo) => !combo.some((calc) => used.has(calc)));
      i = 0;
      continue;
    }
    i++;
  }

  const boost = (text: string) =>
    multiplier === 1 ? text : text.replace(/-?\d+(\.\d+)?/g, (n) => String(Math.round(Number(n) * multiplier * 100) / 100));
  const known: EditorItem[] = found
    .flatMap((group) => buildEditorItems(group.map(withSupplement), item.category ?? ItemCategory.Unknown, true))
    .map((augment) => ({ ...augment, displayString: boost(augment.displayString) }));
  const unknown: EditorItem[] = calcs
    .filter((calc) => !used.has(calc))
    .map((calc, index) => {
      const value = calc.sources[0]?.contributes?.value;
      const text = value === undefined ? calc.stat.ref : calc.stat.ref.replace("#", String(Math.round(value * multiplier * 100) / 100));
      return {
        existing: true,
        name: "Unknown augment",
        refName: `swiftexile.unknown.${index}`,
        icon: "",
        displayString: text,
        stats: [],
        baseItem: undefined as unknown as BaseType,
      };
    });

  const limit = itemIsModifiable(item) ? Math.max(sockets.current, sockets.normal) : sockets.current || sockets.normal;
  const augments: Array<EditorItem | null> = [...known, ...unknown];
  while (augments.length < limit) augments.push(null);
  sockets.augments = augments;
  sockets.empty = augments.filter((a) => a === null).length;
}

/** Presets for an item, like CheckedItem.vue's watcher; keeps trade options from `previous`. */
function buildState(item: ParsedItem, previous?: State): State {
  const w = widget();
  const prevTrade = previous ? activePreset(previous).filters.trade : undefined;
  const options = {
    league: useLeagues().selectedId.value!,
    collapseListings: w.collapseListings,
    activateStockFilter: w.activateStockFilter,
    searchStatRange: w.searchStatRange,
    useEn:
      (AppConfig().language === "cmn-Hant" && AppConfig().realm === "pc-ggg") ||
      AppConfig().preferredTradeSite === "www",
    currency: prevTrade?.currency,
    listingType: prevTrade?.listingType,
    defaultAllSelected: w.defaultAllSelected,
  };
  const presets = createPresets(item, options);
  const hasEachMod = presets.presets.some((p) => p.id === "filters.preset_exact" || p.id === "filters.preset_base_item");
  if (!hasEachMod && presets.presets.some((p) => p.id === "filters.preset_pseudo")) {
    const stats = eachModFilters(item, options.searchStatRange);
    if (stats.length) {
      presets.presets.push({ id: EACH_MOD_PRESET, filters: createFilters(item, { ...options, exact: false }), stats });
    }
  }
  if (previous && presets.presets.some((p) => p.id === previous.presets.active)) {
    presets.active = previous.presets.active;
  }
  const preset = presets.presets.find((p) => p.id === presets.active)!;
  if (prevTrade) preset.filters.trade.listed = prevTrade.listed;
  const api = apiToSatisfySearch(item, preset.stats, preset.filters);
  if (api === "bulk" && !prevTrade) preset.filters.trade.listingType = "online";
  return { item, presets, api };
}

/** poe.ninja price for `count` items (the Stock filter's amount). */
export async function ninjaFor(count: number): Promise<string> {
  if (!state) return json({ error: "no item" });
  return json({ ninja: await ninjaPrice(state.item, Math.max(1, Math.round(count))) });
}

// MARK: Item editor (ItemEditorV2.vue: runes in sockets, catalyst quality)

let editorCache: { category: string; groups: ReturnType<typeof getCategoryGroups> } | null = null;

function editorType(item: ParsedItem): ItemEditorType {
  // Upstream skips uniques (a TODO there); SwiftExile lets you try augments in a unique's sockets too.
  if (
    item.rarity === ItemRarity.Unique &&
    (item.augmentSockets?.augments.length ?? 0) > 0 &&
    item.category &&
    (WEAPON.has(item.category) || ARMOUR.has(item.category))
  ) {
    return ItemEditorType.Augment;
  }
  // FiltersBlock.vue's showItemEditor
  if (!itemIsModifiable(item)) {
    return (item.augmentSockets?.augments.length ?? 0) > 0 ? getItemEditorType(item) : ItemEditorType.None;
  }
  return getItemEditorType(item);
}

function augmentGroups(item: ParsedItem) {
  if (!editorCache || editorCache.category !== item.category) {
    editorCache = { category: item.category!, groups: getCategoryGroups(GROUPED_AUGMENTS, item.category!) };
  }
  return editorCache.groups;
}

function catalystTypes(item: ParsedItem): BaseType[] {
  return item.category === ItemCategory.Jewel ? CATALYST_TYPES.Refined : CATALYST_TYPES.Normal;
}

const assetURL = (path: string) => (path.startsWith("/") ? `${location.origin}${path}` : path);

function describeEditorItem(augment: EditorItem) {
  return {
    refName: augment.refName,
    name: augment.name,
    icon: assetURL(augment.icon),
    text: augment.displayString,
  };
}

/** What the item editor can change on this item, and what's selected. */
export function editor(): string {
  if (!state) return json({ error: "no item" });
  return json(describeEditor(state.item));
}

function describeEditor(item: ParsedItem) {
  const type = editorType(item);
  if (type === ItemEditorType.Augment && item.augmentSockets) {
    const groups = augmentGroups(item);
    const tabs: Array<{ tab: string; group: string; items: ReturnType<typeof describeEditorItem>[] }> = [];
    for (const [group, list] of Object.entries(groups.Rune)) tabs.push({ tab: "Rune", group, items: list.map(describeEditorItem) });
    for (const [group, list] of Object.entries(groups.SoulCore)) tabs.push({ tab: "Soul Core", group, items: list.map(describeEditorItem) });
    tabs.push({ tab: "Idol", group: "", items: groups.Idol.map(describeEditorItem) });
    tabs.push({ tab: "Legacy", group: "", items: groups.Legacy.map(describeEditorItem) });
    tabs.push({ tab: "Other", group: "", items: groups.Other.map(describeEditorItem) });
    return {
      type: "augment",
      sockets: item.augmentSockets.augments.map((augment) =>
        augment ? { ...describeEditorItem(augment), bound: Boolean(augment.socketBound) } : null,
      ),
      tabs: tabs.filter((t) => t.items.length),
    };
  }
  if (type === ItemEditorType.Catalyst) {
    const amounts = item.info.refName === "Breach Ring" ? [0, 20, 30, 40, 50, 60, 70] : item.category === ItemCategory.Jewel ? [0, 20] : [0, 20, 30, 40, 50];
    const selected = catalystTypes(item).find((c) => c.tags[1] === item.qualityType);
    return {
      type: "catalyst",
      catalysts: catalystTypes(item).map((c) => ({
        refName: c.refName,
        name: c.name,
        icon: assetURL(c.icon),
        text: (CATALYST_TO_TAG[c.tags[1]] ?? []).join(", "),
      })),
      amounts,
      selected: selected?.refName ?? null,
      quality: item.quality ?? 0,
      price: selected && item.quality ? catalystPrice(selected, item.quality) : null,
    };
  }
  return { type: "none" };
}

function catalystPrice(catalyst: BaseType, amount: number) {
  const ninja = usePoeninja();
  const entry = ninja.findPriceByQuery({ ns: "ITEM", name: catalyst.name });
  if (!entry) return null;
  const total = priced(entry.primaryValue * amount, false);
  return { min: total.min, max: total.max, currency: total.currency, currencyIcon: currencyIcons[coreCurrencyId(total.currency)] ?? null };
}

/** Puts an augment (rune, soul core, ...) in a socket, or empties it (null), then rebuilds the filters. */
export function setAugment(index: number, refName: string | null): string {
  if (!state || !state.item.augmentSockets) return json({ error: "no sockets" });
  const current = state.item.augmentSockets.augments[index];
  if (current?.socketBound) return json({ error: "This socket's augment can't be changed." });
  let augment: EditorItem | null = null;
  if (refName) {
    const groups = augmentGroups(state.item);
    const all = [
      ...Object.values(groups.Rune).flat(),
      ...Object.values(groups.SoulCore).flat(),
      ...groups.Idol,
      ...groups.Legacy,
      ...groups.Other,
    ];
    augment = all.find((a) => a.refName === refName) ?? null;
    if (!augment) return json({ error: "unknown augment" });
  }
  const multiplier = socketEffectMultiplier(state.item);
  if (augment && multiplier !== 1) {
    augment = {
      ...augment,
      displayString: augment.displayString.replace(/-?\d+(\.\d+)?/g, (n) => String(Math.round(Number(n) * multiplier * 100) / 100)),
    };
  }
  useAugment(state.item, augment as EditorItem, index);
  return rebuilt();
}

/** Applies a catalyst with the given quality (0 removes its effect), then rebuilds the filters. */
export function setCatalyst(refName: string, quality: number): string {
  if (!state) return json({ error: "no item" });
  const catalyst = catalystTypes(state.item).find((c) => c.refName === refName);
  if (!catalyst) return json({ error: "unknown catalyst" });
  applyCatalyst(state.item, catalyst, quality);
  return rebuilt();
}

function rebuilt() {
  state = buildState(state!.item, state!);
  return json({ ...filterState(state), editor: describeEditor(state.item) });
}

/** Changes one stat filter of the active preset (index from `check`). */
export function setStat(index: number, disabled: boolean, min: number | null, max: number | null): string {
  if (!state) return json({ error: "no item" });
  const stat = activePreset(state).stats[index];
  if (!stat) return json({ error: "no such stat" });
  stat.disabled = disabled;
  if (stat.roll) {
    stat.roll.min = min ?? "";
    stat.roll.max = max ?? "";
  }
  return json(updated(state));
}

/** Changes an item-level filter chip (`key` from `itemFilters`). */
export function setItemFilter(key: string, disabled: boolean, value: number | null, max: number | null): string {
  if (!state) return json({ error: "no item" });
  const filters = activePreset(state).filters;
  if (key === "corrupted") {
    if (filters.corrupted) filters.corrupted.value = !disabled;
  } else if (key === "searchRelaxed") {
    if (filters.searchRelaxed) filters.searchRelaxed.disabled = disabled;
  } else {
    const filter = getPath(filters, key) as { disabled: boolean; value?: number; max?: number } | undefined;
    if (!filter) return json({ error: "no such filter" });
    filter.disabled = disabled;
    if (value !== null && "value" in filter) filter.value = value;
    if ("value" in filter) filter.max = max ?? undefined;
  }
  return json(updated(state));
}

/** Changes a trade option: listingType, listed, or currency (null = any). */
export function setTradeOption(key: "listingType" | "listed" | "currency", value: string | null): string {
  if (!state) return json({ error: "no item" });
  const trade = activePreset(state).filters.trade as Record<string, unknown>;
  trade[key] = value ?? undefined;
  return json(updated(state));
}

/** Switches the trade league (and poe.ninja prices); check the item again afterwards. */
export function setLeague(id: string): string {
  const leagues = useLeagues();
  if (!leagues.list.value.some((league) => league.id === id)) return json({ error: "unknown league" });
  leagues.selectedId.value = id;
  return json({ league: id });
}

export function selectPreset(id: string): string {
  if (!state) return json({ error: "no item" });
  state.presets.active = id;
  return json(updated(state));
}

/** Link to the same search on the trade site (TradeLinks.vue / TradeBulk.vue). */
export function tradeLink(have: string | null, account: string | null = null): string {
  if (!state) return json({ error: "no item" });
  const { filters, stats } = activePreset(state);
  const base = `https://${getTradeEndpoint()}/trade2`;
  const league = encodeURIComponent(filters.trade.league);
  if (state.api === "bulk") {
    // Pay with divines by default (TradeBulk.vue), or exalts when pricing divines themselves.
    const payWith = have ?? (state.item.info.refName === "Divine Orb" ? "exalted" : "divine");
    const body = createBulkRequest(filters, state.item, [payWith]);
    return json({ url: `${base}/exchange/poe2/${league}?q=${encodeURIComponent(JSON.stringify({ exchange: body.query }))}` });
  }
  const request = createTradeRequest(filters, stats, state.item) as {
    query: { filters?: { trade_filters?: { filters?: Record<string, unknown> } } };
  };
  if (account) {
    // One seller's listing: the same search limited to their account.
    const query = request.query;
    query.filters ??= {};
    query.filters.trade_filters ??= {};
    query.filters.trade_filters.filters ??= {};
    query.filters.trade_filters.filters.account = { input: account };
  }
  // Encoded: account names contain "#", which would otherwise start the URL fragment.
  return json({ url: `${base}/search/poe2/${league}?q=${encodeURIComponent(JSON.stringify(request))}` });
}

/** Runs the trade or bulk search for the current item and filters. */
export async function search(): Promise<string> {
  if (!state || !tradeApi || !bulkApi) return json({ error: "no item" });
  const preset = activePreset(state);
  if (state.api === "trade") {
    await tradeApi.search(preset.filters, preset.stats, state.item);
    if (tradeApi.error.value) return json({ error: tradeApi.error.value });
    const result = tradeApi.searchResult.value;
    return json({
      api: "trade",
      total: result?.total ?? 0,
      inexact: result?.inexact ?? false,
      listings: tradeApi.groupedResults.value.map((r) => ({
        price: r.priceAmount,
        currency: r.priceCurrency,
        currencyIcon: currencyIcons[r.priceCurrency] ?? null,
        normalizedPrice: r.normalizedPrice ?? null,
        normalizedCurrency: r.normalizedPriceCurrency?.id ?? null,
        listed: r.relativeDate,
        account: r.accountName,
        status: r.accountStatus,
        listedTimes: r.listedTimes,
        instantBuyout: r.isInstantBuyout,
        itemLevel: r.itemLevel ?? null,
        stackSize: r.stackSize ?? null,
        corrupted: r.corrupted ?? false,
        isMine: r.isMine,
      })),
    });
  }
  await bulkApi.search(state.item, preset.filters);
  if (bulkApi.error.value) return json({ error: bulkApi.error.value });
  const result = bulkApi.result.value;
  const groups = result
    ? ([["xchgStable", "divine"], ["xchgExalted", "exalted"], ["xchgChaos", "chaos"]] as const).map(([key, fallback]) => {
        const listed = toRaw(result[key].listed.value);
        const have = listed?.haveTag ?? fallback;
        return {
          have,
          haveIcon: currencyIcons[have] ?? null,
          total: listed?.total ?? 0,
          listings: (listed?.listed ?? []).map((r) => ({
            exchangeAmount: r.exchangeAmount,
            itemAmount: r.itemAmount,
            stock: r.stock,
            listed: r.relativeDate,
            account: r.accountName,
            status: r.accountStatus,
            isMine: r.isMine,
          })),
        };
      })
    : [];
  return json({ api: "bulk", groups });
}

/** One filter per modifier line (implicits, explicits, ...), all off; for the Each mod preset. */
function eachModFilters(item: ParsedItem, searchStatRange: number): StatFilter[] {
  const types = [
    ModifierType.Implicit,
    ModifierType.Explicit,
    ModifierType.Fractured,
    ModifierType.Desecrated,
    ModifierType.Crafted,
    ModifierType.Enchant,
  ];
  return item.statsByType
    .filter((calc) => types.includes(calc.type))
    .map((calc) => ({ ...calculatedStatToFilter(calc, searchStatRange, item), disabled: true }));
}

// MARK: State description

function updated(s: State) {
  const preset = activePreset(s);
  s.api = apiToSatisfySearch(s.item, preset.stats, preset.filters);
  return filterState(s);
}

/** Everything the panel shows about the current filters; returned after every change. */
function filterState(s: State) {
  const preset = activePreset(s);
  const filters = preset.filters;
  return {
    api: s.api,
    presets: s.presets.presets.map((p) => ({
      id: p.id,
      label: PRESET_LABELS[p.id] ?? p.id,
      active: p.id === s.presets.active,
    })),
    stats: describeStats(preset.stats, s.item),
    itemFilters: describeItemFilters(filters, s.item),
    searchName: describeSearchName(filters, s.item),
    trade: {
      listingType: filters.trade.listingType,
      listed: filters.trade.listed ?? null,
      currency: filters.trade.currency ?? null,
    },
  };
}

function describeItem(item: ParsedItem) {
  return {
    name: item.info.name,
    refName: item.info.refName,
    namespace: item.info.namespace,
    icon: item.info.icon,
    rarity: item.rarity ?? null,
    category: item.category ?? null,
    itemLevel: item.itemLevel ?? null,
    quality: item.quality ?? null,
    gemLevel: item.gemLevel ?? null,
    stackSize: item.stackSize?.value ?? null,
    corrupted: item.isCorrupted,
    unidentified: item.isUnidentified,
  };
}

/** "Snakebite" vs "Any Gloves" (FilterName.vue). */
function describeSearchName(filters: ItemFilters, item: ParsedItem) {
  const exact = filters.searchExact;
  return {
    exact: exact.name ?? exact.baseType ?? item.info.name,
    relaxed: filters.searchRelaxed
      ? `Any ${filters.searchRelaxed.category ?? filters.searchRelaxed.baseType ?? "item"}`
      : null,
    relaxedEnabled: filters.searchRelaxed ? !filters.searchRelaxed.disabled : false,
  };
}

function describeItemFilters(filters: ItemFilters, item: ParsedItem) {
  const out: Array<{ key: string; kind: "numeric" | "logical"; label: string; value: number | null; max: number | null; disabled: boolean }> = [];
  if (filters.corrupted) {
    out.push({
      key: "corrupted",
      kind: "logical",
      label: filters.corrupted.value ? "Corrupted" : "Not Corrupted",
      value: null,
      max: null,
      disabled: !filters.corrupted.value,
    });
  }
  for (const [path, label] of NUMERIC_FILTERS) {
    const filter = getPath(filters, path) as { value: number; max?: number; disabled: boolean } | undefined;
    if (!filter) continue;
    out.push({ key: path, kind: "numeric", label, value: filter.value, max: filter.max ?? null, disabled: filter.disabled });
  }
  for (const [path, label] of LOGICAL_FILTERS) {
    const filter = getPath(filters, path) as { disabled: boolean } | undefined;
    if (!filter) continue;
    out.push({ key: path, kind: "logical", label: label(item), value: null, max: null, disabled: filter.disabled });
  }
  return out;
}

function describeStats(stats: StatFilter[], item: ParsedItem) {
  return stats.map((stat, index) => describeStat(stat, index, item));
}

function describeStat(stat: StatFilter, index: number, item: ParsedItem) {
  // Upstream gives slider bounds only to uniques; for other items use the modifier tiers' roll
  // ranges (from the advanced item text), so rares get the same visual slider.
  const uniqueBounds = stat.roll?.bounds;
  const bounds = uniqueBounds ?? tierBounds(stat);
  return {
    index,
    text: stat.text,
    display: stat.roll ? stat.text.replace("#", formatRoll(stat.roll.value, stat.roll.dp)) : stat.text,
    tag: stat.tag,
    hidden: stat.hidden ? (i18n(stat.hidden) ?? stat.hidden) : null,
    sources: stat.sources.length,
    disabled: stat.disabled,
    tiers: tiers(stat, item),
    roll: stat.roll
      ? {
          value: stat.roll.value,
          min: stat.roll.min === "" || stat.roll.min === undefined ? null : stat.roll.min,
          max: stat.roll.max === "" || stat.roll.max === undefined ? null : stat.roll.max,
          defaultMin: stat.roll.default.min,
          defaultMax: stat.roll.default.max,
          boundsMin: bounds?.min ?? null,
          boundsMax: bounds?.max ?? null,
          boundsKind: uniqueBounds ? "unique" : bounds ? "tier" : null,
          decimal: stat.roll.dp,
        }
      : null,
  };
}

/** Sum of the sources' tier ranges, e.g. 41(40-60) → 40…60. */
function tierBounds(stat: StatFilter): { min: number; max: number } | undefined {
  const roll = stat.roll;
  // Properties (DPS, armour, ...) are computed from several mods; a summed range would mislead.
  if (!roll || roll.isNegated || stat.tag === FilterTag.Property || !stat.sources.length) return undefined;
  let min = 0;
  let max = 0;
  for (const source of stat.sources) {
    if (!source.contributes) return undefined;
    min += Math.min(source.contributes.min, source.contributes.max);
    max += Math.max(source.contributes.min, source.contributes.max);
  }
  // Pseudo stats can scale or combine sources differently from the item's value; only trust the
  // range when the item's own roll falls inside it.
  // "reduced" stats can carry their tier ranges negated (-50…-46 for a 48% reduction).
  const inside = (value: number) => value >= min - 0.5 && value <= max + 0.5;
  if (!inside(roll.value) && inside(-roll.value)) [min, max] = [-max, -min];
  if (!inside(roll.value)) return undefined;
  const scale = roll.dp ? 100 : 1;
  min = Math.floor(Math.min(min, roll.value) * scale) / scale;
  max = Math.ceil(Math.max(max, roll.value) * scale) / scale;
  return max > min ? { min, max } : undefined;
}

/** Tier tags, like FilterModifierTiers.vue. */
function tiers(filter: StatFilter, item: ParsedItem) {
  if (item.category === ItemCategory.Map || item.category === ItemCategory.Tablet) return [];
  const out: Array<{ tier: number; kind: string }> = [];
  for (const source of filter.sources) {
    const tier = source.modifier.info.tier;
    if (!tier) continue;
    const tierable =
      (filter.tag === FilterTag.Explicit ||
        filter.tag === FilterTag.Desecrated ||
        filter.tag === FilterTag.Fractured ||
        filter.tag === FilterTag.Crafted ||
        filter.tag === FilterTag.Pseudo ||
        filter.tag === FilterTag.Property) &&
      item.category !== ItemCategory.Jewel &&
      item.category !== ItemCategory.ClusterJewel &&
      item.category !== ItemCategory.MemoryLine;
    if (tierable) {
      if (tier === 1) out.push({ tier, kind: "tier-1" });
      else if (tier === 2) out.push({ tier, kind: "tier-2" });
      else if (widget().alwaysShowTier) out.push({ tier, kind: "tier-3-plus" });
    } else if (tier >= 2) {
      out.push({ tier, kind: "not-tier-1" });
    }
  }
  return out.sort((a, b) => a.tier - b.tier);
}

function formatRoll(value: number, decimal: boolean) {
  return decimal ? value.toFixed(2).replace(/\.?0+$/, "") : String(Math.round(value));
}

function getPath(object: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((value, key) => (value as Record<string, unknown> | undefined)?.[key], object);
}

// MARK: Prices and icons

/** poe.ninja price and 7-day trend, like PriceTrend.vue. Waits up to 3 s for prices on first use. */
async function ninjaPrice(item: ParsedItem, count: number) {
  const ninja = usePoeninja();
  for (let waited = 0; ninja.initialLoading() && waited < 3000; waited += 100) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const detailsId = getDetailsId(item);
  const entry = detailsId && ninja.findPriceByQuery(detailsId);
  if (!entry) return null;
  const price = priced(entry.primaryValue, item.info.refName === "Divine Orb");
  const sparkline = (entry as { sparkline?: { data?: Array<number | null>; totalChange?: number } }).sparkline;
  const currencyId = coreCurrencyId(price.currency);
  const stack = count > 1 ? priced(entry.primaryValue * count, item.info.refName === "Divine Orb") : null;
  return {
    stack: stack
      ? { count, min: stack.min, max: stack.max, currency: stack.currency, currencyIcon: currencyIcons[coreCurrencyId(stack.currency)] ?? null }
      : null,
    min: price.min,
    max: price.max,
    currency: price.currency,
    currencyIcon: currencyIcons[currencyId] ?? null,
    url: (entry as { url?: string }).url ?? null,
    trend: sparkline?.data ? sparkline.data.map((point) => point ?? null) : null,
    totalChange: sparkline?.totalChange ?? null,
  };
}

// MARK: Price currency

type PriceCurrency = "auto" | "chaos" | "exalted" | "divine";
let priceCurrency: PriceCurrency = "auto";

/**
 * Which currency poe.ninja prices are shown in (a SwiftExile setting). "auto" is upstream's
 * behaviour: divines from about 1 divine up, the core currency (chaos or exalted) below.
 */
export async function setPriceCurrency(mode: PriceCurrency): Promise<string> {
  priceCurrency = mode;
  if (mode === "chaos" || mode === "exalted") {
    const ninja = usePoeninja();
    const widgetConfig = AppConfig("price-check") as unknown as { coreCurrency?: string } | undefined;
    if (widgetConfig && widgetConfig.coreCurrency !== mode) widgetConfig.coreCurrency = mode;
    // Upstream reloads the exchange rate for the new core currency.
    for (let waited = 0; waited < 3000 && (ninja.xchgRateCurrency.value?.id !== mode || !ninja.xchgRate.value); waited += 100) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  return json({ priceCurrency });
}

/** A poe.ninja value (in divines) in the chosen currency. */
function priced(divines: number, isDivineItem: boolean) {
  const ninja = usePoeninja();
  switch (priceCurrency) {
    case "divine":
      return { min: divines, max: divines, currency: "div" };
    case "chaos":
    case "exalted":
      return ninja.autoCurrency(divines, true);
    default:
      return ninja.autoCurrency(divines, isDivineItem);
  }
}

/** Icons for the trade currency choices. */
function coreCurrencyIcons() {
  return { divine: currencyIcons.divine ?? null, exalted: currencyIcons.exalted ?? null, chaos: currencyIcons.chaos ?? null };
}

/** poe.ninja core currency → trade site id (same first-letter mapping as CoreCurrencyImg.vue). */
function coreCurrencyId(currency: string) {
  switch (currency.toLowerCase().charAt(0)) {
    case "d": return "divine";
    case "c": return "chaos";
    case "e": return "exalted";
    case "a": return "annul";
    default: return currency;
  }
}

async function loadI18n(language: string) {
  for (const lang of [language, "en"]) {
    try {
      const response = await fetch(`${import.meta.env.BASE_URL}data/${lang}/app_i18n.json`);
      if (response.ok) {
        strings = (await response.json()) as Record<string, unknown>;
        return;
      }
    } catch {
      // try English
    }
  }
}

/** "filters.hide_ele_res" → "Filtering by exact Elemental Resistance unreasonably increases the price". */
function i18n(key: string): string | undefined {
  const value = getPath(strings, key);
  return typeof value === "string" ? value : undefined;
}

async function loadCurrencyIcons() {
  try {
    const response = await Host.proxy(`${poeHost()}/api/trade2/data/static`);
    const body = (await response.json()) as { result?: Array<{ entries?: Array<{ id: string; image?: string }> }> };
    const icons: Record<string, string> = {};
    for (const group of body.result ?? []) {
      for (const entry of group.entries ?? []) {
        if (entry.image) icons[entry.id] = entry.image.startsWith("http") ? entry.image : `https://web.poecdn.com${entry.image}`;
      }
    }
    currencyIcons = icons;
  } catch {
    // Icons are cosmetic; prices still show as text.
  }
}

function poeHost() {
  return getTradeEndpoint();
}

// MARK: Item check

/** Item info for the native item check (upstream's ItemInfo.vue and hotkeyable-actions.ts), plus the
 *  item's modifiers as the game describes them with advanced descriptions (name, tier, lines). */
export function itemInfo(clipboard: string): string {
  const parsed = parseClipboard(clipboard);
  if (parsed.isErr()) return unknownItemInfo(clipboard) ?? json({ error: String(parsed.error) });
  const item = parsed.value;
  const { category, rarity } = item;
  // Maps, contracts, and logbooks get Exiled Exchange 2's map check (WidgetItemCheck.vue isMapLike).
  const mapLike =
    (category === ItemCategory.Map && rarity !== ItemRarity.Unique) ||
    category === ItemCategory.HeistContract ||
    category === ItemCategory.HeistBlueprint ||
    category === ItemCategory.Invitation ||
    item.info.refName === "Expedition Logbook";
  if (mapLike) return json({ map: describeMap(item) });

  const language = AppConfig().language;
  const poedb = poe2dbPath(item);
  const name = JSON.stringify(item.info.name);
  const note = item.note ? JSON.stringify(item.note) : null;
  const both = (AppConfig<{ samePricedType?: string }>("item-check")?.samePricedType ?? "both") === "both";

  const as = item.weaponAS;
  const phys = as ? Math.round(as * (item.weaponPHYSICAL ?? 0)) : null;
  const elem = as ? Math.round(as * (item.weaponELEMENTAL ?? 0)) : null;

  return json({
    item: describeItem(item),
    title: itemTitle(item),
    links: {
      wiki: `https://www.poe2wiki.net/wiki/${encodeURIComponent(item.info.refName.replaceAll(" ", "_"))}`,
      poedb: poedb ? `https://poe2db.tw/${POEDB_LANGS[language] ?? "us"}/${poedb}` : null,
      craftOfExile:
        language === "en" && item.info.craftable && itemIsModifiable(item)
          ? `https://craftofexile.com/?game=poe2&eimport=${encodeURIComponent(item.rawText)}`
          : null,
    },
    stashSearch: name,
    samePricedSearch: note ? (both && note.length + name.length < 51 ? `${note}${name}` : note) : null,
    note: item.note ?? null,
    weapon: as
      ? {
          physicalDps: phys,
          elementalDps: elem,
          totalDps: (phys ?? 0) + (elem ?? 0),
          attacksPerSecond: as,
          critChance: item.weaponCRIT ?? null,
        }
      : null,
    defences: describeDefences(item),
    requires: item.requires ?? null,
    skills: grantedSkills(item.rawText),
    mods: describeModLines(item.rawText),
    mirrored: item.isMirrored ?? false,
    fractured: item.isFractured ?? false,
    sanctified: item.isSanctified ?? false,
  });
}

/** The map check (MapCheck.vue): the map's properties and its modifiers, each with the text
 *  Exiled Exchange 2 rates it by (`matcher`, as stored in its settings). */
function describeMap(item: ParsedItem) {
  const percent = (label: string, value: number | undefined) =>
    value ? { label, value: `${value > 0 ? "+" : ""}${value}%` } : null;
  const properties = [
    percent("Item rarity", item.mapItemRarity),
    percent("Pack size", item.mapPackSize),
    percent("Magic monsters", item.mapMagicMonsters),
    percent("Rare monsters", item.mapRareMonsters),
    percent("Monster rarity", item.mapMonsterRarity),
    percent("Monster effectiveness", item.mapEffectiveness),
    percent("Waystone drop chance", item.mapDropChance),
    percent("Gold", item.mapGold),
    item.mapRevives != null ? { label: "Revives", value: String(item.mapRevives) } : null,
  ].filter((p) => p != null);
  return {
    item: describeItem(item),
    title: itemTitle(item),
    tier: item.mapTier ?? null,
    areaLevel: item.areaLevel ?? null,
    properties,
    stats: prepareMapStats(item).map((stat) => ({
      matcher: stat.matcher,
      text: stat.roll != null ? stat.matcher.replace("#", String(stat.roll)) : stat.matcher,
      type: stat.type ?? null,
    })),
    // Not in Exiled Exchange 2's data (newer modifiers): still rateable by their text.
    unknown: item.unknownModifiers.map((mod) => ({ text: mod.text, matcher: unknownMatcher(mod.text) })),
  };
}

/** "Delirium Fog in Map spawns 20(12-26)% increased Mirror Shards" → "… spawns #% increased …". */
function unknownMatcher(text: string): string {
  return text
    .replace(/\(\s*-?[\d.]+\s*[-–—]+\s*-?[\d.]+\s*\)/g, "")
    .replace(/\+?(-?\d+(\.\d+)?)/g, "#")
    .trim();
}

/** Every map modifier to rate in the map check settings (settings-maps.vue findAllAreaMods), plus
 *  SwiftExile's supplement of newer ones from poe2db. */
export function mapModifiers(): string {
  const out: Array<{ matcher: string; tag: string | null }> = [];
  for (const stat of Data.STATS_ITERATOR("AreaMods")) {
    if (!stat.fromAreaMods && !stat.fromUberAreaMods && !stat.fromHeistAreaMods) continue;
    const tag =
      stat.fromHeistAreaMods && !stat.fromAreaMods
        ? "heist"
        : stat.fromUberAreaMods && !stat.fromAreaMods
          ? "uber"
          : null;
    for (const c of stat.matchers) out.push({ matcher: c.string, tag });
  }
  const known = new Set(out.map((entry) => entry.matcher));
  for (const matcher of mapModsSupplement.matchers) {
    if (!known.has(matcher)) out.push({ matcher, tag: "poe2db" });
  }
  out.sort((a, b) => a.matcher.localeCompare(b.matcher));
  return json(out);
}

/** "Level 11 Bone Blast" for each "Grants Skill: …" line. */
function grantedSkills(rawText: string): string[] {
  const prefix = Data.CLIENT_STRINGS.GRANTS_SKILL;
  return rawText
    .split(/\r?\n/)
    .filter((line) => line.startsWith(prefix))
    .map((line) => line.slice(prefix.length).trim());
}

/** Items the parser doesn't know (quest items, new item kinds): just the name and a wiki link. */
function unknownItemInfo(clipboard: string): string | null {
  const _$ = Data.CLIENT_STRINGS;
  const header = (parserInternals.itemTextToSections(clipboard) as string[][])[0] ?? [];
  const rarityIndex = header.findIndex((line) => line.startsWith(_$.RARITY));
  if (rarityIndex < 0) return null;
  const names = header.slice(rarityIndex + 1).filter((line) => line !== _$.CANNOT_USE_ITEM);
  if (!names.length) return null;
  const name = names[names.length - 1];
  const itemClass = header.find((line) => line.startsWith(_$.ITEM_CLASS))?.slice(_$.ITEM_CLASS.length) ?? null;
  return json({
    known: false,
    item: {
      name,
      refName: name,
      namespace: "",
      icon: "",
      rarity: header[rarityIndex].slice(_$.RARITY.length),
      category: itemClass,
      itemLevel: null,
      quality: null,
      gemLevel: null,
      stackSize: null,
      corrupted: false,
      unidentified: false,
    },
    title: names.length > 1 ? names[0] : null,
    links: {
      wiki: `https://www.poe2wiki.net/wiki/${encodeURIComponent(name.replaceAll(" ", "_"))}`,
      poedb: null,
      craftOfExile: null,
    },
    stashSearch: JSON.stringify(name),
    samePricedSearch: null,
    note: null,
    weapon: null,
    defences: null,
    requires: null,
    skills: grantedSkills(clipboard),
    mods: describeModLines(clipboard),
    mirrored: false,
    fractured: false,
    sanctified: false,
  });
}

/** The name a magic or rare item has on its own (the base type is `item.info.name`). */
function itemTitle(item: ParsedItem): string | null {
  if (item.rarity !== ItemRarity.Rare && item.rarity !== ItemRarity.Magic) return null;
  const header = (parserInternals.itemTextToSections(item.rawText) as string[][])[0] ?? [];
  const names = header.slice(2).filter((line) => line !== Data.CLIENT_STRINGS.CANNOT_USE_ITEM);
  if (item.rarity === ItemRarity.Rare) return names.length >= 2 ? names[0] : null;
  return names[0] && names[0] !== item.info.name ? names[0] : null;
}

function describeDefences(item: ParsedItem) {
  // Upstream's parser drops a unique's defences (its price check searches by name); read them here.
  const fromText = (prefix: string) => {
    for (const line of item.rawText.split(/\r?\n/)) {
      if (line.startsWith(prefix)) return parseInt(line.slice(prefix.length), 10);
    }
    return null;
  };
  const unique = item.rarity === ItemRarity.Unique;
  const _$ = Data.CLIENT_STRINGS;
  const values = {
    armour: item.armourAR ?? (unique ? fromText(_$.ARMOUR) : null),
    evasion: item.armourEV ?? (unique ? fromText(_$.EVASION) : null),
    energyShield: item.armourES ?? (unique ? fromText(_$.ENERGY_SHIELD) : null),
    ward: item.armourRW ?? (unique ? fromText(_$.RUNIC_WARD) : null),
    block: item.armourBLOCK ?? (unique ? fromText(_$.BLOCK_CHANCE) : null),
  };
  return Object.values(values).some((v) => v != null) ? values : null;
}

/** The modifier blocks of copied item text: each "{ … }" line with the lines under it. */
function describeModLines(rawText: string) {
  const sections = parserInternals.itemTextToSections(rawText) as string[][];
  const mods: Array<{
    type: string;
    generation: string | null;
    name: string | null;
    tier: number | null;
    rank: number | null;
    tags: string[];
    lines: string[];
  }> = [];
  for (const section of sections) {
    if (!section.length || !isModInfoLine(section[0])) continue;
    for (const { modLine, statLines } of groupLinesByMod(section)) {
      const { modType, lines } = parseModType(statLines);
      let info;
      try {
        info = parseModInfoLine(modLine, modType);
      } catch {
        info = { type: modType, tags: [] as string[] };
      }
      mods.push({
        type: info.type,
        generation: info.generation ?? null,
        name: info.name ?? null,
        tier: info.tier ?? null,
        rank: info.rank ?? null,
        tags: info.tags ?? [],
        lines,
      });
    }
  }
  return mods;
}

// Same as upstream's hotkeyable-actions.ts (not exported there).
const POEDB_LANGS: Record<string, string> = {
  en: "us",
  ru: "ru",
  "cmn-Hant": "tw",
  ko: "kr",
  ja: "jp",
  de: "de",
  es: "sp",
  pt: "pt",
  fr: "fr",
};

const POE2DB_CONVERSIONS = new Map<string, string>([
  [ItemCategory.Claw, "Claws"],
  [ItemCategory.Dagger, "Daggers"],
  [ItemCategory.Wand, "Wands"],
  [ItemCategory.OneHandedSword, "One_Hand_Swords"],
  [ItemCategory.OneHandedAxe, "One_Hand_Axes"],
  [ItemCategory.OneHandedMace, "One_Hand_Maces"],
  [ItemCategory.Sceptre, "Sceptres"],
  [ItemCategory.Spear, "Spears"],
  [ItemCategory.Flail, "Flails"],
  [ItemCategory.Bow, "Bows"],
  [ItemCategory.Staff, "Staves"],
  [ItemCategory.TwoHandedSword, "Two_Hand_Swords"],
  [ItemCategory.TwoHandedAxe, "Two_Hand_Axes"],
  [ItemCategory.TwoHandedMace, "Two_Hand_Maces"],
  [ItemCategory.Warstaff, "Quarterstaves"],
  [ItemCategory.Crossbow, "Crossbows"],
  [ItemCategory.Talisman, "Talismans"],
  [ItemCategory.Amulet, "Amulets"],
  [ItemCategory.Ring, "Rings"],
  [ItemCategory.Belt, "Belts"],
  [ItemCategory.BodyArmour, "Body_Armours"],
  [ItemCategory.Helmet, "Helmets"],
  [ItemCategory.Gloves, "Gloves"],
  [ItemCategory.Boots, "Boots"],
  [ItemCategory.Quiver, "Quivers"],
  [ItemCategory.Shield, "Shields"],
  [ItemCategory.Focus, "Foci"],
  [ItemCategory.Buckler, "Bucklers"],
  ["Ruby", "Ruby"],
  ["Emerald", "Emerald"],
  ["Sapphire", "Sapphire"],
  ["Time-Lost Ruby", "Time-Lost_Ruby"],
  ["Time-Lost Emerald", "Time-Lost_Emerald"],
  ["Time-Lost Sapphire", "Time-Lost_Sapphire"],
  ["Life Flask", "Life_Flasks"],
  ["Mana Flask", "Mana_Flasks"],
  ["Charm", "Charms"],
  ["Urn Relic", "Urn_Relic"],
  ["Amphora Relic", "Amphora_Relic"],
  ["Vase Relic", "Vase_Relic"],
  ["Seal Relic", "Seal_Relic"],
  ["Coffer Relic", "Coffer_Relic"],
  ["Tapestry Relic", "Tapestry_Relic"],
  ["Incense Relic", "Incense_Relic"],
  ["Breach Precursor Tablet", "Breach_Precursor_Tablet"],
  ["Expedition Precursor Tablet", "Expedition_Precursor_Tablet"],
  ["Delirium Precursor Tablet", "Delirium_Precursor_Tablet"],
  ["Ritual Precursor Tablet", "Ritual_Precursor_Tablet"],
  ["Precursor Tablet", "Precursor_Tablet"],
  ["Overseer Precursor Tablet", "Overseer_Precursor_Tablet"],
  ["Waystones(Low)", "Waystones_low_tier"],
  ["Waystones(Mid)", "Waystones_mid_tier"],
  ["Waystones(Top)", "Waystones_top_tier"],
]);

function encodePoe2dbUri(text: string) {
  return text.replaceAll(/ /g, "_").replaceAll(/'/g, "");
}

function poe2dbPath(item: ParsedItem): string | undefined {
  const category = item.category;
  const refName = item.info.refName;
  if (!category) return;
  if (item.rarity === ItemRarity.Unique) return encodePoe2dbUri(refName);
  if (POE2DB_CONVERSIONS.has(refName)) return POE2DB_CONVERSIONS.get(refName)! + "#ModifiersCalc";
  if (!POE2DB_CONVERSIONS.has(category)) return encodePoe2dbUri(refName);
  let path = POE2DB_CONVERSIONS.get(category)!;
  if (ARMOUR.has(category) && !(category === ItemCategory.Buckler || category === ItemCategory.Focus)) {
    if (item.armourAR) path += "_str";
    if (item.armourEV) path += "_dex";
    if (item.armourES) path += "_int";
  }
  return path + "#ModifiersCalc";
}
