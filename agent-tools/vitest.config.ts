import { defineConfig } from "vitest/config";

// The cores only: a plugin's `*.test.tsx` are Claude Code's own (`claude plugin test`), which
// in turn never runs a `*.spec.ts`. A string `tsconfigRaw` stops the lookup of the nearest
// tsconfig.json, which for a core is the plugin's, over types only `just dev-setup` lays.
export default defineConfig({
  esbuild: { tsconfigRaw: "{}" },
  test: { include: ["plugins/*/core/**/*.spec.ts"] },
});
