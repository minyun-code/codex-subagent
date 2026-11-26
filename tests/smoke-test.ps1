[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$repoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$runnerPs1 = Join-Path (Join-Path (Join-Path (Join-Path $repoRoot 'skills') 'codex-subagent') 'scripts') 'invoke-codex.ps1'
$installPs1 = Join-Path (Join-Path $repoRoot 'scripts') 'install.ps1'
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

$passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
    $script:passed++
    Write-Host "  [PASS] $Message" -ForegroundColor Green
}

Write-Host "=== codex-subagent smoke tests ===" -ForegroundColor Cyan

# 1. PowerShell AST syntax check across all .ps1 files
$psFiles = Get-ChildItem -Path $repoRoot -Filter '*.ps1' -Recurse
foreach ($f in $psFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "Syntax valid: $($f.Name)"
}

# 2. Validate plugin.json is valid JSON with required keys
$pluginManifest = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'plugin.json'), $utf8NoBom) | ConvertFrom-Json
Assert-True ($pluginManifest.name -eq 'codex-subagent') "plugin.json name is codex-subagent"
Assert-True ($pluginManifest.repository -eq 'https://github.com/minyun-code/codex-subagent') "plugin.json repository matches minyun-code"

# 3. Create temp sandbox for fake binary, non-git dir, and fake HOME
$sandbox = Join-Path $env:TEMP ("codex-subagent-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
try {
    $fakeHome = Join-Path $sandbox 'home'
    $nonGitDir = Join-Path $sandbox 'nongit'
    $fakeExe = Join-Path $sandbox 'codex.exe'
    New-Item -ItemType Directory -Path $fakeHome, $nonGitDir -Force | Out-Null
    [System.IO.File]::WriteAllText($fakeExe, 'stub', $utf8NoBom)

    # 3a. Security guardrail: danger-full-access must be rejected
    $null = & $psExe -NoProfile -ExecutionPolicy Bypass -File $runnerPs1 -CodexBin $fakeExe -WorkDir $nonGitDir -Mode 'danger-full-access' -Prompt 'hi' -DryRun 2>&1
    Assert-True ($LASTEXITCODE -ne 0) "Rejects danger-full-access mode"

    # 3b. Missing prompt exits fast with code 2 (must not hang on open stdin pipe)
    $null = & $psExe -NoProfile -ExecutionPolicy Bypass -File $runnerPs1 -CodexBin $fakeExe -WorkDir $nonGitDir 2>&1
    Assert-True ($LASTEXITCODE -eq 2) "Missing prompt exits fast with code 2"

    # 3b2. Explicit -Stdin reads piped input cleanly
    $stdinJson = ('hello from pipe' | & $psExe -NoProfile -ExecutionPolicy Bypass -File $runnerPs1 -CodexBin $fakeExe -WorkDir $nonGitDir -Stdin -NoProxy -DryRun | Out-String)
    Assert-True ($LASTEXITCODE -eq 0 -and ($stdinJson | ConvertFrom-Json).dryRun -eq $true) "Explicit -Stdin reads piped input"

    # 3c. DryRun in non-git dir adds --skip-git-repo-check and inherits default model (null)
    $dryJson = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $runnerPs1 -CodexBin $fakeExe -WorkDir $nonGitDir -Mode 'read-only' -NoProxy -Prompt 'hello' -DryRun | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "DryRun succeeds with explicit -CodexBin"
    $dry = $dryJson | ConvertFrom-Json
    Assert-True ($dry.binarySource -eq 'param') "Tier 1 binarySource is 'param'"
    Assert-True ($dry.inGitRepo -eq $false) "Detects non-git workspace"
    Assert-True ($dry.args -contains '--skip-git-repo-check') "Auto-adds --skip-git-repo-check outside git repo"
    Assert-True ($null -eq $dry.model) "Does not hardcode default model"
    Assert-True ($null -eq $dry.reasoningEffort) "Does not hardcode reasoning effort"
    Assert-True ($dry.args -contains 'approval_policy="never"') "Injects approval_policy=never"

    # 3d. DryRun resume mode with session id & model override
    $resumeJson = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $runnerPs1 -CodexBin $fakeExe -WorkDir $nonGitDir -Mode 'workspace-write' -SessionId 'thr_123' -Model 'o3' -Json -NoProxy -Prompt 'continue' -DryRun | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "DryRun resume succeeds"
    $res = $resumeJson | ConvertFrom-Json
    Assert-True ($res.args[0] -eq 'exec' -and $res.args[1] -eq 'resume') "Resume invokes 'codex exec resume'"
    Assert-True ($res.args -contains 'thr_123') "Resume passes SessionId"
    Assert-True ($res.model -eq 'o3') "Respects explicit -Model override"

    # 4. Sandbox install.ps1 -Target all + local.config.json persistence + uninstall
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $installPs1 -Target all -HomeDir $fakeHome -CodexBin $fakeExe -SkipDoctor | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "install.ps1 -Target all succeeds in sandbox"

    $agyPlugin = Join-Path $fakeHome '.gemini\config\plugins\codex-subagent'
    $codexSkill = Join-Path $fakeHome '.codex\skills\codex-subagent'
    $codexToml = Join-Path $fakeHome '.codex\agents\codex-subagent.toml'
    $dshSkill = Join-Path $fakeHome '.dsh\skills\codex-subagent'

    Assert-True (Test-Path -LiteralPath (Join-Path $agyPlugin 'plugin.json')) "AGY plugin.json installed"
    Assert-True (Test-Path -LiteralPath (Join-Path $agyPlugin 'agents\codex-subagent.md')) "AGY agent installed"
    Assert-True (Test-Path -LiteralPath (Join-Path $agyPlugin 'skills\codex-subagent\local.config.json')) "AGY local.config.json written"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $agyPlugin 'tests'))) "AGY plugin excludes repo tests/"
    Assert-True (Test-Path -LiteralPath (Join-Path $codexSkill 'SKILL.md')) "Codex skill installed"
    Assert-True (Test-Path -LiteralPath $codexToml) "Codex native agent TOML installed"
    Assert-True (Test-Path -LiteralPath (Join-Path $dshSkill 'SKILL.md')) "DSH skill installed"

    $tomlText = [System.IO.File]::ReadAllText($codexToml, $utf8NoBom)
    Assert-True (-not $tomlText.Contains('{{RUNNER_CMD_PATH}}')) "Codex TOML placeholder rendered"
    Assert-True ($tomlText.Contains('invoke-codex.cmd')) "Codex TOML points to installed invoke-codex.cmd"

    # Installed runner reads local.config.json automatically (Tier 3)
    $installedRunner = Join-Path $codexSkill 'scripts\invoke-codex.ps1'
    $tier3Json = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $installedRunner -WorkDir $nonGitDir -NoProxy -Prompt 'test' -DryRun | Out-String)
    Assert-True ($LASTEXITCODE -eq 0) "Installed runner resolves Tier 3 local.config.json"
    $tier3 = $tier3Json | ConvertFrom-Json
    Assert-True ($tier3.binarySource -eq 'local-config') "Tier 3 binarySource is 'local-config'"

    # Upgrade preserves existing local.config.json
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $installPs1 -Target all -HomeDir $fakeHome -SkipDoctor | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "Re-running install.ps1 (upgrade) succeeds"
    Assert-True (Test-Path -LiteralPath (Join-Path $codexSkill 'local.config.json')) "Upgrade preserves local.config.json"

    # Uninstall cleans all three hosts
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $installPs1 -Uninstall -Target all -HomeDir $fakeHome -SkipDoctor | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "install.ps1 -Uninstall -Target all succeeds"
    Assert-True (-not (Test-Path -LiteralPath $agyPlugin)) "AGY plugin removed"
    Assert-True (-not (Test-Path -LiteralPath $codexSkill)) "Codex skill removed"
    Assert-True (-not (Test-Path -LiteralPath $codexToml)) "Codex agent TOML removed"
    Assert-True (-not (Test-Path -LiteralPath $dshSkill)) "DSH skill removed"

    Write-Host "`nAll $passed smoke test assertions passed!" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
