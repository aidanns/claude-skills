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
