// Builds Engine/engine.ts into one script (Engine/dist/engine.js) using upstream's sources and
// node_modules. Plain object with no imports, so it needs nothing installed next to it.
// Run from upstream/renderer: npx vite build --config ../../Engine/vite.config.mjs
const repo = new URL("..", import.meta.url).pathname;
const renderer = repo + "upstream/renderer/";
// A few upstream modules imported by the config pull in .vue files; load upstream's Vue plugin.
const { default: vue } = await import(renderer + "node_modules/@vitejs/plugin-vue/dist/index.mjs");

export default {
  root: renderer,
  base: "/",
  // Absolute asset paths in pulled-in .vue files (e.g. /images/...) resolve against upstream public/;
  // nothing from it is copied (the engine page reads data from the renderer folder at runtime).
  publicDir: renderer + "public",
  logLevel: "warn",
  plugins: [vue()],
  resolve: {
    alias: [
      // No UI in the engine: see Engine/widget-registry-stub.ts.
      { find: /^\.\/overlay\/widget-registry\.js$/, replacement: repo + "Engine/widget-registry-stub.ts" },
      { find: /^@ipc\//, replacement: repo + "upstream/ipc/" },
      { find: /^@\//, replacement: renderer + "src/" },
      { find: /^vue$/, replacement: renderer + "node_modules/vue" },
    ],
    extensions: [".ts", ".js", ".vue", ".json"],
  },
  define: {
    "import.meta.vitest": "undefined",
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  build: {
    outDir: repo + "Engine/dist",
    emptyOutDir: true,
    copyPublicDir: false,
    target: "esnext",
    sourcemap: false,
    minify: true,
    lib: {
      entry: repo + "Engine/engine.ts",
      formats: ["iife"],
      name: "SwiftExileEngine",
      fileName: () => "engine.js",
    },
  },
};
