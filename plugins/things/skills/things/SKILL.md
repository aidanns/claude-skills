---
name: things
description: Use when the user asks to interact with Things3 — adding todos, viewing lists or projects, checking what's due, or managing tasks.
version: 1.0.0
---

# Things3 CLI Reference

The `things` command (installed via `brew install things-cli`) interacts with Things3 via AppleScript. Things3 must be installed and running.

## Discovering lists and projects

```bash
# Built-in lists (Inbox, Today, Anytime, Upcoming, Trash)
things show-lists

# User-created projects
things show-projects
```

## Viewing todos

Use `--list` for built-in lists and `--project` for projects. Without either flag, `show` defaults to `--project`, so built-in lists like Today will fail without `--list`.

```bash
# View today's todos
things show --list Today

# View inbox
things show --list Inbox

# View todos in a project
things show --project "Project Name"
```

## Adding todos

```bash
things add "Todo title"

# Add to a specific list
things add "Buy milk" --list Inbox

# Add with a due date
things add "Submit report" --when tomorrow

# Add with notes
things add "Call dentist" --notes "Ask about appointment availability"

# Add with tags
things add "Fix bug" --tags "work,urgent"

# Add with a checklist (comma-separated items)
things add "Pack for trip" --checklist "Passport,Charger,Clothes"

# Add to a project with all options
things add "Write tests" --list Inbox --when tomorrow --notes "Unit tests for auth module" --tags "dev"

# Add an already-completed todo
things add "Completed task" --completed
```

## Quirks

- The binary is `things`, not `things-cli`.
- `show` defaults to project lookup. Always pass `--list` for built-in lists (Inbox, Today, Anytime, Upcoming, Trash).
- The `--info` flag on `show` and `add` prints the generated AppleScript — useful for debugging only.
- The CLI only supports adding and viewing todos. There are no commands for completing, deleting, or moving todos.
