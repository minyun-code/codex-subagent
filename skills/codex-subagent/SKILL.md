---
name: codex-subagent
description: >-
  Use this skill when delegating complex coding, refactoring, debugging, or deep
  code review tasks to the local OpenAI Codex CLI (codex exec) in an isolated
  sandboxed context on Windows, or when resuming a Codex thread and diagnosing
  Codex CLI setup.
---

# Codex Subagent Runbook

将编码、重构、调试或深度代码审查任务委派给本地 OpenAI Codex CLI（`codex exec`）。本技能自带零硬编码的 Windows PowerShell 包装脚本 [scripts/invoke-codex.cmd](./scripts/invoke-codex.cmd)，自动发现本地 `codex.exe`（优先使用原生二进制，不依赖/不改动宿主机 Node.js 版本）并复用 `~/.codex` 登录态与 `config.toml` 默认模型配置。

## Preferred Execution Path

- 在 **Antigravity (AGY)** 中：优先通过 `invoke_subagent` 调用 `TypeName: "codex-subagent"`，让冗长日志隔离在子会话上下文中，并支持并行委派。
- 在 **Codex / DeepSeek Harness (DSH)** 或命令行中：直接调用当前 `SKILL.md` 同目录下的 [scripts/invoke-codex.cmd](./scripts/invoke-codex.cmd)（或 `scripts/invoke-codex.ps1`）。

### Locate Wrapper Script Dynamically

不要硬编码盘符或用户名。按当前宿主解析 `invoke-codex.cmd` 路径（优先取当前 `SKILL.md` 所在目录的 `scripts\invoke-codex.cmd`）：

```powershell
$runner = @(
  (Join-Path $HOME '.gemini\config\plugins\codex-subagent\skills\codex-subagent\scripts\invoke-codex.cmd'),
  (Join-Path $HOME '.codex\skills\codex-subagent\scripts\invoke-codex.cmd'),
  (Join-Path $HOME '.dsh\skills\codex-subagent\scripts\invoke-codex.cmd')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
```

## Wrapper Parameters (`invoke-codex.cmd`)

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `-WorkDir <path>` | 当前目录 | 目标工作区路径（`-C`）。非 Git 目录自动附加 `--skip-git-repo-check`。 |
| `-Mode <read-only\|workspace-write>` | `read-only` | 沙箱边界。强制禁止 `danger-full-access`，始终注入 `approval_policy="never"`。 |
| `-Prompt <string>` | — | 单行短提示词（经 UTF-8 stdin 传入）；传 `-` 或搭配 `-Stdin` 可从管道读取。 |
| `-PromptFile <path>` | — | 多行或中文提示词推荐方式（UTF-8 无 BOM 文件）。 |
| `-Model <name>` | 继承 `~/.codex/config.toml` | 可选模型覆盖（`-m`）；也可通过环境变量 `CODEX_SUBAGENT_MODEL` 指定。 |
| `-ReasoningEffort <level>` | 继承 `~/.codex/config.toml` | 可选推理强度覆盖；也可通过 `CODEX_SUBAGENT_EFFORT` 指定。 |
| `-SessionId <id>` | — | 续跑指定 Codex 线程（`codex exec resume <id>`）。 |
| `-ResumeLast` | `false` | 续跑 `-WorkDir` 下最近一次会话。 |
| `-Json` | `false` | 输出 JSONL 事件流（`thread.started` 包含 `thread_id`）。 |
| `-OutputFile <path>` | — | 将最终回复写入指定文件（`-o`）。 |
| `-AddDir <path[]>` | — | `workspace-write` 模式下额外放行的可写目录。 |
| `-CodexBin <path>` | 自动探测 | 显式指定 `codex.exe` / `codex.cmd`（优先级高于环境变量 `CODEX_SUBAGENT_BIN`、`local.config.json` 与 `PATH` 探测）。 |
| `-Proxy <url>` / `-NoProxy` | 自动探测 Windows 系统代理 | 自动读取并探测活跃的 Windows 系统代理（自动排除 localhost），或显式指定/禁用。 |
| `-TimeoutSec <int>` | `600` | 硬超时秒数；超时强杀整个进程树并以 `124` 退出。 |
| `-DryRun` | `false` | 仅输出解析后的二进制路径、参数数组与代理策略 JSON，不实际发起 API 调用。 |

## Recommended Invocation Pattern (UTF-8 Safe)

对于多行任务描述、中文提示词或含引号/反斜杠的指令，务必写入 UTF-8 临时文件并用 `-PromptFile` 传入，执行后清理临时文件：

```powershell
$promptFile = Join-Path $env:TEMP ("codex-prompt-" + [guid]::NewGuid().ToString("N") + ".txt")
[System.IO.File]::WriteAllText($promptFile, @"
审查 src/ 下近期改动的并发与错误处理风险，按严重级别列出具体文件与行号。
"@, [System.Text.UTF8Encoding]::new($false))
try {
  & $runner `
    -WorkDir "D:\path\to\repo" `
    -Mode read-only `
    -Json `
    -PromptFile $promptFile
} finally {
  Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
}
```

### Multi-Turn Session Resume

从首次 `-Json` 输出的 `thread.started` 事件中提取 `thread_id`，续跑同一上下文：

```powershell
& $runner -WorkDir "D:\path\to\repo" -Mode workspace-write -SessionId "<thread_id>" -PromptFile $promptFile
```

## Guardrails

1. **Task-tiered sandbox**：审查、调研、分析、规划类任务必须使用 `-Mode read-only`；仅在用户明确要求修改/新建代码文件时使用 `-Mode workspace-write`；严禁尝试绕过沙箱。
2. **Runtime isolation**：不要在宿主机上运行 `nvm use` 或切换全局 Node.js 版本来运行 Codex；若系统全局 `codex` 不在 `PATH` 或使用独立包，请通过 `-CodexBin`、`CODEX_SUBAGENT_BIN` 或技能目录下的 `local.config.json` 配置原生 `codex.exe` 路径。

## Troubleshooting

- **找不到 `codex.exe`**：运行 `-DryRun` 查看探测结果；确认已安装 `@openai/codex`，或在安装目录旁 `local.config.json` 中写入 `{"codexBin": "C:\\path\\to\\codex.exe"}`。
- **登录态失效**：在终端执行 `codex login status`，如未登录则执行 `codex login`。
- **网络超时**：确认系统代理正在运行，或显式传入 `-Proxy http://127.0.0.1:7897`；内网/直连环境可传 `-NoProxy`。
