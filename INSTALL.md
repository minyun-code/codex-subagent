# INSTALL.md — AI Agent 自动安装指令 (`codex-subagent`)

> 本文件供 **Antigravity (AGY)**、**OpenAI Codex** 或 **DeepSeek Harness (DSH)** 等 AI Agent 读取并按步骤自动执行安装。
> 仅支持 Windows（PowerShell 5.1 / 7+），无需修改宿主机 Node.js 版本。

## 执行步骤

### 第 1 步：确定目标宿主 (`-Target`)

仅默认安装到**当前与你对话的宿主**，除非用户明确要求同时安装到多个宿主：

| 当前运行的宿主 | `-Target` 参数 | 安装目标路径 |
| :--- | :--- | :--- |
| Antigravity (AGY) | `agy` | `~/.gemini/config/plugins/codex-subagent/` |
| OpenAI Codex | `codex` | `~/.codex/skills/codex-subagent/` 与 `~/.codex/agents/codex-subagent.toml` |
| DeepSeek Harness (DSH) | `dsh` | `~/.dsh/skills/codex-subagent/` |
| 用户明确要求三端全装 | `all` | 以上三端全部安装 |

### 第 2 步：拉取仓库到临时目录

优先使用 `git clone`；若本机无 `git`，自动回退下载 GitHub Zip 归档：

```powershell
$stage = Join-Path $env:TEMP ("codex-subagent-install-" + [guid]::NewGuid().ToString("N"))
if (Get-Command git -ErrorAction SilentlyContinue) {
  git clone --depth 1 https://github.com/minyun-code/codex-subagent.git $stage
  $srcDir = $stage
} else {
  $zip = "$stage.zip"
  Invoke-WebRequest -Uri "https://github.com/minyun-code/codex-subagent/archive/refs/heads/main.zip" -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $stage -Force
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  $srcDir = Join-Path $stage "codex-subagent-main"
}
```

### 第 3 步：运行幂等安装脚本（自动执行健康自检）

将 `<TARGET>` 替换为第 1 步确定的值（`agy`、`codex`、`dsh` 或 `all`）：

```powershell
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $srcDir "scripts\install.ps1") -Target <TARGET>
```

> **可选参数**：
> - 若用户的 `codex.exe` 安装在非标准目录（不在 `PATH` 中），可额外传 `-CodexBin "C:\path\to\codex.exe"`，安装器会自动写入本机 `local.config.json`（升级时自动保留）。
> - 如需指定默认模型/推理强度，可附加 `-Model <model> -ReasoningEffort <level>`（不传则默认继承 `~/.codex/config.toml`）。

### 第 4 步：清理临时目录

```powershell
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
```

### 第 5 步：向用户汇报安装与自检结果

基于 `doctor.ps1` 的输出，简明向用户报告：
1. 已安装的宿主及落盘目录；
2. 本地 `codex` CLI 探测结果、版本号与登录状态（若未安装提示执行 `npm install -g @openai/codex`；若未登录提示执行 `codex login`）；
3. 生效方式提醒：
   - **AGY**：插件自动加载，下一轮对话即可使用；可在 Customizations 页面管理 `[codex-subagent](customization://codex-subagent)`。
   - **Codex**：新开会话或下一轮即可调用技能 `codex-subagent` 及自定义子 Agent `codex-subagent.toml`。
   - **DSH**：刷新或重启会话即可在技能列表中看到 `codex-subagent`。

---

## 升级与卸载

- **升级**：重复执行上述第 2~4 步即可，安装器会覆盖代码文件并自动保留你已有的 `local.config.json`。
- **卸载**：克隆或进入本地仓库目录后运行：
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File ".\scripts\install.ps1" -Uninstall -Target <agy|codex|dsh|all>
  ```
