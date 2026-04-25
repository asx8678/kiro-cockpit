# Phase 2 NanoPlanner Review

Issue: `kiro-fxm`  
Base branch: `main`  
Feature branch: `feature/kiro-fxm-phase2-review`  
Spec: `plan2.md`

## Scope

This review covered the completed Phase 2 NanoPlanner Brain work:

- `.kiro/agents/*` planner/executor configuration and `priv/prompts/*` prompts
- plan persistence migrations, schemas, and `KiroCockpit.Plans`
- `KiroCockpit.ProjectSnapshot`
- `KiroCockpit.NanoPlanner.ContextBuilder`, `PlanSchema`, `PromptBuilder`, and `NanoPlanner`
- `KiroCockpit.Permissions`
- CLI `/nano*`, `/plans`, and `/plan *` command routing
- `SessionPlanLive`, `PlanCard`, and `PermissionBadge`
- NanoPlanner and LiveView integration tests

## Findings

The review found two blocking issues in the Phase 2 read-only project snapshot/stale-plan area:

1. `ProjectSnapshot.compute_hash/1` did not fully implement the stale-plan hash expected by `plan2.md` §16/§18. It hashed root-tree text and config excerpts, but missed ordinary relevant source-file changes. It also included `session_summary`, which is conversational context rather than project state and could create false stale-plan positives.
2. `ContextBuilder.read_root_tree/2` recursively traversed project trees and only applied `max_tree_lines` after traversal. Per `plan2.md` §8/§18, Phase 2 discovery should be compact, safe, read-only, and shallow/top-level.

## Changes Made

The review pass fixed those issues directly:

- Added `file_fingerprints` to `%KiroCockpit.ProjectSnapshot{}` and to the snapshot hash inputs.
  - Fingerprints include relative path, file size, and POSIX mtime for bounded relevant project files.
  - Known noisy/build/vendor directories are skipped.
  - Symlinked directories are not followed during root discovery or fingerprinting.
- Removed `session_summary` from the stale-plan hash while keeping it in rendered prompt context.
- Changed root-file discovery to a shallow top-level listing with ignored build/cache/vendor entries.
- Hardened safe-file reads so they do not follow symlinked files or symlinked ancestor directories.
- Added regression coverage for:
  - source-file changes changing the stale-plan hash;
  - config-file changes beyond excerpt limits still changing the hash;
  - session-summary-only changes not changing the hash;
  - shallow root listings not including nested files;
  - noisy root directories being omitted;
  - symlinked `config/` and `lib/` ancestors not escaping the project root for safe reads;
  - deterministic hashing with file fingerprints.

## Residual Risks / Notes

- The stale-plan fingerprint intentionally uses metadata (`size` + POSIX `mtime`) rather than content hashing for all files, matching the Phase 2 spec wording around file mtimes while keeping context gathering lightweight and read-only.
- The fingerprint traversal is bounded (`@max_fingerprint_entries` and `@max_fingerprint_depth`) to avoid unbounded work on very large repositories. Extremely large projects may still have changes outside the bounded fingerprint set; this is acceptable for Phase 2 but should be revisited if stronger stale detection is needed.
- Existing Postgrex sandbox disconnect log lines can appear during the test suite but do not correspond to failures.

## Quality Gates

Final gates run in `/Users/adam2/projects/kiro-fxm`:

| Command | Result |
| --- | --- |
| `mix format --check-formatted` | PASS |
| `mix compile --warnings-as-errors` | PASS |
| `mix test test/kiro_cockpit/project_snapshot_test.exs test/kiro_cockpit/nano_planner/context_builder_test.exs` | PASS — 69 tests, 0 failures |
| `mix test` | PASS — 806 tests, 0 failures |
| `mix credo --strict` | PASS — 0 issues |
| `mix dialyzer` | PASS — 0 errors |

## Verdict

APPROVE after the stale-plan hash and compact discovery fixes above.
