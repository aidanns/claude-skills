# claude-skills

Personal Claude Code plugin marketplace for Aidan Nagorcka-Smith.

## Scope

A GitHub-hosted plugin marketplace for custom Claude Code plugins. Plugins are installable on any machine via Claude Code's standard plugin system.

## Installation

Register this marketplace in `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "claude-skills": {
      "source": {
        "source": "github",
        "repo": "aidanns/claude-skills"
      }
    }
  }
}
```

Then install individual plugins:

```
/plugin install <plugin-name>@claude-skills
```

Or browse available plugins:

```
/plugin > Discover
```

## Usage

### Adding a new plugin

Create a directory under `plugins/` following this structure:

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

Minimum `plugin.json`:

```json
{
  "name": "my-plugin",
  "description": "What this plugin does",
  "author": {
    "name": "Aidan Nagorcka-Smith"
  }
}
```

## License

MIT

## Author

Aidan Nagorcka-Smith
