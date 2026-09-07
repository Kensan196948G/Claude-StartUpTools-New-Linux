#!/usr/bin/env node
// post-compact-reinject.js (ClaudeOS v10) — SessionStart(matcher: compact) hook
// /compact・autocompact 後に pre-compact.js が退避した evacuation-latest.json の要旨 (≤12 行) だけを
// additionalContext として再注入する。session-start.js の全量再注入 (thrashing の原因) は行わない。
"use strict";
const fs = require("fs");
const path = require("path");
const file = path.join(process.cwd(), ".claude", "claudeos", "snapshots", "evacuation-latest.json");
let ev = null;
try { ev = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(0); }
const lines = [
  "[PostCompact] 圧縮前の退避情報 (evacuation-latest.json)",
  `  evacuated_at: ${ev.evacuated_at || "?"}`,
  `  phase: ${ev.phase || "?"}`,
  `  last_session_summary: ${String(ev.last_session_summary || "(none)").slice(0, 300)}`,
  `  stable_achieved: ${ev.stable_achieved ? "yes" : "no"} / consecutive_success: ${ev.consecutive_success ?? 0}`,
];
if (Array.isArray(ev.orchestration_events) && ev.orchestration_events.length) {
  lines.push(`  recent_events: ${ev.orchestration_events.slice(-3).map((e) => (typeof e === "string" ? e : JSON.stringify(e))).join(" | ").slice(0, 300)}`);
}
lines.push("  → 中断した作業は state.json (execution.phase / warnings) と git status を再確認してから継続する");
try {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: lines.join("\n") } }));
} catch { console.log(lines.join("\n")); }
process.exit(0);
