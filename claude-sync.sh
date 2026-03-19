#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CONFIG_REPO="${CLAUDE_SYNC_REPO:-$HOME/.claude-config}"
PROJECTS_DIR="${CLAUDE_SYNC_PROJECTS:-}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

usage() {
    cat <<'EOF'
claude-sync — Export, import, and sync your Claude Code setup

USAGE:
    claude-sync <command> [options]

COMMANDS:
    init                          Initialize config repo (or link existing)
    export                        Snapshot ~/.claude/ + projects → config repo
    import [--only X] [--skip X]  Restore config repo → ~/.claude/
    sync                          Export + commit + push (one-liner)
    diff                          Show changes since last export
    status                        List what would be exported
    install-skill <name> <path>   Copy a skill into a project
    list-skills                   List all available skills
    push                          Git push config repo
    pull                          Git pull config repo
    version                       Show version

OPTIONS:
    --only <components>     Comma-separated: settings,skills,plugins,scripts,mcp,agents,memory
    --skip <components>     Comma-separated list of components to skip
    --from <path>           Use alternate config repo (for install-skill)
    --dry-run               Show what would happen without doing it
    --with-secrets          Include API keys/tokens (default: stripped)

ENVIRONMENT:
    CLAUDE_HOME             Claude config dir (default: ~/.claude)
    CLAUDE_SYNC_REPO        Config repo location (default: ~/.claude-config)
    CLAUDE_SYNC_PROJECTS    Colon-separated project dirs to scan for .claude/

EOF
}

# ---------- helpers ----------

ensure_config_repo() {
    if [[ ! -d "$CONFIG_REPO/.git" ]]; then
        err "Config repo not found at $CONFIG_REPO"
        err "Run 'claude-sync init' first, or set CLAUDE_SYNC_REPO"
        exit 1
    fi
}

should_include() {
    local component="$1"
    if [[ -n "${ONLY:-}" ]]; then
        [[ ",$ONLY," == *",$component,"* ]]
    elif [[ -n "${SKIP:-}" ]]; then
        [[ ",$SKIP," != *",$component,"* ]]
    else
        return 0
    fi
}

PLACEHOLDER="__CONFIGURE_AFTER_IMPORT__"

# Secret patterns to strip from env vars and MCP configs
SECRET_PATTERNS='_KEY|_TOKEN|_SECRET|_PASSWORD|_CREDENTIAL|AUTHORIZATION|AUTH_HEADER|BEARER|API_KEY'

# Strip secrets from a JSON file, writing sanitized version to dst
strip_secrets_json() {
    local src="$1" dst="$2"
    if [[ "${WITH_SECRETS:-false}" == "true" ]]; then
        cp -a "$src" "$dst"
        return 0
    fi
    python3 -c "
import json, re, sys, os

PLACEHOLDER = '$PLACEHOLDER'
SECRET_RE = re.compile(r'($SECRET_PATTERNS)', re.IGNORECASE)

def scrub(obj, path=''):
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            full_key = f'{path}.{k}' if path else k
            if isinstance(v, str) and SECRET_RE.search(k):
                result[k] = PLACEHOLDER
            elif isinstance(v, dict):
                result[k] = scrub(v, full_key)
            elif isinstance(v, list):
                result[k] = [scrub(i, full_key) if isinstance(i, (dict, list)) else i for i in v]
            else:
                result[k] = v
        return result
    return obj

with open('$src') as f:
    data = json.load(f)

scrubbed = scrub(data)

os.makedirs(os.path.dirname('$dst') or '.', exist_ok=True)
with open('$dst', 'w') as f:
    json.dump(scrubbed, f, indent=2)
    f.write('\n')

# Report what was stripped
def find_stripped(orig, cleaned, path=''):
    found = []
    if isinstance(orig, dict) and isinstance(cleaned, dict):
        for k in orig:
            full = f'{path}.{k}' if path else k
            if k in cleaned and cleaned[k] == PLACEHOLDER and orig[k] != PLACEHOLDER:
                found.append(full)
            elif isinstance(orig.get(k), dict):
                found.extend(find_stripped(orig[k], cleaned.get(k, {}), full))
    return found

stripped = find_stripped(data, scrubbed)
for s in stripped:
    print(s)
" 2>/dev/null
}

# Check a file for placeholder values and warn
check_placeholders() {
    local file="$1"
    if [[ -f "$file" ]] && grep -q "$PLACEHOLDER" "$file" 2>/dev/null; then
        warn "  $file contains placeholder secrets — edit manually after import"
        return 0
    fi
    return 1
}

copy_if_exists() {
    local src="$1" dst="$2"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        return 0
    fi
    return 1
}

discover_projects() {
    local projects=()
    # From CLAUDE_SYNC_PROJECTS env var (colon-separated)
    if [[ -n "${PROJECTS_DIR:-}" ]]; then
        IFS=':' read -ra dirs <<< "$PROJECTS_DIR"
        for d in "${dirs[@]}"; do
            if [[ -d "$d/.claude" ]]; then
                projects+=("$d")
            fi
        done
    fi
    # From claude's own project registry
    if [[ -d "$CLAUDE_HOME/projects" ]]; then
        for pdir in "$CLAUDE_HOME/projects"/*/; do
            [[ -d "$pdir" ]] || continue
            local dirname
            dirname=$(basename "$pdir")
            # Skip worktree dirs
            [[ "$dirname" == *"--claude-worktrees-"* ]] && continue
            # Decode encoded path: -mnt-c-Users-Avri-Projects-interview-platform
            # Strategy: split on -, greedily build longest valid path segments
            local real_path=""
            local segments
            # Remove leading dash, split into array
            IFS='-' read -ra segments <<< "${dirname#-}"
            local current=""
            for seg in "${segments[@]}"; do
                if [[ -z "$current" ]]; then
                    current="/$seg"
                elif [[ -d "$current/$seg" ]]; then
                    current="$current/$seg"
                elif [[ -d "$current-$seg" ]]; then
                    current="$current-$seg"
                else
                    # Try appending with dash (for names like interview-platform)
                    if [[ -e "$current-$seg" || -d "$current-$seg" ]]; then
                        current="$current-$seg"
                    else
                        current="$current/$seg"
                    fi
                fi
            done
            real_path="$current"
            if [[ -d "$real_path" ]]; then
                local found=0
                for p in "${projects[@]+"${projects[@]}"}"; do
                    [[ "$p" == "$real_path" ]] && found=1 && break
                done
                [[ $found -eq 0 ]] && projects+=("$real_path")
            fi
        done
    fi
    printf '%s\n' "${projects[@]+"${projects[@]}"}"
}

project_slug() {
    # /mnt/c/Users/Avri/Projects/interview-platform → interview-platform
    basename "$1"
}

# ---------- commands ----------

cmd_init() {
    header "Initializing claude-sync config repo"

    if [[ -d "$CONFIG_REPO/.git" ]]; then
        warn "Config repo already exists at $CONFIG_REPO"
        echo "  Remote: $(cd "$CONFIG_REPO" && git remote get-url origin 2>/dev/null || echo 'none')"
        return 0
    fi

    local remote="${1:-}"
    if [[ -n "$remote" ]]; then
        info "Cloning $remote → $CONFIG_REPO"
        git clone "$remote" "$CONFIG_REPO"
    else
        info "Creating new config repo at $CONFIG_REPO"
        mkdir -p "$CONFIG_REPO"
        cd "$CONFIG_REPO"
        git init

        # Create .gitignore
        cat > .gitignore <<'GITIGNORE'
# Secrets — never commit
.credentials.json
*.key
*.pem
secrets/
.env

# Caches and ephemera
cache/
debug/
file-history/
history.jsonl
session-env/
sessions/
shell-snapshots/
stats-cache.json
statsig/
tasks/
todos/
telemetry/
backups/
paste-cache/
plans/
mcp-needs-auth-cache.json

# Plugin caches (references are enough to reinstall)
plugins/cache/
plugins/marketplaces/
plugins/repos/
plugins/config.json
plugins/blocklist.json
plugins/install-counts-cache.json
GITIGNORE

        cat > README.md <<'README'
# Claude Code Config

My Claude Code configuration, managed by [claude-sync](https://github.com/your-user/claude-sync).

## Contents
- `global/` — User-level settings, skills, scripts, plugin references
- `projects/` — Per-project skills, memory, CLAUDE.md files

## Restore on a new machine
```bash
# Install claude-sync first, then:
claude-sync init git@github.com:your-user/claude-config.git
claude-sync import
```
README

        git add -A
        git commit -m "Initial config repo"
        ok "Created config repo at $CONFIG_REPO"
        info "Add a remote: cd $CONFIG_REPO && git remote add origin <url>"
    fi
}

cmd_export() {
    ensure_config_repo
    header "Exporting Claude Code config"
    local count=0

    # --- Global settings (secrets stripped by default) ---
    if should_include "settings"; then
        info "Settings..."
        for f in settings.json settings.local.json; do
            if [[ -f "$CLAUDE_HOME/$f" ]]; then
                local stripped
                stripped=$(strip_secrets_json "$CLAUDE_HOME/$f" "$CONFIG_REPO/global/$f")
                if [[ -n "$stripped" ]]; then
                    warn "Stripped secrets from $f:"
                    echo "$stripped" | while read -r key; do
                        echo "    → $key"
                    done
                fi
                count=$((count + 1))
            fi
        done
    fi

    # --- Custom scripts ---
    if should_include "scripts"; then
        info "Scripts..."
        mkdir -p "$CONFIG_REPO/global/scripts"
        for f in "$CLAUDE_HOME"/*.sh; do
            [[ -f "$f" ]] || continue
            cp -a "$f" "$CONFIG_REPO/global/scripts/"
            count=$((count + 1))
        done
    fi

    # --- User-level skills ---
    if should_include "skills"; then
        info "User skills..."
        if [[ -d "$CLAUDE_HOME/skills" ]]; then
            mkdir -p "$CONFIG_REPO/global/skills"
            # Clean and re-copy to catch deletions
            rm -rf "$CONFIG_REPO/global/skills"
            cp -a "$CLAUDE_HOME/skills" "$CONFIG_REPO/global/skills"
            count=$(( count + $(find "$CONFIG_REPO/global/skills" -type f | wc -l) ))
        fi
    fi

    # --- Agents ---
    if should_include "agents"; then
        if compgen -G "$CLAUDE_HOME/agents/*.md" > /dev/null 2>&1; then
            info "Agents..."
            mkdir -p "$CONFIG_REPO/global/agents"
            cp -a "$CLAUDE_HOME"/agents/*.md "$CONFIG_REPO/global/agents/"
            count=$(( count + $(ls "$CONFIG_REPO/global/agents/"*.md 2>/dev/null | wc -l) ))
        fi
    fi

    # --- Plugin references ---
    if should_include "plugins"; then
        info "Plugin references..."
        mkdir -p "$CONFIG_REPO/global/plugins"
        for f in installed_plugins.json known_marketplaces.json; do
            if copy_if_exists "$CLAUDE_HOME/plugins/$f" "$CONFIG_REPO/global/plugins/$f"; then
                count=$((count + 1))
            fi
        done
    fi

    # --- MCP config (secrets stripped by default) ---
    if should_include "mcp"; then
        info "MCP config..."
        if [[ -f "$CLAUDE_HOME/.mcp.json" ]]; then
            local stripped
            stripped=$(strip_secrets_json "$CLAUDE_HOME/.mcp.json" "$CONFIG_REPO/global/mcp.json")
            if [[ -n "$stripped" ]]; then
                warn "Stripped secrets from .mcp.json:"
                echo "$stripped" | while read -r key; do
                    echo "    → $key"
                done
            fi
            count=$((count + 1))
        fi
    fi

    # --- Project-level configs ---
    if should_include "projects"; then
        info "Scanning projects..."
        while IFS= read -r project_path; do
            [[ -z "$project_path" ]] && continue
            local slug
            slug=$(project_slug "$project_path")
            local dest="$CONFIG_REPO/projects/$slug"
            info "  → $slug"

            # Skills
            if should_include "skills" && [[ -d "$project_path/.claude/skills" ]]; then
                rm -rf "$dest/skills"
                mkdir -p "$dest/skills"
                cp -a "$project_path/.claude/skills/." "$dest/skills/"
                count=$(( count + $(find "$dest/skills" -type f | wc -l) ))
            fi

            # Memory (from ~/.claude/projects/<encoded>/)
            if should_include "memory"; then
                local encoded_name
                encoded_name=$(echo "$project_path" | sed 's/\//-/g')
                local mem_src="$CLAUDE_HOME/projects/$encoded_name/memory"
                if [[ -d "$mem_src" ]]; then
                    rm -rf "$dest/memory"
                    mkdir -p "$dest/memory"
                    cp -a "$mem_src/." "$dest/memory/"
                    count=$(( count + $(find "$dest/memory" -type f | wc -l) ))
                fi
            fi

            # CLAUDE.md
            if copy_if_exists "$project_path/.claude/CLAUDE.md" "$dest/CLAUDE.md"; then
                count=$((count + 1))
            fi
            # Also check root CLAUDE.md
            if copy_if_exists "$project_path/CLAUDE.md" "$dest/CLAUDE.root.md"; then
                count=$((count + 1))
            fi

            # Project-level settings
            for f in settings.json settings.local.json; do
                local encoded_name
                encoded_name=$(echo "$project_path" | sed 's/\//-/g')
                if copy_if_exists "$CLAUDE_HOME/projects/$encoded_name/$f" "$dest/$f"; then
                    count=$((count + 1))
                fi
            done

            # Project-level MCP (secrets stripped)
            if should_include "mcp" && [[ -f "$project_path/.mcp.json" ]]; then
                strip_secrets_json "$project_path/.mcp.json" "$dest/mcp.json" > /dev/null
                count=$((count + 1))
            fi

        done < <(discover_projects)
    fi

    ok "Exported $count files to $CONFIG_REPO"

    # Show git status of config repo
    cd "$CONFIG_REPO"
    local changes
    changes=$(git status --porcelain | wc -l)
    if [[ $changes -gt 0 ]]; then
        info "$changes files changed. Run 'claude-sync push' to save remotely."
    else
        info "No changes since last export."
    fi
}

cmd_import() {
    ensure_config_repo
    header "Importing Claude Code config"
    local count=0
    local dry_run="${DRY_RUN:-false}"

    local has_placeholders=false

    # --- Global settings ---
    if should_include "settings"; then
        for f in settings.json settings.local.json; do
            if [[ -f "$CONFIG_REPO/global/$f" ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    info "[dry-run] Would restore $f"
                else
                    cp -a "$CONFIG_REPO/global/$f" "$CLAUDE_HOME/$f"
                    if check_placeholders "$CLAUDE_HOME/$f"; then
                        has_placeholders=true
                    fi
                    count=$((count + 1))
                fi
            fi
        done
    fi

    # --- Scripts ---
    if should_include "scripts" && [[ -d "$CONFIG_REPO/global/scripts" ]]; then
        for f in "$CONFIG_REPO/global/scripts"/*.sh; do
            [[ -f "$f" ]] || continue
            local fname
            fname=$(basename "$f")
            if [[ "$dry_run" == "true" ]]; then
                info "[dry-run] Would restore script: $fname"
            else
                cp -a "$f" "$CLAUDE_HOME/$fname"
                chmod +x "$CLAUDE_HOME/$fname"
                count=$((count + 1))
            fi
        done
    fi

    # --- User-level skills ---
    if should_include "skills" && [[ -d "$CONFIG_REPO/global/skills" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "[dry-run] Would restore user skills: $(ls "$CONFIG_REPO/global/skills/")"
        else
            mkdir -p "$CLAUDE_HOME/skills"
            cp -a "$CONFIG_REPO/global/skills/." "$CLAUDE_HOME/skills/"
            count=$(( count + $(find "$CONFIG_REPO/global/skills" -type f | wc -l) ))
        fi
    fi

    # --- Agents ---
    if should_include "agents" && [[ -d "$CONFIG_REPO/global/agents" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "[dry-run] Would restore agents"
        else
            mkdir -p "$CLAUDE_HOME/agents"
            cp -a "$CONFIG_REPO/global/agents/." "$CLAUDE_HOME/agents/"
            count=$(( count + $(find "$CONFIG_REPO/global/agents" -type f | wc -l) ))
        fi
    fi

    # --- Plugin references ---
    if should_include "plugins"; then
        mkdir -p "$CLAUDE_HOME/plugins"
        for f in installed_plugins.json known_marketplaces.json; do
            if [[ -f "$CONFIG_REPO/global/plugins/$f" ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    info "[dry-run] Would restore plugin ref: $f"
                else
                    cp -a "$CONFIG_REPO/global/plugins/$f" "$CLAUDE_HOME/plugins/$f"
                    count=$((count + 1))
                fi
            fi
        done
    fi

    # --- MCP config ---
    if should_include "mcp" && [[ -f "$CONFIG_REPO/global/mcp.json" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "[dry-run] Would restore MCP config"
        else
            cp -a "$CONFIG_REPO/global/mcp.json" "$CLAUDE_HOME/.mcp.json"
            if check_placeholders "$CLAUDE_HOME/.mcp.json"; then
                has_placeholders=true
            fi
            count=$((count + 1))
        fi
    fi

    # --- Project-level configs ---
    if should_include "projects" && [[ -d "$CONFIG_REPO/projects" ]]; then
        for project_dir in "$CONFIG_REPO/projects"/*/; do
            [[ -d "$project_dir" ]] || continue
            local slug
            slug=$(basename "$project_dir")
            info "Project: $slug"

            # Find matching project path
            local target_project=""
            while IFS= read -r p; do
                if [[ "$(project_slug "$p")" == "$slug" ]]; then
                    target_project="$p"
                    break
                fi
            done < <(discover_projects)

            if [[ -z "$target_project" ]]; then
                warn "  Project '$slug' not found locally — skipping (set CLAUDE_SYNC_PROJECTS to include it)"
                continue
            fi

            # Skills
            if should_include "skills" && [[ -d "$project_dir/skills" ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    info "  [dry-run] Would restore skills to $target_project/.claude/skills/"
                else
                    mkdir -p "$target_project/.claude/skills"
                    cp -a "$project_dir/skills/." "$target_project/.claude/skills/"
                    count=$((count + 1))
                fi
            fi

            # Memory
            if should_include "memory" && [[ -d "$project_dir/memory" ]]; then
                local encoded_name
                encoded_name=$(echo "$target_project" | sed 's/\//-/g;s/^-//')
                local mem_dest="$CLAUDE_HOME/projects/$encoded_name/memory"
                if [[ "$dry_run" == "true" ]]; then
                    info "  [dry-run] Would restore memory"
                else
                    mkdir -p "$mem_dest"
                    cp -a "$project_dir/memory/." "$mem_dest/"
                    count=$((count + 1))
                fi
            fi

            # CLAUDE.md
            if [[ -f "$project_dir/CLAUDE.md" ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    info "  [dry-run] Would restore .claude/CLAUDE.md"
                else
                    mkdir -p "$target_project/.claude"
                    cp -a "$project_dir/CLAUDE.md" "$target_project/.claude/CLAUDE.md"
                    count=$((count + 1))
                fi
            fi

            # MCP
            if should_include "mcp" && [[ -f "$project_dir/mcp.json" ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    info "  [dry-run] Would restore .mcp.json"
                else
                    cp -a "$project_dir/mcp.json" "$target_project/.mcp.json"
                    count=$((count + 1))
                fi
            fi
        done
    fi

    if [[ "$dry_run" == "true" ]]; then
        info "Dry run complete — no changes made."
    else
        ok "Imported $count files from $CONFIG_REPO"
        if [[ "$has_placeholders" == "true" ]]; then
            echo ""
            warn "Some files contain ${BOLD}$PLACEHOLDER${NC}"
            warn "Edit these files manually to add your API keys/tokens."
        fi
    fi
}

cmd_sync() {
    cmd_export
    cd "$CONFIG_REPO"
    local changes
    changes=$(git status --porcelain | wc -l)
    if [[ $changes -eq 0 ]]; then
        ok "Already up to date."
        return 0
    fi
    git add -A
    git commit -m "sync: $(date '+%Y-%m-%d %H:%M:%S')"
    if git remote get-url origin &>/dev/null; then
        git push
        ok "Pushed to remote."
    else
        warn "No remote configured. Run: cd $CONFIG_REPO && git remote add origin <url>"
    fi
}

cmd_diff() {
    ensure_config_repo
    # First export to staging area, then show git diff
    cmd_export 2>/dev/null
    cd "$CONFIG_REPO"
    git diff
    git diff --cached
    # Also show untracked
    git status --short
}

cmd_status() {
    ensure_config_repo
    header "Claude Code config status"

    echo ""
    echo "Global:"
    echo "  Settings:   $(ls "$CLAUDE_HOME"/settings*.json 2>/dev/null | wc -l) file(s)"
    echo "  Scripts:    $(ls "$CLAUDE_HOME"/*.sh 2>/dev/null | wc -l) file(s)"
    echo "  Skills:     $(ls -d "$CLAUDE_HOME"/skills/*/ 2>/dev/null | wc -l) skill(s)"
    echo "  Agents:     $(find "$CLAUDE_HOME/agents" -name "*.md" 2>/dev/null | wc -l) agent(s)"
    echo "  Plugins:    $(python3 -c "import json; d=json.load(open('$CLAUDE_HOME/plugins/installed_plugins.json')); print(len(d.get('plugins',{})))" 2>/dev/null || echo 0) installed"
    echo "  MCP:        $(test -f "$CLAUDE_HOME/.mcp.json" && echo "configured" || echo "none")"

    echo ""
    echo "Projects:"
    while IFS= read -r project_path; do
        [[ -z "$project_path" ]] && continue
        local slug
        slug=$(project_slug "$project_path")
        local skills=0 memory=0 claude_md="no"
        [[ -d "$project_path/.claude/skills" ]] && skills=$(ls -d "$project_path/.claude/skills"/*/ 2>/dev/null | wc -l)
        local encoded
        encoded=$(echo "$project_path" | sed 's/\//-/g')
        [[ -d "$CLAUDE_HOME/projects/$encoded/memory" ]] && memory=$(find "$CLAUDE_HOME/projects/$encoded/memory" -name "*.md" | wc -l)
        [[ -f "$project_path/.claude/CLAUDE.md" || -f "$project_path/CLAUDE.md" ]] && claude_md="yes"
        echo "  $slug: ${skills} skills, ${memory} memory files, CLAUDE.md: ${claude_md}"
    done < <(discover_projects)

    echo ""
    echo "Config repo: $CONFIG_REPO"
    if [[ -d "$CONFIG_REPO/.git" ]]; then
        echo "  Remote: $(cd "$CONFIG_REPO" && git remote get-url origin 2>/dev/null || echo 'none')"
        echo "  Last sync: $(cd "$CONFIG_REPO" && git log -1 --format='%ai' 2>/dev/null || echo 'never')"
    else
        echo "  Not initialized. Run 'claude-sync init'"
    fi
}

cmd_install_skill() {
    local skill_name="${1:-}"
    local target_path="${2:-}"
    local from_repo="${FROM_REPO:-$CONFIG_REPO}"

    if [[ -z "$skill_name" || -z "$target_path" ]]; then
        err "Usage: claude-sync install-skill <skill-name> <project-path>"
        exit 1
    fi

    # Resolve target
    target_path=$(realpath "$target_path" 2>/dev/null || echo "$target_path")

    if [[ ! -d "$target_path" ]]; then
        err "Project path does not exist: $target_path"
        exit 1
    fi

    # Search for the skill in config repo
    local skill_src=""

    # Check global skills
    if [[ -d "$from_repo/global/skills/$skill_name" ]]; then
        skill_src="$from_repo/global/skills/$skill_name"
    fi

    # Check project skills
    if [[ -z "$skill_src" ]]; then
        for pdir in "$from_repo/projects"/*/skills/"$skill_name"; do
            if [[ -d "$pdir" ]]; then
                skill_src="$pdir"
                break
            fi
        done
    fi

    # Also check live Claude dirs if config repo doesn't have it
    if [[ -z "$skill_src" && -d "$CLAUDE_HOME/skills/$skill_name" ]]; then
        skill_src="$CLAUDE_HOME/skills/$skill_name"
    fi

    if [[ -z "$skill_src" ]]; then
        err "Skill '$skill_name' not found in config repo or ~/.claude/skills/"
        info "Available skills:"
        cmd_list_skills
        exit 1
    fi

    local dest="$target_path/.claude/skills/$skill_name"
    mkdir -p "$dest"
    cp -a "$skill_src/." "$dest/"
    ok "Installed skill '$skill_name' → $dest"
    info "Files: $(find "$dest" -type f | wc -l)"
}

cmd_list_skills() {
    header "Available skills"

    echo ""
    echo "User-level (~/.claude/skills/):"
    if [[ -d "$CLAUDE_HOME/skills" ]]; then
        for d in "$CLAUDE_HOME/skills"/*/; do
            [[ -d "$d" ]] || continue
            echo "  - $(basename "$d")"
        done
    else
        echo "  (none)"
    fi

    echo ""
    echo "Project-level:"
    while IFS= read -r project_path; do
        [[ -z "$project_path" ]] && continue
        if [[ -d "$project_path/.claude/skills" ]]; then
            local slug
            slug=$(project_slug "$project_path")
            for d in "$project_path/.claude/skills"/*/; do
                [[ -d "$d" ]] || continue
                echo "  - $(basename "$d")  ($slug)"
            done
        fi
    done < <(discover_projects)

    # Also check config repo
    if [[ -d "$CONFIG_REPO" ]]; then
        echo ""
        echo "In config repo:"
        find "$CONFIG_REPO" -path "*/skills/*/SKILL.md" -o -path "*/skills/*/skill.md" 2>/dev/null | while read -r f; do
            local rel
            rel=${f#$CONFIG_REPO/}
            local sname
            sname=$(basename "$(dirname "$f")")
            echo "  - $sname  ($rel)"
        done
    fi
}

cmd_push() {
    ensure_config_repo
    cd "$CONFIG_REPO"
    git add -A
    local changes
    changes=$(git status --porcelain | wc -l)
    if [[ $changes -eq 0 ]]; then
        ok "Nothing to push."
        return 0
    fi
    git commit -m "sync: $(date '+%Y-%m-%d %H:%M:%S')"
    git push
    ok "Pushed."
}

cmd_pull() {
    ensure_config_repo
    cd "$CONFIG_REPO"
    git pull
    ok "Pulled latest config."
    info "Run 'claude-sync import' to apply changes."
}

cmd_version() {
    echo "claude-sync v${VERSION}"
}

# ---------- argument parsing ----------

ONLY=""
SKIP=""
DRY_RUN="false"
WITH_SECRETS="false"
FROM_REPO=""
COMMAND=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)         ONLY="$2"; shift 2 ;;
        --skip)         SKIP="$2"; shift 2 ;;
        --dry-run)      DRY_RUN="true"; shift ;;
        --with-secrets) WITH_SECRETS="true"; shift ;;
        --from)         FROM_REPO="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        -*)        err "Unknown option: $1"; usage; exit 1 ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND="$1"
            else
                ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

case "${COMMAND:-help}" in
    init)           cmd_init "${ARGS[@]+"${ARGS[@]}"}" ;;
    export)         cmd_export ;;
    import)         cmd_import ;;
    sync)           cmd_sync ;;
    diff)           cmd_diff ;;
    status)         cmd_status ;;
    install-skill)  cmd_install_skill "${ARGS[@]+"${ARGS[@]}"}" ;;
    list-skills)    cmd_list_skills ;;
    push)           cmd_push ;;
    pull)           cmd_pull ;;
    version)        cmd_version ;;
    help)           usage ;;
    *)              err "Unknown command: $COMMAND"; usage; exit 1 ;;
esac
