# intent — orientation for Claude (and any LLM)

This project is set up with **magnetfragnet** — a per-iteration nudge tool
that watches your TDD loop, surfaces drift, and asks for ACH-shaped audits
when the architecture changes. The tool's MCP server is configured in
`.mcp.json`; Claude Code auto-discovers it.

## In 30 seconds

After each TDD red→green→refactor cycle, call the `nudge_iteration` MCP
tool with `{ iteration, diff: { files_changed, loc_added, loc_removed } }`.
The server returns the highest-priority nudge for *this* iteration's diff
against *this* project's state.

If `primary.skill` is set, your next move is to apply the named skill —
write the artifact it demands — and then call `validate_skill_artifact`
or `audit_completed`.

## Read this first

1. **`intent.md`** — the foundational doc for this project. Your
   constraints (numbered `C-N`) and the tool's 10 nudge dimensions.
   Everything traces upward to here.
2. **`magnetfragnet stats`** at the command line — shows what nudges have
   fired over time, primary-nudge distribution, per-detector latency. Run
   it whenever you want to see if the discipline is paying off.

## MCP tools you can call

| Tool | When | Returns |
|---|---|---|
| `nudge_iteration` | After each TDD iteration | `{ primary, all_fired, skipped, citations, detector_latency_ms, total_ms }` |
| `validate_skill_artifact` | After producing a non-audit artifact under a skill | `{ ok, errors[] }` |
| `audit_completed` | After producing an architecture audit bundle | `{ ok, counter_reset, errors? }` |
| `report_card` | Anytime, to inspect history | Same shape as `magnetfragnet stats --json` |
| `eval_session` | Anytime, for cross-iteration signals (stuck primary, cadence drop, staleness) | `{ evals: EvalResult[] }` |

## Interpreting a nudge response

**Primary is chosen by `distance × weight`, not by severity.** A
`severity: "info"` nudge can outrank a `severity: "warn"` one if it's
farther from threshold. Ties are broken lexicographically by `nudge_id`.

**If `primary.skill` is set**, apply the skill (read its `SKILL.md`,
follow the template), then call `validate_skill_artifact` or
`audit_completed`.

**If `primary.skill` is NOT set, but a non-primary entry in `all_fired`
has a `skill` field**, that skill-bearing nudge is *queued*: it will
re-fire on subsequent iterations until you address it. For architecture
audits (nudge #9) the trigger persists in the rolling-diff window until
`audit_completed` validates a bundle on disk.

## How to produce an ACH artifact

**ID convention:** `audit-NNN-<slug>-YYYY-MM-DD` for architecture audits,
`rca-NNN-<slug>-YYYY-MM-DD` for ACH-shaped RCAs. Increment NNN from the
highest existing ID under the same dir.

Each artifact is a directory of four JSON files under `audits/<id>/` (or
`rca/<id>/`):

- `metadata.json` — `analyticQuestion`, `keyJudgment{summary, confidence}`,
  `remainingGaps`, `triggerEvent`, `iterationNumber`.
- `hypotheses.json` — must include a mundane hypothesis. For architecture
  audits, must include all five archetype tags: `fit`, `posthoc`,
  `cherrypick`, `drift`, `tension`.
- `evidence.json` — every `sourceIds` entry must resolve in `sources.json`.
- `sources.json` — every source must have `type ∈ {test, research, artifact}`
  and a `path` that exists on disk.

When ready, call `audit_completed(iteration, bundleDir)`. The server
validates with the architecture floor enforced; on pass, the counter resets.

## Inspecting the project's discipline over time

```
magnetfragnet stats           # human table
magnetfragnet stats --json    # machine-readable, same data as report_card
magnetfragnet status --line   # one-line live summary; wire into your harness's status line
magnetfragnet eval            # cross-iteration eval signals + context suggestions
magnetfragnet report <query>   # longitudinal metric queries (series, latency-trend, ...)
magnetfragnet predict list     # prediction ledger
magnetfragnet check           # record one iteration from any shell (same engine as nudge_iteration)
magnetfragnet hooks install   # wire `check` into Claude Code lifecycle hooks
magnetfragnet watch           # foreground watcher: fire `check` on context-shift edits
```

You'll see total iterations, per-nudge fire counts, primary-nudge
distribution, mean + p95 per-detector latency, audits completed, and the
current audit counter. If a detector is consistently skipping (errors),
it'll appear in the Skipped section with the most recent reason.

## What NOT to do

- Don't cite `intent.md` constraints loosely. Use `C-N` IDs.
- Don't write narrative-only evidence in ACH bundles — every cell must
  back to a re-runnable test, a re-readable research note, or a
  versioned artifact reference.
- Don't change the score formula in the magnetfragnet source without a
  superseding ADR and a migration commit.

## If you're stuck

- A nudge confuses you → read its detector source (named in `report_card`).
- The discipline confuses you → re-read `intent.md`. The constraints are
  your anchor.
- The tool itself confuses you → run `magnetfragnet --help` and
  `magnetfragnet stats`.

If after that the docs still confuse you, that's a doc bug worth flagging
in a research note under `research/`. The next session inherits the fix.
