// Replaces upstream's overlay/widget-registry for the headless engine.
//
// The real registry imports every widget's .vue component, which pulls the whole UI into the
// engine and creates an import cycle (Config → registry → CheckedItem.vue → help/tips → Config)
// that leaves enums undefined at load time. Config.ts only uses the registry to build default
// widgets when no saved config exists; the engine falls back to its own price-check defaults.
export const registry = {
  widgets: [] as unknown[],
  getWidgetComponent(_wmType: string) {
    return undefined;
  },
};
