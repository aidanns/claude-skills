# engineering

Engineering workflow skills covering domain-driven design, debugging discipline, TDD, architecture review, and an issue-tracker pipeline (PRD → vertical-slice issues → triage).

## Skills

| Skill | What it does |
| --- | --- |
| `diagnose` | Disciplined 6-phase debugging loop — feedback loop → reproduce → hypothesise → instrument → fix → cleanup. |
| `grill-with-docs` | Stress-tests a plan by interviewing the user one question at a time, sharpening domain language and updating `CONTEXT.md` / ADRs inline. |
| `improve-codebase-architecture` | Surfaces "deepening opportunities" (shallow → deep modules) using a deletion-test heuristic and a strict architectural glossary. |
| `tdd` | Test-driven development with strict red-green-refactor and vertical-slice (tracer-bullet) discipline. |
| `to-issues` | Breaks a plan or PRD into independently-grabbable tracer-bullet issues on the project issue tracker. |
| `to-prd` | Synthesises the current conversation into a PRD and posts it to the issue tracker. |
| `triage` | Moves issues through a state machine of canonical roles (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). |
| `zoom-out` | One-shot "give me a higher-level map of this area" prompt. |

## Setup expected by these skills

Several skills (`to-issues`, `to-prd`, `triage`, and indirectly `diagnose` / `tdd` / `improve-codebase-architecture`) reference per-repo conventions:

- An **issue tracker** (GitHub by default) and **triage label vocabulary** (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`).
- A **domain glossary** at `CONTEXT.md` and **ADRs** under `docs/adr/`.

In the upstream `mattpocock/skills` repo these are scaffolded by a `setup-matt-pocock-skills` skill. That setup skill is **not** included in this plugin — set up the conventions manually in each repo, or substitute your own equivalents. Skill prose still references `/setup-matt-pocock-skills`; treat those as pointers to your own setup process.

## Attribution

All skills in this plugin are adapted from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT License, Copyright (c) 2026 Matt Pocock).

| Skill | Upstream source |
| --- | --- |
| `diagnose` | [`skills/engineering/diagnose`](https://github.com/mattpocock/skills/tree/main/skills/engineering/diagnose) |
| `grill-with-docs` | [`skills/engineering/grill-with-docs`](https://github.com/mattpocock/skills/tree/main/skills/engineering/grill-with-docs) |
| `improve-codebase-architecture` | [`skills/engineering/improve-codebase-architecture`](https://github.com/mattpocock/skills/tree/main/skills/engineering/improve-codebase-architecture) |
| `tdd` | [`skills/engineering/tdd`](https://github.com/mattpocock/skills/tree/main/skills/engineering/tdd) |
| `to-issues` | [`skills/engineering/to-issues`](https://github.com/mattpocock/skills/tree/main/skills/engineering/to-issues) |
| `to-prd` | [`skills/engineering/to-prd`](https://github.com/mattpocock/skills/tree/main/skills/engineering/to-prd) |
| `triage` | [`skills/engineering/triage`](https://github.com/mattpocock/skills/tree/main/skills/engineering/triage) |
| `zoom-out` | [`skills/engineering/zoom-out`](https://github.com/mattpocock/skills/tree/main/skills/engineering/zoom-out) |

The companion `setup-matt-pocock-skills` skill is intentionally excluded.
