```
  ██████╗ ██████╗ ██╗     ██╗     ███████╗ ██████╗████████╗
 ██╔════╝██╔═══██╗██║     ██║     ██╔════╝██╔════╝╚══██╔══╝
 ██║     ██║   ██║██║     ██║     █████╗  ██║        ██║   
 ██║     ██║   ██║██║     ██║     ██╔══╝  ██║        ██║   
 ╚██████╗╚██████╔╝███████╗███████╗███████╗╚██████╗   ██║   
  ╚═════╝ ╚═════╝ ╚══════╝╚══════╝╚══════╝ ╚═════╝   ╚═╝   

 ██╗   ██╗███╗   ██╗██╗██╗  ██╗ █████╗ ██╗ █████╗ ██████╗ ████████╗███████╗
 ██║   ██║████╗  ██║██║╚██╗██╔╝██╔══██╗██║██╔══██╗██╔══██╗╚══██╔══╝██╔════╝
 ██║   ██║██╔██╗ ██║██║ ╚███╔╝ ███████║██║███████║██████╔╝   ██║   █████╗  
 ██║   ██║██║╚██╗██║██║ ██╔██╗ ██╔══██║██║██╔══██║██╔══██╗   ██║   ██╔══╝  
 ╚██████╔╝██║ ╚████║██║██╔╝ ██╗██║  ██║██║██║  ██║██║  ██║   ██║   ██║     
  ╚═════╝ ╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝   

  █████╗ ██╗     █████╗ ██████╗████████╗██╗███████╗ █████╗  ██████╗████████╗███████╗
 ██╔══██╗██║   ██╔══██╗██╔══██╗╚══██╔══╝██║██╔════╝██╔══██╗██╔════╝╚══██╔══╝██╔════╝
 ███████║██║   ███████║██████╔╝   ██║   ██║█████╗  ███████║██║        ██║   ███████╗ 
 ██╔══██║██║   ██╔══██║██╔══██╗   ██║   ██║██╔══╝  ██╔══██║██║        ██║   ╚════██║
 ██║  ██║██║   ██║  ██║██║  ██║   ██║   ██║██║     ██║  ██║╚██████╗   ██║   ███████║
 ╚═╝  ╚═╝╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝╚═╝     ╚═╝  ╚═╝ ╚═════╝   ╚═╝   ╚══════╝
```

> **IRFlow Timeline — AI Artifact Collector for Linux and macOS**  
> Rapidly collect AI assistant conversation artifacts from a user profile for forensic analysis in rapid incident response investigations.

---

## Supported AI Tools

| Tool | Artifact Location |
|------|-------------------|
| Claude Code CLI | `~/.claude/` |
| Claude Desktop | `~/Library/Application Support/Claude/` *(macOS)* / `~/.config/Claude/` *(Linux)* |
| OpenAI Codex CLI | `~/.codex/` |
| xAI Grok Build | `~/.grok/` |
| ChatGPT Desktop | `~/Library/Application Support/OpenAI/ChatGPT/` *(macOS)* / `~/.config/OpenAI/ChatGPT/` *(Linux)* |
| Gemini CLI | `~/.gemini/` |
| Antigravity CLI | `~/.gemini/antigravity-cli/` |
| Cursor | `~/.cursor/` + IDE User data |
| GitHub Copilot (VS Code) | VS Code `workspaceStorage` / `globalStorage` |
| GitHub Copilot CLI | `~/.copilot/` |
| Windsurf | `~/.config/Windsurf/User/` |
| Continue.dev | `~/.continue/` |

---

## Rapid Incident Response Procedure

### Phase 1 — Preparation (Before Deployment)

**Step 1 — Transfer the script to the target host**

Copy `Collect-UnixAIArtifacts.sh` to the target system. Use whatever channel is available: SCP, USB, shared drive, or your IR toolkit.

```bash
scp Collect-UnixAIArtifacts.sh investigator@target-host:/tmp/
```

**Step 2 — Make it executable**

```bash
chmod +x /tmp/Collect-UnixAIArtifacts.sh
```

---

### Phase 2 — Triage (Discovery Before Collecting)

**Step 3 — Run an inventory scan first (no files copied)**

Use `-i` to discover what AI artifacts exist on the system without touching or copying anything. This is a non-invasive first look — safe to run before deciding scope.

```bash
./Collect-UnixAIArtifacts.sh -i
```

Output will show every AI tool found and the paths where artifacts reside.

---

### Phase 3 — Collection

**Step 4a — Collect from the current user (default)**

Outputs to `~/Desktop/AI-Artifacts-<timestamp>/` automatically.

```bash
./Collect-UnixAIArtifacts.sh
```

**Step 4b — Collect to a specific output folder**

Point output to your IR evidence folder or a mounted forensic drive.

```bash
./Collect-UnixAIArtifacts.sh -o /media/ir-drive/evidence/AI-Case001
```

**Step 4c — Collect from a specific user profile**

Use `-p` when investigating another user's home directory or a mounted disk image.

```bash
# Specific user on a live system
./Collect-UnixAIArtifacts.sh -p /home/suspect -o /media/ir-drive/AI-suspect

# Mounted forensic image
./Collect-UnixAIArtifacts.sh -p /mnt/image/home/victim -o ~/case/AI
```

**Step 4d — Collect from ALL user profiles**

Requires `sudo` on Linux. Scans every home directory under `/home` (Linux) or `/Users` (macOS).

```bash
sudo ./Collect-UnixAIArtifacts.sh -a -o /media/ir-drive/AI-AllUsers
```

**Step 4e — Collect and compress immediately**

Add `-c` to automatically archive the output folder as `.tar.gz` after collection — ideal for exfil or chain-of-custody packaging.

```bash
./Collect-UnixAIArtifacts.sh -o ~/IRCase/AI -c
```

**Step 4f — Limit file size to avoid collecting large binaries**

Default max is 200 MB per file. Lower it if you need to stay under a transfer budget.

```bash
./Collect-UnixAIArtifacts.sh -m 50 -o ~/IRCase/AI
```

---

### Phase 4 — Analysis in IRFlow Timeline

**Step 5 — Load the collection into IRFlow Timeline**

1. Open **IRFlow Timeline**
2. Navigate to **Tools > Collect AI Artifacts**
3. Click **Browse folder**
4. Select the output folder (e.g. `AI-Artifacts-20250101-120000/`)
5. IRFlow reads `irflow-manifest.json` automatically and plots all conversation events on the timeline

The manifest files generated in every collection:

| File | Contents |
|------|----------|
| `irflow-manifest.json` | Machine-readable summary: sources, files, timestamps, errors |
| `irflow-manifest.txt` | Human-readable report: same data, plain text |

---

### Phase 5 — Packaging Evidence

**Step 6 — Archive for chain of custody**

If you did not use `-c` during collection, archive manually:

```bash
tar -czf AI-Case001-$(date +%Y%m%d).tar.gz -C /media/ir-drive/evidence AI-Case001/
sha256sum AI-Case001-$(date +%Y%m%d).tar.gz > AI-Case001-$(date +%Y%m%d).tar.gz.sha256
```

---

## All Options

```
Usage:
  chmod +x Collect-UnixAIArtifacts.sh
  ./Collect-UnixAIArtifacts.sh [OPTIONS]

Options:
  -o, --output-path <dir>      Output folder  (default: ~/Desktop/AI-Artifacts-<ts>)
  -p, --profile-path <dir>     Profile to collect from  (default: current user ~)
                               For mounted images: -p /mnt/disk/home/victim
  -a, --all-users              Scan all profiles under /home (Linux) or /Users (macOS)
  -c, --compress               Archive output as .tar.gz after collection
  -i, --inventory-only         Discover without copying files
  -m, --max-file-size-mb <n>   Skip files larger than n MB  (default: 200)
  -h, --help                   Show this help
```

---

## Quick Reference — IR Cheat Sheet

```
# Inventory only (no files copied)
./Collect-UnixAIArtifacts.sh -i

# Current user → Desktop
./Collect-UnixAIArtifacts.sh

# Specific output folder
./Collect-UnixAIArtifacts.sh -o /path/to/evidence

# Specific user profile
./Collect-UnixAIArtifacts.sh -p /home/suspect -o /path/to/evidence

# Mounted forensic image
./Collect-UnixAIArtifacts.sh -p /mnt/image/home/victim -o /path/to/evidence

# All users (requires sudo on Linux)
sudo ./Collect-UnixAIArtifacts.sh -a -o /path/to/evidence

# Collect + compress
./Collect-UnixAIArtifacts.sh -o /path/to/evidence -c

# Limit file size to 50 MB
./Collect-UnixAIArtifacts.sh -m 50 -o /path/to/evidence
```

---

## Requirements

- **Bash** 4.0+
- **Python 3** *(optional — required only for `irflow-manifest.json`; text report always written)*
- `find`, `cp`, `tar`, `hostname` *(standard on all Linux/macOS systems)*
- `sudo` *(required only for `-a` / `--all-users` on Linux)*

---

## Repository

[https://github.com/L3ndzsec/Collect-UnixAIArtifacts](https://github.com/L3ndzsec/Collect-UnixAIArtifacts)
