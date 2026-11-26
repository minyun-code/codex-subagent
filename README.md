# codex-subagent

> [English Documentation](./README.en.md) | Windows-First | 零硬编码 | 支持 Antigravity (AGY) / Codex / DeepSeek Harness (DSH)

将本地 **OpenAI Codex CLI (`codex exec`)** 封装为轻量、零耦合、沙箱隔离的可移植子 Agent 与通用技能（Skill），让 **Antigravity (AGY)**、**Codex**、**DeepSeek Harness (DSH)** 均可通过一句话安装并安全委派复杂编码、重构、调试与深度代码审查任务。

## 一句话让 AI 自动安装

直接把下面任意一句话发给你的 **AGY / Codex / DSH**：

```text
请读取并按步骤执行 https://raw.githubusercontent.com/minyun-code/codex-subagent/main/INSTALL.md，为当前环境安装 codex-subagent。
```

若当前网络不方便直连 `raw.githubusercontent.com`，可直接发送：

```text
请克隆 https://github.com/minyun-code/codex-subagent.git 并阅读其中的 INSTALL.md，为当前环境安装 codex-subagent。
```

如需同时安装到本机全部三端，只需在句尾补充「安装到全部宿主（`-Target all`）」。

## 手动安装（PowerShell）

```powershell
git clone --depth 1 https://github.com/minyun-code/codex-subagent.git
cd codex-subagent

# 安装到指定宿主（agy / codex / dsh / all）
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -Target agy

# 若本地使用非 PATH 下的独立 codex.exe，可一并持久化路径
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -Target all -CodexBin "D:\path\to\codex.exe"
```

本地开发调试可使用 `-Link` 创建 NTFS 目录联接（无需管理员权限）。

## 三端落盘形态

| 目标宿主 | 安装形态 | 落盘位置 | 说明 |
| :--- | :--- | :--- | :--- |
| **Antigravity (AGY)** | 原生完整插件 | `~/.gemini/config/plugins/codex-subagent/` | 包含 `plugin.json`、`agents/codex-subagent.md`、`skills/codex-subagent/`、`rules/AGENTS.md`，可直接通过 `agy plugin validate --strict` |
| **OpenAI Codex** | Skill + 原生子 Agent | `~/.codex/skills/codex-subagent/`<br>`~/.codex/agents/codex-subagent.toml` | 自包含运行脚本 + 自动渲染真实路径的 TOML 子 Agent 定义 |
| **DeepSeek Harness (DSH)** | 免构建原生 Skill | `~/.dsh/skills/codex-subagent/` | 纯 `SKILL.md` + PowerShell 脚本，零构建、不修改 `cordis.patch.yml` |

## 核心特性

- **零硬编码与四级 CLI 发现**：按 `显式参数 -CodexBin` → `环境变量 CODEX_SUBAGENT_BIN / CODEX_BIN` → `local.config.json` → `PATH 与常见目录` 顺序自动探测，优先解析原生 `codex.exe`，不干扰宿主机 `nvm` / Node.js 环境。
- **继承个人默认配置**：默认不硬编码模型名与推理强度，直接复用用户 `~/.codex/config.toml` 与登录态；按需通过 `-Model` / `-ReasoningEffort` 或环境变量覆盖。
- **任务分级沙箱边界**：默认 `-Mode read-only`，仅在明确授权修改文件时使用 `-Mode workspace-write`，强制注入 `approval_policy="never"`，从设计上禁止 `danger-full-access`。
- **Windows 实战稳定性**：UTF-8 无 BOM stdin 传递提示词（规避中文乱码与引号转义）、自动探测 Windows 活跃系统代理（跳过 localhost，支持 `-Proxy` / `-NoProxy`）、硬超时进程树强杀（退出码 `124`）、非 Git 目录自动补齐 `--skip-git-repo-check`。
- **多轮会话续跑与无消耗自检**：支持 `-Json` 输出 `thread_id` 与 `-SessionId` / `-ResumeLast` 续跑；内置 `-DryRun` 与 `scripts/doctor.ps1` 诊断工具。

## 前置依赖

- Windows 10 / 11（PowerShell 5.1 或 PowerShell 7+）
- 本地已安装并登录 OpenAI Codex CLI（`@openai/codex`）：
  ```powershell
  codex --version
  codex login status
  ```

## 自检、测试与卸载

```powershell
# 运行环境体检
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1

# 运行离线自动化烟雾测试（不消耗 API 额度）
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-test.ps1

# 卸载指定宿主
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -Uninstall -Target agy
```

## 开源协议

[MIT License](./LICENSE)
