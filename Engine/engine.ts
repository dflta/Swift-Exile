// Headless price-check engine.
//
// Runs Exiled Exchange 2's own parser, filter, trade, and price code (imported unchanged from
// upstream/) without any UI. SwiftExile loads it in a hidden WKWebView and draws the price check in
// SwiftUI. Every function returns a JSON string so Swift can decode it with Codable.
//
// It follows the same steps as upstream's CheckedItem.vue / PriceTrend.vue / PriceCheckWindow.vue.
import { toRaw } from "vue";
import { initConfig, AppConfig } from "@/web/Config";
import * as Data from "@/assets/data";
import { Host } from "@/web/background/IPC";
import { parseClipboard, ItemCategory, ItemRarity, type ParsedItem } from "@/parser";
import { createPresets } from "@/web/price-check/filters/create-presets";
import type { FilterPreset, StatFilter } from "@/web/price-check/filters/interfaces";
import { apiToSatisfySearch } from "@/web/price-check/trade/common";
import { CATEGORY_TO_TRADE_ID } from "@/web/price-check/trade/pathofexile-trade";
import { useTradeApi } from "@/web/price-check/trade/trade-api";
import { useBulkApi } from "@/web/price-check/trade/bulk-api";
import { useLeagues } from "@/web/background/Leagues";
import { usePoeninja } from "@/web/background/Prices";
import { getDetailsId } from "@/web/price-check/trends/getDetailsId";

interface PriceCheckWidgetConfig {
  collapseListings: "app" | "api";
  activateStockFilter: boolean;
  searchStatRange: number;
  defaultAllSelected: boolean;
  smartInitialSearch: boolean;
  lockedInitialSearch: boolean;
}

interface State {
  item: ParsedItem;
  presets: { active: string; presets: FilterPreset[] };
  api: "trade" | "bulk";
}

let state: State | null = null;
let tradeApi: ReturnType<typeof useTradeApi> | null = null;
let bulkApi: ReturnType<typeof useBulkApi> | null = null;

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
};
const widget = () => ({ ...WIDGET_DEFAULTS, ...(AppConfig("price-check") as unknown as Partial<PriceCheckWidgetConfig> | undefined) });
const activePreset = (s: State) => s.presets.presets.find((p) => p.id === s.presets.active)!;

/** Loads settings, item data, leagues, and poe.ninja prices. Call once. */
export async function init(): Promise<string> {
  // The engine never talks to the overlay's event socket (it would steal item events).
  Host.sendEvent = () => {};
  await initConfig();
  await Data.init(AppConfig().language);
  const leagues = useLeagues();
  await leagues.load();
  const ninja = usePoeninja();
  ninja.queuePricesFetch();
  tradeApi = useTradeApi();
  bulkApi = useBulkApi();
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
  const presets = createPresets(item, {
    league: leagues.selectedId.value!,
    collapseListings: w.collapseListings,
    activateStockFilter: w.activateStockFilter,
    searchStatRange: w.searchStatRange,
    useEn:
      (AppConfig().language === "cmn-Hant" && AppConfig().realm === "pc-ggg") ||
      AppConfig().preferredTradeSite === "www",
    currency: undefined,
    listingType: undefined,
    defaultAllSelected: w.defaultAllSelected,
  });
  const preset = presets.presets.find((p) => p.id === presets.active)!;
  const api = apiToSatisfySearch(item, preset.stats, preset.filters);
  if (api === "bulk") preset.filters.trade.listingType = "online";
  state = { item, presets, api };

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
    api,
    searchByDefault,
    league: leagues.selectedId.value ?? null,
    presets: presets.presets.map((p) => ({ id: p.id, active: p.id === presets.active })),
    stats: describeStats(preset.stats),
    ninja: await ninjaPrice(item),
  });
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
  state.api = apiToSatisfySearch(state.item, activePreset(state).stats, activePreset(state).filters);
  return json({ stats: describeStats(activePreset(state).stats), api: state.api });
}

export function selectPreset(id: string): string {
  if (!state) return json({ error: "no item" });
  state.presets.active = id;
  const preset = activePreset(state);
  state.api = apiToSatisfySearch(state.item, preset.stats, preset.filters);
  return json({ stats: describeStats(preset.stats), api: state.api });
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
    ? (["xchgStable", "xchgExalted", "xchgChaos"] as const).map((key) => {
        const listed = toRaw(result[key].listed.value);
        return {
          have: listed?.haveTag ?? key,
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

// MARK: Helpers

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

function describeStats(stats: StatFilter[]) {
  return stats.map((stat, index) => ({
    index,
    text: stat.text,
    display: stat.roll ? stat.text.replace("#", formatRoll(stat.roll.value, stat.roll.dp)) : stat.text,
    tag: stat.tag,
    hidden: stat.hidden ?? null,
    disabled: stat.disabled,
    roll: stat.roll
      ? {
          value: stat.roll.value,
          min: stat.roll.min === "" || stat.roll.min === undefined ? null : stat.roll.min,
          max: stat.roll.max === "" || stat.roll.max === undefined ? null : stat.roll.max,
          defaultMin: stat.roll.default.min,
          defaultMax: stat.roll.default.max,
          boundsMin: stat.roll.bounds?.min ?? null,
          boundsMax: stat.roll.bounds?.max ?? null,
          decimal: stat.roll.dp,
        }
      : null,
  }));
}

function formatRoll(value: number, decimal: boolean) {
  return decimal ? value.toFixed(2).replace(/\.?0+$/, "") : String(Math.round(value));
}

/** poe.ninja price, like PriceTrend.vue. Waits up to 3 s for the price list on first use. */
async function ninjaPrice(item: ParsedItem) {
  const ninja = usePoeninja();
  for (let waited = 0; ninja.initialLoading() && waited < 3000; waited += 100) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const detailsId = getDetailsId(item);
  const entry = detailsId && ninja.findPriceByQuery(detailsId);
  if (!entry) return null;
  const price = ninja.autoCurrency(entry.primaryValue, item.info.refName === "Divine Orb");
  return { min: price.min, max: price.max, currency: price.currency, url: entry.url ?? null };
}
