# codex-subagent

> [中文文档](./README.md) | Windows-First | Zero Hardcoding | Supports Antigravity (AGY), OpenAI Codex & DeepSeek Harness (DSH)

A standalone, portable wrapper that turns the local **OpenAI Codex CLI (`codex exec`)** into a sandboxed subagent and skill across **Antigravity (AGY)**, **OpenAI Codex**, and **DeepSeek Harness (DSH)** — with zero build steps and one-sentence AI installation.

## One-Sentence AI Installation

Paste either prompt into **AGY**, **Codex**, or **DSH**:

```text
Fetch and follow the instructions in https://raw.githubusercontent.com/minyun-code/codex-subagent/main/INSTALL.md to install codex-subagent for the current host.
```

Or clone-first (helpful behind restricted networks):

```text
Clone https://github.com/minyun-code/codex-subagent.git, read INSTALL.md, and install codex-subagent for the current host.
```

## Manual Installation (Windows PowerShell)

```powershell
git clone --depth 1 https://github.com/minyun-code/codex-subagent.git
cd codex-subagent

# Install for a specific host: agy | codex | dsh | all
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -Target agy

# Optional: persist a custom standalone codex.exe path into local.config.json
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -Target all -CodexBin "D:\path\to\codex.exe"
```

Use `-Link` during local development to install via NTFS Directory Junctions (no Administrator privileges required).

## Host Adapter Matrix

| Target Host | Native Package Type | Install Location | Notes |
| :--- | :--- | :--- | :--- |
| **Antigravity (AGY)** | Native Plugin | `~/.gemini/config/plugins/codex-subagent/` | Includes `plugin.json`, `agents/codex-subagent.md`, `skills/codex-subagent/`, and `rules/AGENTS.md`; passes `agy plugin validate --strict` |
| **OpenAI Codex** | Skill + Native TOML Subagent | `~/.codex/skills/codex-subagent/`<br>`~/.codex/agents/codex-subagent.toml` | Self-contained PowerShell runner + rendered TOML subagent pointing to the installed wrapper |
| **DeepSeek Harness (DSH)** | Zero-Build Skill | `~/.dsh/skills/codex-subagent/` | Pure `SKILL.md` + scripts; zero build, never mutates `cordis.patch.yml` |

## Key Features

- **Zero hardcoding & 4-tier binary discovery**: `-CodexBin` → `CODEX_SUBAGENT_BIN` / `CODEX_BIN` → `local.config.json` → `PATH` & common Windows locations. Prefers native `codex.exe` to avoid interfering with host Node.js / `nvm` versions.
- **Inherits user defaults**: Leaves model and reasoning effort unset by default so `~/.codex/config.toml` applies cleanly; override via flags, env vars, or `local.config.json`.
- **Task-tiered sandbox**: Defaults to `-Mode read-only`, allows `-Mode workspace-write` only when requested, enforces `approval_policy="never"`, and blocks `danger-full-access`.
- **Windows resilience**: UTF-8 no-BOM stdin transport, active Windows system proxy detection (`-Proxy` / `-NoProxy`), process-tree timeout termination (exit code `124`), and automatic `--skip-git-repo-check` outside Git repos.
- **Dry-run & diagnostics**: Built-in `-DryRun`, `scripts/doctor.ps1`, and offline `tests/smoke-test.ps1`.

## Diagnostics, Testing & Uninstall

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-test.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -Uninstall -Target agy
```

## License

[MIT License](./LICENSE)
