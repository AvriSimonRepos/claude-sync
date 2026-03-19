# claude-sync

Export, import, and sync your entire Claude Code setup across machines.

Covers **everything** — settings, skills, MCP configs, plugins, agents, custom scripts, project-level memory, and CLAUDE.md files.

## Why not [claude-config-portable](https://github.com/nizanrosh/claude-config-portable)?

| Feature | claude-config-portable | claude-sync |
|---|---|---|
| Global settings | Yes | Yes |
| User skills | Yes | Yes |
| **Project-level skills** | No | **Yes** |
| **Project memory** | No | **Yes** |
| **Custom scripts** (statusline, etc.) | No | **Yes** |
| **CLAUDE.md files** | No | **Yes** |
| Version history | No | **Full git log** |
| Diff between exports | No | `claude-sync diff` |
| Selective import | `--only`/`--skip` | `--only`/`--skip` |
| Share skills across projects | No | `install-skill` |
| Dependencies | Go 1.22+ | bash + git |

## Install

```bash
# Option 1: curl
curl -fsSL https://raw.githubusercontent.com/your-user/claude-sync/main/install.sh | bash

# Option 2: clone
git clone https://github.com/your-user/claude-sync.git
cp claude-sync/claude-sync.sh ~/.local/bin/claude-sync
chmod +x ~/.local/bin/claude-sync
```

## Quick Start

```bash
# 1. Initialize config repo
claude-sync init

# 2. Export your setup
claude-sync export

# 3. Connect to GitHub (private repo recommended)
cd ~/.claude-config
git remote add origin git@github.com:your-user/claude-config.git
git push -u origin main

# 4. From now on, one command to sync:
claude-sync sync
```

## Commands

| Command | Description |
|---|---|
| `init [remote-url]` | Create config repo or clone existing one |
| `export` | Snapshot `~/.claude/` + project configs → config repo |
| `import` | Restore from config repo → `~/.claude/` |
| `sync` | Export + commit + push (daily driver) |
| `diff` | Show changes since last export |
| `status` | Overview of your Claude Code setup |
| `install-skill <name> <project>` | Copy a skill into any project |
| `list-skills` | List all available skills |
| `push` / `pull` | Git push/pull the config repo |

## Options

| Flag | Description |
|---|---|
| `--only <components>` | Only sync: `settings,skills,plugins,scripts,mcp,agents,memory,projects` |
| `--skip <components>` | Skip specific components |
| `--dry-run` | Preview import without writing |
| `--from <path>` | Use alternate config repo for `install-skill` |

## What Gets Synced

### Global (`~/.claude/`)
- `settings.json` / `settings.local.json`
- `skills/` (user-level custom skills)
- `agents/` (custom agent definitions)
- `*.sh` (statusline, context scripts)
- `plugins/installed_plugins.json` + `known_marketplaces.json`
- `.mcp.json` (MCP server config)

### Per-Project
- `.claude/skills/` (project-level skills like `sass-architect`, `prd`)
- Project memory (`~/.claude/projects/*/memory/`)
- `.claude/CLAUDE.md` and root `CLAUDE.md`
- Project-level settings and MCP configs

## Setup on a New Machine

```bash
# Install the tool
curl -fsSL https://raw.githubusercontent.com/your-user/claude-sync/main/install.sh | bash

# Clone your config
claude-sync init git@github.com:your-user/claude-config.git

# Restore everything
claude-sync import

# Or just specific parts
claude-sync import --only skills,settings
```

## Share with a Colleague

```bash
# They clone your config repo (or fork it)
claude-sync init git@github.com:your-user/claude-config.git

# Import only skills and settings (skip your personal memory/scripts)
claude-sync import --only skills,settings

# Or install a single skill into their project
claude-sync install-skill sass-architect ~/Projects/their-project
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_HOME` | `~/.claude` | Claude config directory |
| `CLAUDE_SYNC_REPO` | `~/.claude-config` | Config repo location |
| `CLAUDE_SYNC_PROJECTS` | (auto-discovered) | Colon-separated project paths |

## Storage Backends

The config repo is just a git repo. Push it anywhere:

- **GitHub** (recommended): Private repo, free, `gh` CLI support
- **GitLab / Bitbucket**: Same git workflow
- **Google Drive**: Use [rclone](https://rclone.org/) to sync `~/.claude-config/` to Drive
- **Dropbox / OneDrive**: Symlink `~/.claude-config` into your sync folder

## Security

- **Credentials are excluded** — `.credentials.json`, secrets, keys are in `.gitignore`
- **Plugin caches excluded** — only references are synced (plugins reinstall from marketplace)
- **History/sessions excluded** — conversation data stays local
- Use a **private repo** for your config data

## License

MIT
