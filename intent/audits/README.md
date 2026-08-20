# `audits/` — Architecture Audits (ACH-shaped)

Architecture audits produced under nudge #9 by the `intelligence-analyst`
skill. Each audit answers: *does the architecture, as it has actually
evolved, still serve the intent given what the project has learned?*

## Discipline

- Each audit is a directory: `audits/audit-NNN-<slug>-YYYY-MM-DD/`.
- Four required files: `metadata.json`, `hypotheses.json`,
  `evidence.json`, `sources.json`.
- Bundles conform to the vendored cablepull/ach schemas under `schema/v1/`.
- `index.json` catalogs all audits (cablepull-compatible).
- `state.jsonl` (when present) is a derived projection; never hand-edit.
- `evolution.md` (when present) is a generated view embedding Mermaid
  diagrams.

## Source discipline (intent C-12)

Every `evidence[*].sourceIds` must resolve to a `sources.json` entry whose
`type` is `test`, `research`, or `artifact` AND whose `path` exists on
disk. Narrative-only evidence fails the validator.

## Hypothesis IDs (intent C-13)

Hypotheses live in a project-wide namespace (`H-arch-NNN`, `H-rca-NNN`).
Each per-audit `hypotheses.json` may carry a `lineage` field
(`derivedFrom`, `supersededBy`, `mergedFrom`) referencing prior IDs.

## Floor (PRD F-14 R-6)

Every architecture audit must include hypotheses tagged for each of:
`fit`, `posthoc`, `cherrypick`, `drift`, `tension`.

## Index

| ID | Title | Trigger | Date | Status |
|---|---|---|---|---|
| _(none yet)_ | | | | |
