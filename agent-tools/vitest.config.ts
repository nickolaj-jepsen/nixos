import { defineConfig } from "vitest/config";

// The cores only: a plugin's `*.test.tsx` are Claude Code's own (`claude plugin test`), which
// in turn never runs a `*.spec.ts`.
export default defineConfig({
  test: { include: ["plugins/*/core/**/*.spec.ts"] },
});
