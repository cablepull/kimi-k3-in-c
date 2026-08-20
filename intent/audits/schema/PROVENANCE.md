# Vendored cablepull/ach schema — Provenance

## Source

- Upstream: `https://cablepull.github.io/ach`
- Source repo: `https://github.com/cablepull/cablepull.github.io`
- Path within repo: `ach/analyses/<id>/*.json` (live analyses are the de
  facto schema; an explicit `*.schema.json` set is to be derived from those
  examples).

## Pin

- Pinned to upstream `main` as of 2026-05-24.
- Reference analyses inspected for shape:
  - `ai-transformation-threats` (70 evidence items, 7 hypotheses)
  - `future-of-truth-rosenbaum` (13 evidence items, 6 hypotheses)
- `index.json` shape observed at
  `https://raw.githubusercontent.com/cablepull/cablepull.github.io/main/ach/analyses/index.json`.

## Status of v1 schemas

The `schema/v1/` directory will contain explicit JSON Schema files derived
from the observed analyses. Until those are committed, the validator (per
story 009) operates against the shape implied by the reference analyses —
the schema files will be added in the first implementation iteration that
touches F-5 (story 009).

This file documents the pin so a future contributor can reconcile the
vendored schema with upstream changes.

## Why vendored

`intent.md` C-1 forbids network calls during operation. C-14 commits to the
cablepull format. Reconciling these means we own the schema in-tree, pinned
to a known upstream state, with this provenance file as the audit trail.

## Migration protocol

If upstream changes incompatibly:

1. Capture the diff in a new entry in this file (don't rewrite history).
2. Decide: stay pinned, migrate, or fork. The decision is its own ADR
   (ADR-005 may be superseded).
3. If migrating: write a migration that recomputes prior audits' bundles
   against the new schema and commit them together.
