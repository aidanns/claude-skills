# Claude Skills Marketplace Setup

## Purpose

Set up `aidanns/claude-skills` as a personal Claude Code plugin marketplace hosted on GitHub. This allows installing custom-built plugins on any machine via the standard plugin system.

## Structure

```
claude-skills/
├── README.md
├── LICENSE
├── plugins/
│   └── (one directory per plugin)
└── external_plugins/
    └── (placeholder for future third-party inclusions)
```

Each plugin follows the standard Claude Code plugin structure:

```
plugins/my-plugin/
├── .claude-plugin/
│   └── plugin.json       # name, description, author metadata
├── skills/               # SKILL.md files
│   └── my-skill/
│       └── SKILL.md
├── commands/              # slash commands (optional)
├── agents/                # agent definitions (optional)
└── README.md
```

## Registration

Add to `~/.claude/settings.json` under `extraKnownMarketplaces`:

```json
"claude-skills": {
  "source": {
    "source": "github",
    "repo": "aidanns/claude-skills"
  }
}
```

Install plugins via `/plugin install <name>@claude-skills`.

## Decisions

- Public repo so plugins are installable without auth.
- MIT license.
- No CI/CD, linting, or example plugin scaffolding.
- `main` branch as default.
