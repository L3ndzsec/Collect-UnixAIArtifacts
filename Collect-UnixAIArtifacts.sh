#!/usr/bin/env bash
# Collect-UnixAIArtifacts.sh
# IRFlow Timeline — AI Artifact Collector for Linux and macOS
# 
#
# Collects AI assistant conversation artifacts from a user profile for forensic
# analysis in IRFlow Timeline (Tools > Collect AI Artifacts > Browse folder).
#
# Supported tools:
#   Claude Code CLI / Desktop, OpenAI Codex CLI, xAI Grok Build,
#   ChatGPT Desktop, Gemini CLI, Antigravity CLI (agy),
#   Cursor, GitHub Copilot (VS Code + CLI), Windsurf, Continue.dev
#
# Usage:
#   chmod +x Collect-AIArtifacts.sh
#   ./Collect-AIArtifacts.sh [OPTIONS]
#
# Options:
#   -o, --output-path <dir>      Output folder  (default: ~/Desktop/AI-Artifacts-<ts>)
#   -p, --profile-path <dir>     Profile to collect from  (default: current user ~)
#                                For mounted images: -p /mnt/disk/home/victim
#   -a, --all-users              Scan all profiles under /home (Linux) or /Users (macOS)
#   -c, --compress               Archive output as .tar.gz after collection
#   -i, --inventory-only         Discover without copying files
#   -m, --max-file-size-mb <n>   Skip files larger than n MB  (default: 200)
#   -h, --help                   Show this help
#
# Examples:
#   ./Collect-UnixAIArtifacts.sh
#       Collect from the current user; output to Desktop.
#
#   ./Collect-UnixAIArtifacts.sh -o ~/IRCase/AI -c
#       Collect and compress to ~/IRCase/AI.tar.gz
#
#   ./Collect-UnixAIArtifacts.sh -p /mnt/image/home/victim -o ~/case/AI
#       Collect from a mounted image user profile.
#
#   sudo ./Collect-UnixAIArtifacts.sh -a -o ~/IRCase/AI
#       Scan every user profile (root required on Linux).

set -uo pipefail

OS="$(uname -s)"   # Darwin | Linux

# ── Defaults ──────────────────────────────────────────────────────────────────
OUTPUT_PATH=""
PROFILE_PATH=""
ALL_USERS=0
COMPRESS=0
INVENTORY_ONLY=0
MAX_FILE_SIZE_MB=200

# ── Global counters (modified by collect_tree; must not be called in subshells) ──
COLLECTED=0
SKIPPED_SIZE=0
COL_ERRORS=0
LAST_COLLECT_COUNT=0
START_TIME=$(date +%s)

# Temp files for manifest data (populated during collection)
ROOTS_FILE=""
FILES_FILE=""

# ── Colour helpers ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    CC='\033[0;36m'; CG='\033[0;32m'; CY='\033[0;33m'
    CD='\033[0;90m'; CR='\033[0m'
else
    CC=''; CG=''; CY=''; CD=''; CR=''
fi

write_banner() {
    printf "\n${CC}  +------------------------------------------------------+\n"
    printf     "  |   IRFlow Timeline - AI Artifact Collector            |\n"
    printf   "${CD}  |   https://github.com/L3ndzsec                        |${CR}\n"
    printf   "${CC}  +------------------------------------------------------+${CR}\n\n"
}
write_section() {
    local pad; pad=$(printf '%*s' $(( 54 - ${#1} )) '' | tr ' ' '-')
    printf "\n${CC}  -- %s %s${CR}\n" "$1" "$pad"
}
write_found() { printf "${CG}  [+] %s${CR}\n" "$1"; }
write_info()  { printf "${CD}  [.] %s${CR}\n" "$1"; }
write_warn()  { printf "${CY}  [!] %s${CR}\n" "$1"; }
write_miss()  { printf "${CD}  [-] %s${CR}\n" "$1"; }

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-path)      OUTPUT_PATH="$2";      shift 2 ;;
        -p|--profile-path)     PROFILE_PATH="$2";     shift 2 ;;
        -a|--all-users)        ALL_USERS=1;            shift   ;;
        -c|--compress)         COMPRESS=1;             shift   ;;
        -i|--inventory-only)   INVENTORY_ONLY=1;       shift   ;;
        -m|--max-file-size-mb) MAX_FILE_SIZE_MB="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,2\}//; s/^#//'; exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
done

MAX_BYTES=$(( MAX_FILE_SIZE_MB * 1024 * 1024 ))

# ── Portable helpers ───────────────────────────────────────────────────────────

file_size() {
    if [[ "$OS" == "Darwin" ]]; then
        stat -f%z "$1" 2>/dev/null || echo 0
    else
        stat -c%s "$1" 2>/dev/null || echo 0
    fi
}

file_mtime_iso() {
    if [[ "$OS" == "Darwin" ]]; then
        stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" "$1" 2>/dev/null || echo ""
    else
        local epoch; epoch=$(stat -c%Y "$1" 2>/dev/null) || echo ""; echo ""
        [[ -n "$epoch" ]] && date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo ""
    fi
}

iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

make_absolute() {
    local p="$1"
    case "$p" in
        /*) echo "$p" ;;
        ~/*) echo "$HOME/${p#~/}" ;;
        *) echo "$(pwd)/$p" ;;
    esac
}

# macOS: ~/Library/Application Support/<app>
# Linux: ~/.config/<app>  (respects XDG_CONFIG_HOME only for the current user)
get_app_data_dir() {
    local app="$1" home="$2"
    if [[ "$OS" == "Darwin" ]]; then
        echo "$home/Library/Application Support/$app"
    else
        echo "$home/.config/$app"
    fi
}

# ── Manifest helpers ───────────────────────────────────────────────────────────

add_root() {
    # add_root <tool> <label> <path>
    local tool="$1" label="$2" rpath="${3//\"/\\\"}"
    printf '{"tool":"%s","label":"%s","path":"%s"}\n' "$tool" "$label" "$rpath" >> "$ROOTS_FILE"
}

append_file_row() {
    printf '%s\n' "$1" >> "$FILES_FILE"
}

# ── collect_tree ───────────────────────────────────────────────────────────────
# Recursively collect files matching glob patterns from src into dest.
# Sets LAST_COLLECT_COUNT to the number of matched files.
# Modifies COLLECTED, SKIPPED_SIZE, COL_ERRORS, FILES_FILE.
# MUST be called directly (not in a subshell) to preserve those global side-effects.
#
# Usage: collect_tree <src> <dest> <tool> <pat1> [<pat2> ...]
collect_tree() {
    local src="$1" dest="$2" tool="$3"
    shift 3
    LAST_COLLECT_COUNT=0
    if [[ ! -d "$src" ]]; then return; fi

    # Build the -name expression for find
    local find_name_args=()
    local first=1
    local ext
    for ext in "$@"; do
        [[ $first -eq 0 ]] && find_name_args+=( "-o" )
        find_name_args+=( "-iname" "$ext" )
        first=0
    done
    if [[ ${#find_name_args[@]} -eq 0 ]]; then return; fi

    local file size mtime rel dst_file dst_dir
    while IFS= read -r -d '' file; do
        [[ -L "$file" ]] && continue   # skip symlinks

        size=$(file_size "$file")
        if (( size > MAX_BYTES )); then
            local mb=$(( size / 1024 / 1024 ))
            write_warn "Skipping large file (${mb} MB): $(basename "$file")"
            SKIPPED_SIZE=$(( SKIPPED_SIZE + 1 ))
            append_file_row "{\"tool\":\"$tool\",\"status\":\"skipped-size\",\"source\":\"${file//\"/\\\"}\",\"size\":$size}"
            continue
        fi

        LAST_COLLECT_COUNT=$(( LAST_COLLECT_COUNT + 1 ))

        if [[ $INVENTORY_ONLY -eq 0 ]]; then
            rel="${file#$src/}"
            dst_file="$dest/$rel"
            dst_dir="$(dirname "$dst_file")"
            if mkdir -p "$dst_dir" && cp "$file" "$dst_file" 2>/dev/null; then
                COLLECTED=$(( COLLECTED + 1 ))
                mtime=$(file_mtime_iso "$file")
                append_file_row "{\"tool\":\"$tool\",\"status\":\"collected\",\"source\":\"${file//\"/\\\"}\",\"dest\":\"${dst_file//\"/\\\"}\",\"size\":$size,\"modified\":\"$mtime\"}"
            else
                COL_ERRORS=$(( COL_ERRORS + 1 ))
                append_file_row "{\"tool\":\"$tool\",\"status\":\"error\",\"source\":\"${file//\"/\\\"}\"}  "
            fi
        fi
    done < <(find "$src" -maxdepth 20 -not -type l -type f \( "${find_name_args[@]}" \) -print0 2>/dev/null)
}

# ── Per-tool collectors ────────────────────────────────────────────────────────

collect_claude_code() {
    local home="$1" out_base="$2"

    # CLI: ~/.claude/
    local cli_root="$home/.claude"
    if [[ -f "$cli_root/history.jsonl" ]] || [[ -d "$cli_root/projects" ]]; then
        write_found "Claude Code CLI: $cli_root"
        add_root "claude-code" "Claude Code CLI" "$cli_root"
        collect_tree "$cli_root" "$out_base/claude-code-cli" "claude-code" \
            "*.jsonl" "*.json" "*.md"
        write_info "  $LAST_COLLECT_COUNT file(s) matched (CLI)"
    else
        write_miss "Claude Code CLI (~/.claude/) - not found"
    fi

    # Desktop: ~/Library/Application Support/Claude/  (macOS)
    #          ~/.config/Claude/                       (Linux)
    local desktop_base; desktop_base=$(get_app_data_dir "Claude" "$home")
    local has_desktop=0
    local sdir
    for sdir in "claude-code-sessions" "local-agent-mode-sessions"; do
        [[ -d "$desktop_base/$sdir" ]] && has_desktop=1 && break
    done
    if [[ $has_desktop -eq 1 ]]; then
        write_found "Claude Desktop: $desktop_base"
        add_root "claude-code" "Claude Desktop" "$desktop_base"
        collect_tree "$desktop_base" "$out_base/claude-desktop" "claude-code" \
            "*.jsonl" "*.json" "*.md"
        write_info "  $LAST_COLLECT_COUNT file(s) matched (Desktop)"
    else
        write_miss "Claude Desktop - not found"
    fi
}

collect_codex() {
    local home="$1" out_base="$2"
    local codex_home="${CODEX_HOME:-$home/.codex}"
    if [[ ! -f "$codex_home/history.jsonl" ]] && [[ ! -d "$codex_home/sessions" ]]; then
        write_miss "OpenAI Codex (~/.codex/) - not found"; return
    fi
    write_found "OpenAI Codex: $codex_home"
    add_root "codex" "OpenAI Codex" "$codex_home"
    collect_tree "$codex_home" "$out_base/codex" "codex" \
        "*.jsonl" "*.json" "*.md" "*.toml" \
        "*.sqlite" "*.sqlite-wal" "*.sqlite-shm" \
        "*.db" "*.db-wal" "*.db-shm"
    write_info "  $LAST_COLLECT_COUNT file(s) matched"
}

collect_grok_build() {
    local home="$1" out_base="$2"
    local grok_home="${GROK_HOME:-$home/.grok}"
    if [[ ! -d "$grok_home/sessions" ]]; then
        write_miss "xAI Grok Build (~/.grok/) - not found"; return
    fi
    write_found "xAI Grok Build: $grok_home"
    add_root "grok-build" "Grok Build" "$grok_home"
    collect_tree "$grok_home" "$out_base/grok-build" "grok-build" \
        "*.jsonl" "*.json" "*.md" "*.yaml" "*.yml"
    write_info "  $LAST_COLLECT_COUNT file(s) matched"
}

collect_gemini_cli() {
    local home="$1" out_base="$2"
    local gemini_home="$home/.gemini"
    if [[ ! -d "$gemini_home/tmp" ]]; then
        write_miss "Gemini CLI (~/.gemini/tmp/) - not found"; return
    fi
    write_found "Gemini CLI: $gemini_home"
    add_root "gemini-cli" "Gemini CLI" "$gemini_home"
    collect_tree "$gemini_home" "$out_base/gemini-cli" "gemini-cli" \
        "*.jsonl" "*.json" "shell_history" "logs.json"
    write_info "  $LAST_COLLECT_COUNT file(s) matched"
}

collect_antigravity_cli() {
    local home="$1" out_base="$2"
    local ag_root="$home/.gemini/antigravity-cli"
    if [[ ! -d "$ag_root" ]]; then
        write_miss "Antigravity CLI (~/.gemini/antigravity-cli/) - not found"; return
    fi
    write_found "Antigravity CLI: $ag_root"
    add_root "antigravity-cli" "Antigravity CLI" "$ag_root"
    collect_tree "$ag_root" "$out_base/antigravity-cli" "antigravity-cli" \
        "*.jsonl" "*.json" "*.db" "*.db-wal" "*.db-shm"
    write_info "  $LAST_COLLECT_COUNT file(s) matched"
}

collect_cursor() {
    local home="$1" out_base="$2"

    # Agent transcripts: ~/.cursor/projects/
    local cursor_home="${CURSOR_AGENT_HOME:-${CURSOR_HOME:-$home/.cursor}}"
    if [[ -d "$cursor_home/projects" ]]; then
        write_found "Cursor agent transcripts: $cursor_home"
        add_root "cursor" "Cursor (agent)" "$cursor_home"
        collect_tree "$cursor_home" "$out_base/cursor-agent" "cursor" \
            "*.jsonl" "*.json" "*.db" "*.db-wal" "*.db-shm" \
            "*.vscdb" "*.vscdb-wal" "*.vscdb-shm"
        write_info "  $LAST_COLLECT_COUNT file(s) matched (agent)"
    else
        write_miss "Cursor agent transcripts (~/.cursor/projects/) - not found"
    fi

    # IDE conversation DB:
    #   macOS: ~/Library/Application Support/Cursor/User/
    #   Linux: ~/.config/Cursor/User/
    local cursor_user; cursor_user=$(get_app_data_dir "Cursor/User" "$home")
    if [[ -d "$cursor_user" ]]; then
        write_found "Cursor IDE data: $cursor_user"
        add_root "cursor" "Cursor IDE" "$cursor_user"
        collect_tree "$cursor_user" "$out_base/cursor-ide" "cursor" \
            "conversation-search.db" "conversation-search.db-wal" \
            "conversation-search.db-shm" \
            "*.vscdb" "*.vscdb-wal" "*.vscdb-shm" \
            "*.json" "*.jsonl"
        write_info "  $LAST_COLLECT_COUNT file(s) matched (IDE)"
    else
        write_miss "Cursor IDE data - not found"
    fi
}

collect_chatgpt() {
    local home="$1" out_base="$2"
    local found=0
    local dir safe_name

    if [[ "$OS" == "Darwin" ]]; then
        # macOS: Electron app or sandboxed container
        for dir in \
            "$home/Library/Application Support/OpenAI/ChatGPT" \
            "$home/Library/Containers/com.openai.chat/Data/Library/Application Support/OpenAI/ChatGPT" \
            "$home/Library/Containers/com.openai.chat"; do
            if [[ -d "$dir" ]]; then
                write_found "ChatGPT Desktop: $dir"
                add_root "chatgpt" "ChatGPT Desktop" "$dir"
                safe_name=$(basename "$dir" | tr ' ' '-' | tr -dc 'a-zA-Z0-9-')
                collect_tree "$dir" "$out_base/chatgpt-$safe_name" "chatgpt" \
                    "*.db" "*.sqlite" "*.sqlite-wal" "*.sqlite-shm" \
                    "CURRENT" "MANIFEST-*" "*.ldb" "*.sst" "*.log" "*.json"
                write_info "  $LAST_COLLECT_COUNT file(s) matched"
                found=$(( found + 1 ))
            fi
        done
    else
        # Linux: XDG config/data paths (no official native app; covers Electron builds)
        for dir in \
            "$home/.config/OpenAI/ChatGPT" \
            "$home/.local/share/OpenAI/ChatGPT" \
            "$home/.config/ChatGPT" \
            "$home/.local/share/ChatGPT"; do
            if [[ -d "$dir" ]]; then
                write_found "ChatGPT Desktop: $dir"
                add_root "chatgpt" "ChatGPT Desktop" "$dir"
                safe_name=$(basename "$dir" | tr ' ' '-' | tr -dc 'a-zA-Z0-9-')
                collect_tree "$dir" "$out_base/chatgpt-$safe_name" "chatgpt" \
                    "*.db" "*.sqlite" "*.sqlite-wal" "*.sqlite-shm" \
                    "CURRENT" "MANIFEST-*" "*.ldb" "*.sst" "*.log" "*.json"
                write_info "  $LAST_COLLECT_COUNT file(s) matched"
                found=$(( found + 1 ))
            fi
        done
    fi

    [[ $found -eq 0 ]] && write_miss "ChatGPT Desktop - not found"
}

collect_copilot_vscode() {
    local home="$1" out_base="$2"
    local any_found=0
    local prod user_dir ws_root global_empty has_chat safe_name ws_entry

    local products=("Code" "Code - Insiders" "VSCodium" "VSCodium - Insiders")
    for prod in "${products[@]}"; do
        if [[ "$OS" == "Darwin" ]]; then
            user_dir="$home/Library/Application Support/$prod/User"
        else
            user_dir="$home/.config/$prod/User"
        fi

        ws_root="$user_dir/workspaceStorage"
        global_empty="$user_dir/globalStorage/emptyWindowChatSessions"
        [[ -d "$ws_root" ]] || [[ -d "$global_empty" ]] || continue

        # Validate: at least one workspace or emptyWindow with chatSessions
        has_chat=0
        [[ -d "$global_empty" ]] && has_chat=1
        if [[ $has_chat -eq 0 ]] && [[ -d "$ws_root" ]]; then
            while IFS= read -r -d '' ws_entry; do
                if [[ -d "$ws_entry/chatSessions" ]]; then
                    has_chat=1; break
                fi
            done < <(find "$ws_root" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
        fi
        [[ $has_chat -eq 0 ]] && continue

        write_found "GitHub Copilot ($prod): $user_dir"
        add_root "copilot" "Copilot ($prod)" "$user_dir"
        safe_name=$(printf '%s' "$prod" | tr ' ' '-' | tr -dc 'a-zA-Z0-9-')

        collect_tree "$ws_root" "$out_base/copilot-$safe_name-workspaceStorage" "copilot" \
            "*.json" "*.jsonl" "*.db" "*.db-wal" "*.db-shm"
        write_info "  $LAST_COLLECT_COUNT file(s) matched (workspaceStorage)"

        if [[ -d "$global_empty" ]]; then
            collect_tree "$global_empty" "$out_base/copilot-$safe_name-emptyWindow" "copilot" \
                "*.json" "*.jsonl"
            write_info "  $LAST_COLLECT_COUNT file(s) matched (emptyWindowChatSessions)"
        fi
        any_found=$(( any_found + 1 ))
    done

    [[ $any_found -eq 0 ]] && write_miss "GitHub Copilot (VS Code) - no chatSessions found"
}

collect_copilot_cli() {
    local home="$1" out_base="$2"
    local copilot_home="${COPILOT_HOME:-$home/.copilot}"
    if [[ ! -d "$copilot_home/session-state" ]] && [[ ! -f "$copilot_home/session-store.db" ]]; then
        write_miss "GitHub Copilot CLI (~/.copilot/) - not found"; return
    fi
    write_found "GitHub Copilot CLI: $copilot_home"
    add_root "copilot" "Copilot CLI" "$copilot_home"
    collect_tree "$copilot_home" "$out_base/copilot-cli" "copilot" \
        "*.jsonl" "*.json" "*.yaml" "*.yml" "*.md" \
        "*.db" "*.db-wal" "*.db-shm"
    write_info "  $LAST_COLLECT_COUNT file(s) matched"
}

collect_windsurf() {
    local home="$1" out_base="$2"
    local ws_user; ws_user=$(get_app_data_dir "Windsurf/User" "$home")
    if [[ ! -d "$ws_user" ]]; then
        write_miss "Windsurf - not found"; return
    fi
    write_found "Windsurf: $ws_user"
    add_root "windsurf" "Windsurf" "$ws_user"
    collect_tree "$ws_user" "$out_base/windsurf" "windsurf" \
        "*.vscdb" "*.vscdb-wal" "*.vscdb-shm" \
        "*.db" "*.db-wal" "*.db-shm" "*.json" "*.jsonl"
    write_info "  $LAST_COLLECT_COUNT file(s) matched"
}

collect_continue_dev() {
    local home="$1" out_base="$2"
    local continue_home="${CONTINUE_GLOBAL_DIR:-$home/.continue}"
    if [[ ! -d "$continue_home/sessions" ]]; then
        write_miss "Continue.dev (~/.continue/) - not found"; return
    fi
    write_found "Continue.dev: $continue_home"
    add_root "continue" "Continue.dev" "$continue_home"
    collect_tree "$continue_home" "$out_base/continue" "continue" \
        "*.json" "*.jsonl" "*.yaml" "*.yml"
    write_info "  $LAST_COLLECT_COUNT file(s) matched"
}

# ── Manifest ───────────────────────────────────────────────────────────────────

write_manifest() {
    local out_dir="$1" profile_label="$2" computer_name="$3"
    local end_time; end_time=$(date +%s)
    local elapsed=$(( end_time - START_TIME ))
    local collected_at; collected_at=$(iso_now)
    local root_count; root_count=$(wc -l < "$ROOTS_FILE" 2>/dev/null | tr -d ' ')

    # JSON manifest (requires python3 — skipped with a warning if absent)
    local json_path="$out_dir/irflow-manifest.json"
    if command -v python3 &>/dev/null; then
        IRFLOW_OUT="$json_path" \
        IRFLOW_ROOTS="$ROOTS_FILE" \
        IRFLOW_FILES="$FILES_FILE" \
        IRFLOW_HOST="$computer_name" \
        IRFLOW_PROFILE="$profile_label" \
        IRFLOW_ELAPSED="$elapsed" \
        IRFLOW_COLLECTED="$COLLECTED" \
        IRFLOW_SKIPPED="$SKIPPED_SIZE" \
        IRFLOW_ERRORS="$COL_ERRORS" \
        IRFLOW_MAXMB="$MAX_FILE_SIZE_MB" \
        IRFLOW_TS="$collected_at" \
        python3 << 'PYEOF'
import json, os

def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line:
                    try: rows.append(json.loads(line))
                    except Exception: pass
    except Exception: pass
    return rows

e = os.environ
sources = read_jsonl(e['IRFLOW_ROOTS'])
files   = read_jsonl(e['IRFLOW_FILES'])

summary = {
    'collectedAt':      e['IRFLOW_TS'],
    'collectionHost':   e['IRFLOW_HOST'],
    'profileLabel':     e['IRFLOW_PROFILE'],
    'elapsedSeconds':   int(e['IRFLOW_ELAPSED']),
    'filesCollected':   int(e['IRFLOW_COLLECTED']),
    'filesSkippedSize': int(e['IRFLOW_SKIPPED']),
    'errors':           int(e['IRFLOW_ERRORS']),
    'maxFileSizeMB':    int(e['IRFLOW_MAXMB']),
    'sourcesFound':     len(sources),
    'sources':          sources,
    'files':            files,
}

with open(e['IRFLOW_OUT'], 'w', encoding='utf-8') as f:
    json.dump(summary, f, indent=2, ensure_ascii=False)
PYEOF
    else
        write_warn "python3 not found — irflow-manifest.json skipped (text report still written)"
    fi

    # Text report (always written, no dependencies)
    local txt_path="$out_dir/irflow-manifest.txt"
    {
        echo "IRFlow Timeline - AI Artifact Collection Report"
        echo "================================================"
        echo "Collected : $collected_at"
        echo "Host      : $computer_name"
        echo "Profile   : $profile_label"
        echo "Elapsed   : ${elapsed}s"
        echo ""
        echo "  Files collected  : $COLLECTED"
        echo "  Files skipped    : $SKIPPED_SIZE (exceeded $MAX_FILE_SIZE_MB MB limit)"
        echo "  Copy errors      : $COL_ERRORS"
        echo ""
        echo "Artifact sources found ($root_count):"
        if command -v python3 &>/dev/null && [[ -s "$ROOTS_FILE" ]]; then
            python3 - "$ROOTS_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                r = json.loads(line)
                print("  [%-16s]  %s" % (r.get('tool',''), r.get('label','')))
                print("                          %s" % r.get('path',''))
            except Exception: pass
except Exception: pass
PYEOF
        else
            cat "$ROOTS_FILE" 2>/dev/null || true
        fi
        [[ "${root_count:-0}" -eq 0 ]] && echo "  (none - no AI artifacts detected at standard paths)"
        echo ""
        echo "Load into IRFlow Timeline:"
        echo "  Tools > Collect AI Artifacts > 'Browse folder' > select this folder."
    } > "$txt_path"

    echo "$txt_path"
}

# ── Resolve user profiles ──────────────────────────────────────────────────────

resolve_profiles() {
    if [[ $ALL_USERS -eq 1 ]]; then
        local users_base
        if [[ -n "$PROFILE_PATH" ]]; then
            users_base="$(dirname "$(make_absolute "$PROFILE_PATH")")"
        elif [[ "$OS" == "Darwin" ]]; then
            users_base="/Users"
        else
            users_base="/home"
        fi
        if [[ -d "$users_base" ]]; then
            find "$users_base" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null \
                | while IFS= read -r -d '' dir; do
                    local name; name=$(basename "$dir")
                    [[ "$name" =~ ^(Shared|Guest|Public|Nobody|root|daemon|nobody)$ ]] && continue
                    echo "$dir"
                done
        fi
    elif [[ -n "$PROFILE_PATH" ]]; then
        make_absolute "$PROFILE_PATH"
    else
        echo "$HOME"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

write_banner

# Default output path
if [[ -z "$OUTPUT_PATH" ]]; then
    local_ts=$(date +%Y%m%d-%H%M%S)
    if [[ "$OS" == "Darwin" ]]; then
        OUTPUT_PATH="$HOME/Desktop/AI-Artifacts-$local_ts"
    else
        desktop_dir="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
        if [[ -d "$desktop_dir" ]]; then
            OUTPUT_PATH="$desktop_dir/AI-Artifacts-$local_ts"
        else
            OUTPUT_PATH="$HOME/AI-Artifacts-$local_ts"
        fi
    fi
fi
OUTPUT_PATH=$(make_absolute "$OUTPUT_PATH")

# Temp files for manifest data
ROOTS_FILE=$(mktemp /tmp/irflow-roots-XXXXXX.jsonl)
FILES_FILE=$(mktemp /tmp/irflow-files-XXXXXX.jsonl)
trap 'rm -f "$ROOTS_FILE" "$FILES_FILE"' EXIT

if [[ $INVENTORY_ONLY -eq 1 ]]; then
    printf "  Mode: INVENTORY ONLY (no files will be copied)\n\n"
else
    mkdir -p "$OUTPUT_PATH"
    write_info "Output folder: $OUTPUT_PATH"
fi

# Collect profiles into an array (avoid subshell variable loss)
profiles=()
while IFS= read -r profile_root; do
    [[ -n "$profile_root" ]] && profiles+=("$profile_root")
done < <(resolve_profiles)

profile_count=${#profiles[@]}
if [[ $profile_count -eq 0 ]]; then
    write_warn "No profiles found to scan."; exit 1
fi

for profile_root in "${profiles[@]}"; do
    user_name=$(basename "$profile_root")
    if [[ $profile_count -gt 1 ]]; then
        out_base="$OUTPUT_PATH/$user_name"
    else
        out_base="$OUTPUT_PATH"
    fi

    write_section "Profile: $user_name  ($profile_root)"

    collect_claude_code     "$profile_root" "$out_base"
    collect_codex           "$profile_root" "$out_base"
    collect_grok_build      "$profile_root" "$out_base"
    collect_gemini_cli      "$profile_root" "$out_base"
    collect_antigravity_cli "$profile_root" "$out_base"
    collect_cursor          "$profile_root" "$out_base"
    collect_chatgpt         "$profile_root" "$out_base"
    collect_copilot_vscode  "$profile_root" "$out_base"
    collect_copilot_cli     "$profile_root" "$out_base"
    collect_windsurf        "$profile_root" "$out_base"
    collect_continue_dev    "$profile_root" "$out_base"
done

# ── Final report ───────────────────────────────────────────────────────────────

write_section "Collection complete"
end_time=$(date +%s)
elapsed=$(( end_time - START_TIME ))

if [[ $INVENTORY_ONLY -eq 0 ]]; then
    computer_name=$(hostname -s 2>/dev/null || hostname)
    profile_label=$(printf '%s ' "${profiles[@]}")
    txt_path=$(write_manifest "$OUTPUT_PATH" "$profile_label" "$computer_name")

    write_found "Files collected : $COLLECTED"
    [[ $SKIPPED_SIZE -gt 0 ]] && write_warn "Files skipped   : $SKIPPED_SIZE (size limit)"
    [[ $COL_ERRORS   -gt 0 ]] && write_warn "Copy errors     : $COL_ERRORS"
    write_info "Elapsed         : ${elapsed}s"
    write_info "Manifest        : $txt_path"
    printf "\n  ${CC}Output folder: %s${CR}\n" "$OUTPUT_PATH"

    if [[ $COMPRESS -eq 1 ]] && [[ $COLLECTED -gt 0 ]]; then
        archive="$OUTPUT_PATH.tar.gz"
        write_info "Compressing to $archive ..."
        if tar -czf "$archive" -C "$(dirname "$OUTPUT_PATH")" "$(basename "$OUTPUT_PATH")" 2>/dev/null; then
            archive_mb=$(( $(wc -c < "$archive" 2>/dev/null || echo 0) / 1024 / 1024 ))
            write_found "Archive: $archive  (${archive_mb} MB)"
        else
            write_warn "Compression failed"
        fi
    fi

    printf "\n  ${CG}To analyse: IRFlow Timeline > Tools > Collect AI Artifacts > 'Browse folder'${CR}\n"
    printf   "  ${CG}            then select: %s${CR}\n" "$OUTPUT_PATH"
else
    root_count=$(wc -l < "$ROOTS_FILE" 2>/dev/null | tr -d ' ')
    printf "\n  ${CC}Sources found (%s):${CR}\n" "${root_count:-0}"
    if command -v python3 &>/dev/null && [[ -s "$ROOTS_FILE" ]]; then
        python3 - "$ROOTS_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                r = json.loads(line)
                print("  [+] %-28s %s" % (r.get('label',''), r.get('path','')))
            except Exception: pass
except Exception: pass
PYEOF
    fi
    [[ "${root_count:-0}" -eq 0 ]] && write_miss "No AI artifacts detected at standard paths."
    write_info "Elapsed: ${elapsed}s"
fi

printf "\n"
