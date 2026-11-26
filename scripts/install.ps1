[CmdletBinding()]
param(
    [string[]]$Target = @('auto'),
    [string]$HomeDir = $HOME,
    [string]$CodexBin,
    [string]$Model,
    [string]$ReasoningEffort,
    [string]$Proxy,
    [switch]$Link,
    [switch]$Uninstall,
    [switch]$SkipDoctor
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom

$repoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$skillSrc = Join-Path (Join-Path $repoRoot 'skills') 'codex-subagent'
$tomlTemplate = Join-Path (Join-Path (Join-Path $repoRoot 'codex') 'agents') 'codex-subagent.toml'

function Remove-PathSafely([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        if ($item.PSIsContainer) {
            [System.IO.Directory]::Delete($item.FullName, $false)
        } else {
            [System.IO.File]::Delete($item.FullName)
        }
        return
    }

    # Retry briefly to tolerate transient Windows file-watcher / AV locks (e.g., AGY LS watching plugins/)
    $maxAttempts = 6
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $Path)) { return }
        } catch {
            if ($attempt -eq $maxAttempts) {
                throw
            }
            Start-Sleep -Milliseconds (150 * $attempt)
        }
    }
}

function Ensure-Directory([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) {
        New-Item -ItemType Directory -Path $DirPath -Force | Out-Null
    }
}

function Copy-DirectoryClean([string]$Source, [string]$Destination) {
    Ensure-Directory -DirPath $Destination
    $items = Get-ChildItem -LiteralPath $Source -Force
    foreach ($it in $items) {
        if ($it.Name -eq 'local.config.json') { continue }
        $dstPath = Join-Path $Destination $it.Name
        if ($it.PSIsContainer) {
            Copy-DirectoryClean -Source $it.FullName -Destination $dstPath
        } else {
            Copy-Item -LiteralPath $it.FullName -Destination $dstPath -Force
        }
    }
}

function Read-JsonAsHashtable([string]$Path) {
    $ht = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $ht }
    try {
        $obj = [System.IO.File]::ReadAllText($Path, $utf8NoBom) | ConvertFrom-Json
        if ($null -ne $obj) {
            foreach ($p in $obj.PSObject.Properties) {
                if ($null -ne $p.Value -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) {
                    $ht[$p.Name] = [string]$p.Value
                }
            }
        }
    } catch {}
    return $ht
}

function Write-LocalConfigIfNeeded([string]$SkillDirPath, [System.Collections.IDictionary]$Existing) {
    $cfg = [ordered]@{}
    if ($Existing) {
        foreach ($k in $Existing.Keys) {
            $cfg[$k] = $Existing[$k]
        }
    }
    $changed = $false
    if (-not [string]::IsNullOrWhiteSpace($CodexBin)) {
        $cfg['codexBin'] = (Resolve-Path -LiteralPath $CodexBin).Path
        $changed = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $cfg['defaultModel'] = $Model
        $changed = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
        $cfg['defaultReasoningEffort'] = $ReasoningEffort
        $changed = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        $cfg['defaultProxy'] = $Proxy
        $changed = $true
    }

    $cfgPath = Join-Path $SkillDirPath 'local.config.json'
    if ($cfg.Count -gt 0 -and ($changed -or $Existing.Count -gt 0)) {
        $json = ($cfg | ConvertTo-Json -Depth 4) + "`n"
        [System.IO.File]::WriteAllText($cfgPath, $json, $utf8NoBom)
        Write-Host "  [config] Saved local overrides -> $cfgPath" -ForegroundColor DarkGray
    }
}

function Resolve-TargetHosts([string[]]$RawTargets, [string]$ResolvedHome) {
    $flat = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $RawTargets) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        foreach ($part in ($entry -split ',')) {
            $norm = $part.Trim().ToLowerInvariant()
            if ($norm) { $flat.Add($norm) }
        }
    }

    $valid = @('auto', 'agy', 'codex', 'dsh', 'all')
    foreach ($t in $flat) {
        if ($valid -notcontains $t) {
            throw "Invalid -Target '$t'. Allowed values: auto, agy, codex, dsh, all."
        }
    }

    if ($flat.Contains('all')) {
        return @('agy', 'codex', 'dsh')
    }

    if ($flat.Count -eq 0 -or $flat.Contains('auto')) {
        # Detect active host from runtime environment variables first
        $envHosts = [System.Collections.Generic.List[string]]::new()
        if ($env:ANTIGRAVITY_LS_ADDRESS -or $env:ANTIGRAVITY_CSRF_TOKEN) { $envHosts.Add('agy') }
        if ($env:CODEX_THREAD_ID -or $env:CODEX_SANDBOX) { $envHosts.Add('codex') }
        if ($env:DSH_PERMISSION_MODE -or $env:DSH_PROFILE -or $env:DSH_SESSION_ID) { $envHosts.Add('dsh') }

        if ($envHosts.Count -eq 1) {
            Write-Host "[codex-subagent] Auto-detected active host: $($envHosts[0])" -ForegroundColor Cyan
            return @($envHosts[0])
        }

        # Fallback: inspect existing host config roots under $ResolvedHome
        $dirHosts = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath (Join-Path $ResolvedHome '.gemini')) { $dirHosts.Add('agy') }
        if (Test-Path -LiteralPath (Join-Path $ResolvedHome '.codex')) { $dirHosts.Add('codex') }
        if (Test-Path -LiteralPath (Join-Path $ResolvedHome '.dsh')) { $dirHosts.Add('dsh') }

        if ($dirHosts.Count -eq 1) {
            Write-Host "[codex-subagent] Auto-detected single installed host: $($dirHosts[0])" -ForegroundColor Cyan
            return @($dirHosts[0])
        }

        if ($dirHosts.Count -gt 1) {
            [Console]::Error.WriteLine("[codex-subagent] Multiple hosts detected ($($dirHosts -join ', ')). Re-run with -Target agy, -Target codex, -Target dsh, or -Target all.")
            exit 2
        }

        [Console]::Error.WriteLine("[codex-subagent] Could not auto-detect target host under $ResolvedHome. Specify -Target agy, -Target codex, -Target dsh, or -Target all.")
        exit 2
    }

    $dedup = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $flat) {
        if (-not $dedup.Contains($t)) { $dedup.Add($t) }
    }
    return @($dedup)
}

function Install-Agy([string]$ResolvedHome) {
    $pluginsRoot = Join-Path (Join-Path (Join-Path $ResolvedHome '.gemini') 'config') 'plugins'
    $destPlugin = Join-Path $pluginsRoot 'codex-subagent'
    $destSkill = Join-Path (Join-Path $destPlugin 'skills') 'codex-subagent'
    $existingCfg = Read-JsonAsHashtable -Path (Join-Path $destSkill 'local.config.json')

    Ensure-Directory -DirPath $pluginsRoot

    if ($Link) {
        Remove-PathSafely -Path $destPlugin
        New-Item -ItemType Junction -Path $destPlugin -Target $repoRoot | Out-Null
        Write-Host "[AGY] Linked plugin -> $destPlugin (junction to $repoRoot)" -ForegroundColor Green
    } else {
        # Only unlink if converting from a junction; otherwise overwrite in-place so active AGY file watchers never hit Access Denied
        if ((Test-Path -LiteralPath $destPlugin) -and ((Get-Item -LiteralPath $destPlugin -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Remove-PathSafely -Path $destPlugin
        }
        Ensure-Directory -DirPath $destPlugin
        Copy-Item -LiteralPath (Join-Path $repoRoot 'plugin.json') -Destination (Join-Path $destPlugin 'plugin.json') -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $destPlugin 'README.md') -Force
        Copy-DirectoryClean -Source (Join-Path $repoRoot 'agents') -Destination (Join-Path $destPlugin 'agents')
        Copy-DirectoryClean -Source (Join-Path $repoRoot 'rules') -Destination (Join-Path $destPlugin 'rules')
        Copy-DirectoryClean -Source (Join-Path $repoRoot 'skills') -Destination (Join-Path $destPlugin 'skills')
        $assetsSrc = Join-Path $repoRoot 'assets'
        if (Test-Path -LiteralPath $assetsSrc) {
            Copy-DirectoryClean -Source $assetsSrc -Destination (Join-Path $destPlugin 'assets')
        }
        Write-Host "[AGY] Installed plugin -> $destPlugin" -ForegroundColor Green
    }

    Write-LocalConfigIfNeeded -SkillDirPath $destSkill -Existing $existingCfg
}

function Uninstall-Agy([string]$ResolvedHome) {
    $destPlugin = Join-Path (Join-Path (Join-Path (Join-Path $ResolvedHome '.gemini') 'config') 'plugins') 'codex-subagent'
    if (Test-Path -LiteralPath $destPlugin) {
        Remove-PathSafely -Path $destPlugin
        Write-Host "[AGY] Removed plugin: $destPlugin" -ForegroundColor Yellow
    } else {
        Write-Host "[AGY] Not installed: $destPlugin" -ForegroundColor DarkGray
    }
}

function Install-Codex([string]$ResolvedHome) {
    $skillsRoot = Join-Path (Join-Path $ResolvedHome '.codex') 'skills'
    $agentsRoot = Join-Path (Join-Path $ResolvedHome '.codex') 'agents'
    $destSkill = Join-Path $skillsRoot 'codex-subagent'
    $destToml = Join-Path $agentsRoot 'codex-subagent.toml'
    $existingCfg = Read-JsonAsHashtable -Path (Join-Path $destSkill 'local.config.json')

    Ensure-Directory -DirPath $skillsRoot
    Ensure-Directory -DirPath $agentsRoot

    if ($Link) {
        Remove-PathSafely -Path $destSkill
        New-Item -ItemType Junction -Path $destSkill -Target $skillSrc | Out-Null
        Write-Host "[Codex] Linked skill -> $destSkill (junction to $skillSrc)" -ForegroundColor Green
    } else {
        if ((Test-Path -LiteralPath $destSkill) -and ((Get-Item -LiteralPath $destSkill -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Remove-PathSafely -Path $destSkill
        }
        Copy-DirectoryClean -Source $skillSrc -Destination $destSkill
        Write-Host "[Codex] Installed skill -> $destSkill" -ForegroundColor Green
    }

    Write-LocalConfigIfNeeded -SkillDirPath $destSkill -Existing $existingCfg

    $runnerCmdPath = Join-Path (Join-Path $destSkill 'scripts') 'invoke-codex.cmd'
    $tomlRaw = [System.IO.File]::ReadAllText($tomlTemplate, $utf8NoBom)
    $tomlRendered = $tomlRaw.Replace('{{RUNNER_CMD_PATH}}', $runnerCmdPath)
    [System.IO.File]::WriteAllText($destToml, $tomlRendered, $utf8NoBom)
    Write-Host "[Codex] Installed native subagent -> $destToml" -ForegroundColor Green
}

function Uninstall-Codex([string]$ResolvedHome) {
    $destSkill = Join-Path (Join-Path (Join-Path $ResolvedHome '.codex') 'skills') 'codex-subagent'
    $destToml = Join-Path (Join-Path (Join-Path $ResolvedHome '.codex') 'agents') 'codex-subagent.toml'
    $removed = $false
    if (Test-Path -LiteralPath $destSkill) {
        Remove-PathSafely -Path $destSkill
        Write-Host "[Codex] Removed skill: $destSkill" -ForegroundColor Yellow
        $removed = $true
    }
    if (Test-Path -LiteralPath $destToml) {
        Remove-PathSafely -Path $destToml
        Write-Host "[Codex] Removed subagent: $destToml" -ForegroundColor Yellow
        $removed = $true
    }
    if (-not $removed) {
        Write-Host "[Codex] Not installed." -ForegroundColor DarkGray
    }
}

function Install-Dsh([string]$ResolvedHome) {
    $skillsRoot = Join-Path (Join-Path $ResolvedHome '.dsh') 'skills'
    $destSkill = Join-Path $skillsRoot 'codex-subagent'
    $existingCfg = Read-JsonAsHashtable -Path (Join-Path $destSkill 'local.config.json')

    Ensure-Directory -DirPath $skillsRoot

    if ($Link) {
        Remove-PathSafely -Path $destSkill
        New-Item -ItemType Junction -Path $destSkill -Target $skillSrc | Out-Null
        Write-Host "[DSH] Linked skill -> $destSkill (junction to $skillSrc)" -ForegroundColor Green
    } else {
        if ((Test-Path -LiteralPath $destSkill) -and ((Get-Item -LiteralPath $destSkill -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Remove-PathSafely -Path $destSkill
        }
        Copy-DirectoryClean -Source $skillSrc -Destination $destSkill
        Write-Host "[DSH] Installed skill -> $destSkill" -ForegroundColor Green
    }

    Write-LocalConfigIfNeeded -SkillDirPath $destSkill -Existing $existingCfg
}

function Uninstall-Dsh([string]$ResolvedHome) {
    $destSkill = Join-Path (Join-Path (Join-Path $ResolvedHome '.dsh') 'skills') 'codex-subagent'
    if (Test-Path -LiteralPath $destSkill) {
        Remove-PathSafely -Path $destSkill
        Write-Host "[DSH] Removed skill: $destSkill" -ForegroundColor Yellow
    } else {
        Write-Host "[DSH] Not installed: $destSkill" -ForegroundColor DarkGray
    }
}

if (-not [string]::IsNullOrWhiteSpace($CodexBin) -and -not (Test-Path -LiteralPath $CodexBin)) {
    [Console]::Error.WriteLine("[codex-subagent] -CodexBin path does not exist: $CodexBin")
    exit 2
}

$resolvedHome = if (Test-Path -LiteralPath $HomeDir) { (Resolve-Path -LiteralPath $HomeDir).Path } else { $HomeDir }
$targets = Resolve-TargetHosts -RawTargets $Target -ResolvedHome $resolvedHome

foreach ($t in $targets) {
    if ($Uninstall) {
        switch ($t) {
            'agy'   { Uninstall-Agy -ResolvedHome $resolvedHome }
            'codex' { Uninstall-Codex -ResolvedHome $resolvedHome }
            'dsh'   { Uninstall-Dsh -ResolvedHome $resolvedHome }
        }
    } else {
        switch ($t) {
            'agy'   { Install-Agy -ResolvedHome $resolvedHome }
            'codex' { Install-Codex -ResolvedHome $resolvedHome }
            'dsh'   { Install-Dsh -ResolvedHome $resolvedHome }
        }
    }
}

if (-not $Uninstall -and -not $SkipDoctor) {
    Write-Host ""
    $doctorScript = Join-Path $PSScriptRoot 'doctor.ps1'
    if (Test-Path -LiteralPath $doctorScript) {
        $docParams = @{ HomeDir = $resolvedHome }
        if (-not [string]::IsNullOrWhiteSpace($CodexBin)) {
            $docParams['CodexBin'] = $CodexBin
        }
        & $doctorScript @docParams
    }
}
