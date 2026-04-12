# Things CLI Skill Design

## Purpose

A Claude Code skill that teaches Claude how to interact with the Things3 task manager via the `things` CLI (installed from `brew install things-cli`). Purely reactive — only used when the user explicitly asks to interact with Things3.

## Trigger

When the user asks to add todos, view lists/projects, or otherwise interact with Things3.

## Skill content

Concise CLI reference covering:

1. **Binary and quirks** — command is `things`, works via AppleScript, Things3 must be running.
2. **Command reference** — `show-lists`, `show-projects`, `show --list/--project`, `add` with all options.
3. **Common patterns** — one-liner recipes for typical operations.

## Plugin structure

```
plugins/things/
├── .claude-plugin/
│   └── plugin.json
└── skills/
    └── things/
        └── SKILL.md
```

No commands, agents, or MCP servers.
