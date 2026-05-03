# CLAUDE.md

## Repository purpose

Personal Claude Code plugin marketplace hosted on GitHub as `aidanns/claude-skills`. Plugins are installed via `/plugin install <name>@claude-skills`.

## Structure

- `plugins/` — one subdirectory per plugin, each following the standard Claude Code plugin structure (`.claude-plugin/plugin.json`, `skills/`, `commands/`, `agents/`)
- `external_plugins/` — placeholder for future third-party plugin inclusions

## Conventions

- Each plugin must have a `.claude-plugin/plugin.json` with at minimum `name`, `description`, and `author` fields.
- Skills go in `skills/<skill-name>/SKILL.md` within the plugin directory.
- Follow the official plugin structure documented in `claude-plugins-official`.

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `aidanns/claude-skills` (use the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`) map 1:1 to label strings of the same name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root (created lazily by `engineering:grill-with-docs`). See `docs/agents/domain.md`.
