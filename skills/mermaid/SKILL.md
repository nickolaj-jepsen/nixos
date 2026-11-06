---
name: mermaid
description: Render the fenced Mermaid diagrams in a markdown file to SVG images linked above each block. Use whenever you write a Mermaid diagram into a markdown report, note or plan that a person will read outside GitHub, or when another skill says to render diagrams.
---

Run `node <skill-dir>/scripts/render.mjs <file.md>`. It renders each fenced `mermaid` block to `assets/<file>-<n>.svg` beside the file, links it above its block, and prints each SVG's path. Reruns replace the links and SVGs in place, so edit the Mermaid and run it again rather than touching the links.

- **Errors:** it prints the block's line and the parser error, and writes nothing. Fix every one and rerun; a diagram isn't done until it renders.
- **No Node:** keep the Mermaid text and say it wasn't rendered.
- **Pointing at it:** in chat, give the SVG path it printed, not the markdown file.
- **Not for committed docs:** GitHub renders Mermaid itself, so don't add SVGs to files in a repository unless asked.

Diagrams earn their place by showing a relationship that prose would need a paragraph for: a flow across components, a sequence of calls, a state machine, a dependency graph. Keep one to about a dozen nodes, label edges with what crosses them, and draw only what you've verified.
