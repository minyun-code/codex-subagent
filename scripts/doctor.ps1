[CmdletBinding()]
param(
    [string]$HomeDir = $HOME,
    [string]$CodexBin,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

$repoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$resolvedHome = if (Test-Path -LiteralPath $HomeDir) { (Resolve-Path -LiteralPath $HomeDir).Path } else { $HomeDir }

$agyPluginDir = Join-Path (Join-Path (Join-Path (Join-Path $resolvedHome '.gemini') 'config') 'plugins') 'codex-subagent'
$codexSkillDir = Join-Path (Join-Path (Join-Path $resolvedHome '.codex') 'skills') 'codex-subagent'
$codexTomlPath = Join-Path (Join-Path (Join-Path $resolvedHome '.codex') 'agents') 'codex-subagent.toml'
$dshSkillDir = Join-Path (Join-Path (Join-Path $resolvedHome '.dsh') 'skills') 'codex-subagent'

# Pick the most relevant runner (installed copy first so local.config.json is respected)
$runnerCandidates = @(
    (Join-Path (Join-Path (Join-Path (Join-Path $agyPluginDir 'skills') 'codex-subagent') 'scripts') 'invoke-codex.ps1'),
    (Join-Path (Join-Path $codexSkillDir 'scripts') 'invoke-codex.ps1'),
    (Join-Path (Join-Path $dshSkillDir 'scripts') 'invoke-codex.ps1'),
    (Join-Path (Join-Path (Join-Path (Join-Path $repoRoot 'skills') 'codex-subagent') 'scripts') 'invoke-codex.ps1')
)
$runnerScript = $runnerCandidates | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | Select-Object -First 1

$dryRunObj = $null
$dryRunError = $null
if ($runnerScript) {
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerScript, '-DryRun', '-WorkDir', $repoRoot)
    if (-not [string]::IsNullOrWhiteSpace($CodexBin)) {
        $argsList += @('-CodexBin', $CodexBin)
    }
    $outText = (& $psExe @argsList 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        try {
            $dryRunObj = $outText | ConvertFrom-Json
        } catch {
            $dryRunError = "Failed to parse DryRun JSON: $outText"
        }
    } else {
        $dryRunError = $outText
    }
}

$codexVersion = $null
$authStatus = $null
if ($dryRunObj -and $dryRunObj.binary) {
    try {
        if ($dryRunObj.binaryKind -eq 'exe') {
            $codexVersion = (& $dryRunObj.binary --version 2>&1 | Out-String).Trim()
            $loginOut = (& $dryRunObj.binary login status 2>&1 | Out-String).Trim()
            $authStatus = if ($LASTEXITCODE -eq 0) { $loginOut } else { "not-logged-in ($loginOut)" }
        } else {
            $codexVersion = (& cmd.exe /d /s /c "`"$($dryRunObj.binary)`" --version" 2>&1 | Out-String).Trim()
            $loginOut = (& cmd.exe /d /s /c "`"$($dryRunObj.binary)`" login status" 2>&1 | Out-String).Trim()
            $authStatus = if ($LASTEXITCODE -eq 0) { $loginOut } else { "not-logged-in ($loginOut)" }
        }
    } catch {
        $authStatus = "check-failed: $($_.Exception.Message)"
    }
}

$agyValidateStatus = 'skipped'
if ((Test-Path -LiteralPath $agyPluginDir) -and (Get-Command agy -ErrorAction SilentlyContinue)) {
    $valOut = (& agy plugin validate $agyPluginDir --strict 2>&1 | Out-String).Trim()
    $agyValidateStatus = if ($LASTEXITCODE -eq 0) { 'ok' } else { "failed: $valOut" }
}

$report = [ordered]@{
    name        = 'codex-subagent'
    powershell  = $PSVersionTable.PSVersion.ToString()
    homeDir     = $resolvedHome
    cli         = [ordered]@{
        found        = [bool]($null -ne $dryRunObj -and $dryRunObj.binary)
        binary       = if ($dryRunObj) { $dryRunObj.binary } else { $null }
        binaryKind   = if ($dryRunObj) { $dryRunObj.binaryKind } else { $null }
        binarySource = if ($dryRunObj) { $dryRunObj.binarySource } else { $null }
        version      = $codexVersion
        authStatus   = $authStatus
        proxy        = if ($dryRunObj) { $dryRunObj.proxy } else { $null }
        proxySource  = if ($dryRunObj) { $dryRunObj.proxySource } else { $null }
        error        = $dryRunError
    }
    hosts       = [ordered]@{
        agy   = [ordered]@{
            installed = (Test-Path -LiteralPath (Join-Path $agyPluginDir 'plugin.json') -ErrorAction SilentlyContinue)
            path      = $agyPluginDir
            validate  = $agyValidateStatus
        }
        codex = [ordered]@{
            skillInstalled = (Test-Path -LiteralPath (Join-Path $codexSkillDir 'SKILL.md') -ErrorAction SilentlyContinue)
            agentInstalled = (Test-Path -LiteralPath $codexTomlPath -ErrorAction SilentlyContinue)
            skillPath      = $codexSkillDir
            agentPath      = $codexTomlPath
        }
        dsh   = [ordered]@{
            skillInstalled = (Test-Path -LiteralPath (Join-Path $dshSkillDir 'SKILL.md') -ErrorAction SilentlyContinue)
            skillPath      = $dshSkillDir
        }
    }
}

if ($Json) {
    [Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 6))
    exit 0
}

Write-Host "=== codex-subagent doctor ===" -ForegroundColor Cyan
Write-Host "PowerShell : $($report.powershell)"
if ($report.cli.found) {
    Write-Host "Codex CLI  : OK ($($report.cli.version)) [$($report.cli.binarySource)]" -ForegroundColor Green
    Write-Host "  Path     : $($report.cli.binary)"
    Write-Host "  Auth     : $($report.cli.authStatus)"
    Write-Host "  Proxy    : $(if ($report.cli.proxy) { "$($report.cli.proxy) [$($report.cli.proxySource)]" } else { "direct [$($report.cli.proxySource)]" })"
} else {
    Write-Host "Codex CLI  : NOT FOUND" -ForegroundColor Red
    Write-Host "  Detail   : $($report.cli.error)" -ForegroundColor Yellow
    Write-Host "  Next     : Install @openai/codex, set CODEX_SUBAGENT_BIN, or re-run install.ps1 -CodexBin <path>" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Installed Hosts ($resolvedHome):" -ForegroundColor Cyan
Write-Host ("  AGY   : {0} (validate: {1})" -f $(if ($report.hosts.agy.installed) { 'INSTALLED' } else { 'not installed' }), $report.hosts.agy.validate)
Write-Host ("  Codex : skill={0}, agent.toml={1}" -f $(if ($report.hosts.codex.skillInstalled) { 'INSTALLED' } else { 'missing' }), $(if ($report.hosts.codex.agentInstalled) { 'INSTALLED' } else { 'missing' }))
Write-Host ("  DSH   : skill={0}" -f $(if ($report.hosts.dsh.skillInstalled) { 'INSTALLED' } else { 'missing' }))
