[CmdletBinding()]
param(
    [string]$Prompt,
    [string]$PromptFile,
    [switch]$Stdin,
    [string]$WorkDir = (Get-Location).Path,
    [ValidateSet('read-only', 'workspace-write')]
    [string]$Mode = 'read-only',
    [string]$Model,
    [string]$ReasoningEffort,
    [string]$SessionId,
    [switch]$ResumeLast,
    [switch]$Json,
    [string]$OutputFile,
    [string[]]$AddDir,
    [string]$Proxy,
    [switch]$NoProxy,
    [string]$CodexBin,
    [int]$TimeoutSec = 600,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

function Quote-WinArg([string]$Arg) {
    if ($null -eq $Arg -or $Arg.Length -eq 0) { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = [System.Text.StringBuilder]::new('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') {
            $bs++
        } elseif ($ch -eq '"') {
            [void]$sb.Append('\', $bs * 2 + 1)
            [void]$sb.Append('"')
            $bs = 0
        } else {
            if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($bs -gt 0) { [void]$sb.Append('\', $bs * 2) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Stop-ProcessTree([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process) { return }
    try {
        $Process.Kill($true)
        return
    } catch {}
    try {
        if (-not $Process.HasExited) {
            & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null
        }
    } catch {}
    try {
        if (-not $Process.HasExited) { $Process.Kill() }
    } catch {}
}

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 300) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($ar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Resolve-SystemProxyUrl {
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($reg.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace($reg.ProxyServer)) {
            $raw = [string]$reg.ProxyServer
            if ($raw -match '(?:^|;)https=([^;]+)') {
                $raw = $Matches[1]
            } elseif ($raw -match '(?:^|;)http=([^;]+)') {
                $raw = $Matches[1]
            }
            $url = if ($raw -match '^[a-zA-Z]+://') { $raw } else { "http://$raw" }
            $uri = [Uri]$url
            if (Test-TcpPort -HostName $uri.Host -Port $uri.Port) {
                return $url
            }
        }
    } catch {}
    return $null
}

function Test-InsideGitRepo([string]$DirPath) {
    $cur = $DirPath
    while ($cur) {
        if (Test-Path -LiteralPath (Join-Path $cur '.git')) { return $true }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return $false
}

function Get-LocalConfig {
    $result = @{}
    $candidates = [System.Collections.Generic.List[string]]::new()

    $userCfgDir = Join-Path (Join-Path $HOME '.config') 'codex-subagent'
    $candidates.Add((Join-Path $userCfgDir 'config.json'))

    $skillDir = Split-Path -Parent $PSScriptRoot
    $skillsParent = Split-Path -Parent $skillDir
    if ($skillsParent -and (Split-Path -Leaf $skillsParent) -eq 'skills') {
        $pluginRoot = Split-Path -Parent $skillsParent
        if ($pluginRoot) {
            $candidates.Add((Join-Path $pluginRoot 'local.config.json'))
        }
    }
    $candidates.Add((Join-Path $skillDir 'local.config.json'))

    foreach ($cfgPath in $candidates) {
        if (-not (Test-Path -LiteralPath $cfgPath)) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($cfgPath, $utf8NoBom)
            $obj = $raw | ConvertFrom-Json
            if ($null -eq $obj) { continue }
            foreach ($prop in $obj.PSObject.Properties) {
                if ($null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                    $result[$prop.Name] = [string]$prop.Value
                }
            }
        } catch {
            [Console]::Error.WriteLine("[codex-subagent] Warning: failed to parse config ${cfgPath}: $($_.Exception.Message)")
        }
    }
    return $result
}

function Find-NativeCodexExe([string]$SearchRoot) {
    if ([string]::IsNullOrWhiteSpace($SearchRoot) -or -not (Test-Path -LiteralPath $SearchRoot)) {
        return $null
    }
    $preferredRel = Join-Path (Join-Path (Join-Path (Join-Path '@openai' 'codex-win32-x64') 'vendor') 'x86_64-pc-windows-msvc') (Join-Path 'bin' 'codex.exe')
    $direct = Join-Path $SearchRoot $preferredRel
    if (Test-Path -LiteralPath $direct) { return (Resolve-Path -LiteralPath $direct).Path }

    $openaiDir = Join-Path $SearchRoot '@openai'
    if (Test-Path -LiteralPath $openaiDir) {
        $found = Get-ChildItem -Path $openaiDir -Filter 'codex.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($found) { return $found }
    }

    $foundAny = Get-ChildItem -Path $SearchRoot -Filter 'codex.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($foundAny) { return $foundAny }
    return $null
}

function Resolve-CodexCandidate([string]$CandidatePath) {
    if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return $null }
    if (-not (Test-Path -LiteralPath $CandidatePath)) { return $null }

    $resolved = (Resolve-Path -LiteralPath $CandidatePath).Path
    $selfCmd = Join-Path $PSScriptRoot 'invoke-codex.cmd'
    if ([string]::Equals($resolved, $selfCmd, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $native = Find-NativeCodexExe -SearchRoot $resolved
        if ($native) { return @{ Kind = 'exe'; Path = $native } }
        $cmdInDir = Join-Path $resolved 'codex.cmd'
        if (Test-Path -LiteralPath $cmdInDir) { return @{ Kind = 'cmd'; Path = $cmdInDir } }
        return $null
    }

    $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($ext -eq '.exe') {
        return @{ Kind = 'exe'; Path = $resolved }
    }

    # For npm .cmd/.ps1 shims, prefer native codex.exe in nearby node_modules to stay isolated from host Node versions
    $dir = Split-Path -Parent $resolved
    $probeRoots = [System.Collections.Generic.List[string]]::new()
    if ($dir) {
        $probeRoots.Add((Join-Path $dir 'node_modules'))
        $parent = Split-Path -Parent $dir
        if ($parent) {
            $probeRoots.Add($parent)
            $probeRoots.Add((Join-Path $parent 'node_modules'))
        }
    }
    foreach ($root in $probeRoots) {
        $native = Find-NativeCodexExe -SearchRoot $root
        if ($native) { return @{ Kind = 'exe'; Path = $native } }
    }

    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        return @{ Kind = 'cmd'; Path = $resolved }
    }

    return $null
}

function Resolve-CodexBinary {
    param(
        [string]$ExplicitBin,
        [hashtable]$LocalConfig
    )

    # Tier 1: Explicit parameter
    if (-not [string]::IsNullOrWhiteSpace($ExplicitBin)) {
        $hit = Resolve-CodexCandidate -CandidatePath $ExplicitBin
        if ($hit) {
            $hit['Source'] = 'param'
            return $hit
        }
        [Console]::Error.WriteLine("[codex-subagent] Specified -CodexBin not found or invalid: $ExplicitBin")
        exit 127
    }

    # Tier 2: Environment variables
    foreach ($envName in @('CODEX_SUBAGENT_BIN', 'CODEX_BIN')) {
        $envVal = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($envVal)) {
            $hit = Resolve-CodexCandidate -CandidatePath $envVal
            if ($hit) {
                $hit['Source'] = "env:$envName"
                return $hit
            }
        }
    }

    # Tier 3: Local config (written during install or by user)
    if ($LocalConfig -and $LocalConfig.ContainsKey('codexBin')) {
        $hit = Resolve-CodexCandidate -CandidatePath $LocalConfig['codexBin']
        if ($hit) {
            $hit['Source'] = 'local-config'
            return $hit
        }
    }

    # Tier 4: Auto-discovery (PATH -> standard Windows install paths)
    foreach ($cmdName in @('codex.exe', 'codex.cmd', 'codex')) {
        $cmds = @(Get-Command -Name $cmdName -CommandType Application -All -ErrorAction SilentlyContinue)
        foreach ($cmd in $cmds) {
            if ($cmd -and $cmd.Source) {
                $hit = Resolve-CodexCandidate -CandidatePath $cmd.Source
                if ($hit) {
                    $hit['Source'] = 'auto:path'
                    return $hit
                }
            }
        }
    }

    $commonRoots = [System.Collections.Generic.List[string]]::new()
    if ($env:APPDATA) {
        $commonRoots.Add((Join-Path (Join-Path $env:APPDATA 'npm') 'node_modules'))
    }
    if ($env:LOCALAPPDATA) {
        $commonRoots.Add((Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'codex'))
        $commonRoots.Add((Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'OpenAI Codex'))
    }
    $commonRoots.Add((Join-Path (Join-Path $HOME '.codex') 'bin'))
    if ($env:ProgramFiles) {
        $commonRoots.Add((Join-Path (Join-Path $env:ProgramFiles 'OpenAI') 'Codex'))
    }

    foreach ($root in $commonRoots) {
        $native = Find-NativeCodexExe -SearchRoot $root
        if ($native) {
            return @{ Kind = 'exe'; Path = $native; Source = 'auto:common-dir' }
        }
    }

    return $null
}

$localConfig = Get-LocalConfig

# Resolve prompt content (PromptFile > Prompt > explicit -Stdin / -Prompt -)
# Note: Never blindly call [Console]::In.ReadToEnd() when IsInputRedirected is true,
# because non-interactive AI agent terminals keep stdin pipes open indefinitely.
$taskText = $null
if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile)) {
        [Console]::Error.WriteLine("[codex-subagent] PromptFile not found: $PromptFile")
        exit 2
    }
    $taskText = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path, $utf8NoBom)
} elseif ($Stdin.IsPresent -or $Prompt -eq '-') {
    $taskText = [Console]::In.ReadToEnd()
} elseif ($PSBoundParameters.ContainsKey('Prompt') -and -not [string]::IsNullOrWhiteSpace($Prompt)) {
    $taskText = $Prompt
} elseif ($DryRun) {
    $taskText = '[dry-run]'
}

if ([string]::IsNullOrWhiteSpace($taskText)) {
    [Console]::Error.WriteLine("[codex-subagent] Missing prompt. Provide -Prompt, -PromptFile, or pass -Stdin (or -Prompt -) with piped input.")
    exit 2
}

if (-not (Test-Path -LiteralPath $WorkDir)) {
    [Console]::Error.WriteLine("[codex-subagent] WorkDir not found: $WorkDir")
    exit 2
}
$resolvedWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path

$codexTarget = Resolve-CodexBinary -ExplicitBin $CodexBin -LocalConfig $localConfig
if (-not $codexTarget) {
    [Console]::Error.WriteLine("[codex-subagent] Codex CLI binary not found. Install @openai/codex, set CODEX_SUBAGENT_BIN, or pass -CodexBin.")
    exit 127
}

# Resolve effective model & reasoning effort (param > env > local.config.json > inherit ~/.codex/config.toml)
$effectiveModel = $Model
if ([string]::IsNullOrWhiteSpace($effectiveModel)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SUBAGENT_MODEL)) {
        $effectiveModel = $env:CODEX_SUBAGENT_MODEL
    } elseif ($localConfig.ContainsKey('defaultModel')) {
        $effectiveModel = $localConfig['defaultModel']
    }
}

$effectiveEffort = $ReasoningEffort
if ([string]::IsNullOrWhiteSpace($effectiveEffort)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SUBAGENT_EFFORT)) {
        $effectiveEffort = $env:CODEX_SUBAGENT_EFFORT
    } elseif ($localConfig.ContainsKey('defaultReasoningEffort')) {
        $effectiveEffort = $localConfig['defaultReasoningEffort']
    }
}

$isResume = (-not [string]::IsNullOrWhiteSpace($SessionId)) -or $ResumeLast.IsPresent
$inGitRepo = Test-InsideGitRepo -DirPath $resolvedWorkDir

$codexArgs = [System.Collections.Generic.List[string]]::new()
$codexArgs.Add('exec')

if ($isResume) {
    $codexArgs.Add('resume')
    $codexArgs.Add('-c')
    $codexArgs.Add('approval_policy="never"')
    $codexArgs.Add('-c')
    $codexArgs.Add("sandbox_mode=`"$Mode`"")
    if (-not [string]::IsNullOrWhiteSpace($effectiveEffort)) {
        $codexArgs.Add('-c')
        $codexArgs.Add("model_reasoning_effort=`"$effectiveEffort`"")
    }
    if (-not $inGitRepo) { $codexArgs.Add('--skip-git-repo-check') }
    if (-not [string]::IsNullOrWhiteSpace($effectiveModel)) { $codexArgs.Add('-m'); $codexArgs.Add($effectiveModel) }
    if ($Json) { $codexArgs.Add('--json') }
    if ($OutputFile) { $codexArgs.Add('-o'); $codexArgs.Add($OutputFile) }
    if ($ResumeLast -and [string]::IsNullOrWhiteSpace($SessionId)) {
        $codexArgs.Add('--last')
    } else {
        $codexArgs.Add($SessionId)
    }
    $codexArgs.Add('-')
} else {
    $codexArgs.Add('-C')
    $codexArgs.Add($resolvedWorkDir)
    $codexArgs.Add('-s')
    $codexArgs.Add($Mode)
    $codexArgs.Add('-c')
    $codexArgs.Add('approval_policy="never"')
    if (-not [string]::IsNullOrWhiteSpace($effectiveEffort)) {
        $codexArgs.Add('-c')
        $codexArgs.Add("model_reasoning_effort=`"$effectiveEffort`"")
    }
    $codexArgs.Add('--color')
    $codexArgs.Add('never')
    if (-not $inGitRepo) { $codexArgs.Add('--skip-git-repo-check') }
    if (-not [string]::IsNullOrWhiteSpace($effectiveModel)) { $codexArgs.Add('-m'); $codexArgs.Add($effectiveModel) }
    if ($Json) { $codexArgs.Add('--json') }
    if ($OutputFile) { $codexArgs.Add('-o'); $codexArgs.Add($OutputFile) }
    if ($AddDir -and $Mode -eq 'workspace-write') {
        foreach ($dir in $AddDir) {
            if (-not [string]::IsNullOrWhiteSpace($dir)) {
                $codexArgs.Add('--add-dir')
                $codexArgs.Add((Resolve-Path -LiteralPath $dir).Path)
            }
        }
    }
    $codexArgs.Add('-')
}

# Resolve effective proxy (param > local.config.json > existing env > Windows System Proxy)
$effectiveProxy = $null
$proxySource = 'none'
if (-not $NoProxy) {
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        $effectiveProxy = if ($Proxy -match '^[a-zA-Z]+://') { $Proxy } else { "http://$Proxy" }
        $proxySource = 'param'
    } elseif (-not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY) -or -not [string]::IsNullOrWhiteSpace($env:HTTP_PROXY) -or -not [string]::IsNullOrWhiteSpace($env:ALL_PROXY)) {
        $proxySource = 'env'
    } elseif ($localConfig.ContainsKey('defaultProxy')) {
        $cfgProxy = $localConfig['defaultProxy']
        $effectiveProxy = if ($cfgProxy -match '^[a-zA-Z]+://') { $cfgProxy } else { "http://$cfgProxy" }
        $proxySource = 'local-config'
    } else {
        $effectiveProxy = Resolve-SystemProxyUrl
        if ($effectiveProxy) { $proxySource = 'windows-system-proxy' }
    }
}

if ($DryRun) {
    $payload = [ordered]@{
        dryRun          = $true
        binary          = $codexTarget.Path
        binaryKind      = $codexTarget.Kind
        binarySource    = $codexTarget.Source
        workDir         = $resolvedWorkDir
        inGitRepo       = $inGitRepo
        mode            = $Mode
        model           = if ([string]::IsNullOrWhiteSpace($effectiveModel)) { $null } else { $effectiveModel }
        reasoningEffort = if ([string]::IsNullOrWhiteSpace($effectiveEffort)) { $null } else { $effectiveEffort }
        proxy           = $effectiveProxy
        proxySource     = $proxySource
        timeoutSec      = $TimeoutSec
        args            = @($codexArgs)
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 5))
    exit 0
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
if ($codexTarget.Kind -eq 'exe') {
    $psi.FileName = $codexTarget.Path
    $psi.Arguments = ($codexArgs | ForEach-Object { Quote-WinArg $_ }) -join ' '
} else {
    $psi.FileName = $env:ComSpec
    $cmdLine = '"' + $codexTarget.Path + '" ' + (($codexArgs | ForEach-Object { Quote-WinArg $_ }) -join ' ')
    $psi.Arguments = "/d /s /c `"$cmdLine`""
}
$psi.WorkingDirectory = $resolvedWorkDir
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8NoBom
$psi.StandardErrorEncoding = $utf8NoBom

# Prepend Codex vendor helper path (e.g. bundled rg.exe) when running native codex.exe
if ($codexTarget.Kind -eq 'exe') {
    $vendorPathDir = Join-Path (Split-Path -Parent (Split-Path -Parent $codexTarget.Path)) 'path'
    if (Test-Path -LiteralPath $vendorPathDir) {
        $psi.EnvironmentVariables['PATH'] = "$vendorPathDir;$($psi.EnvironmentVariables['PATH'])"
    }
}

if ($effectiveProxy) {
    $psi.EnvironmentVariables['HTTP_PROXY'] = $effectiveProxy
    $psi.EnvironmentVariables['HTTPS_PROXY'] = $effectiveProxy
    $psi.EnvironmentVariables['ALL_PROXY'] = $effectiveProxy
    if ([string]::IsNullOrWhiteSpace($psi.EnvironmentVariables['NO_PROXY'])) {
        $psi.EnvironmentVariables['NO_PROXY'] = 'localhost,127.0.0.1,::1'
    }
}

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi
[void]$proc.Start()

$bytes = $utf8NoBom.GetBytes($taskText)
$proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
$proc.StandardInput.BaseStream.Flush()
$proc.StandardInput.Close()

$outTask = $proc.StandardOutput.ReadLineAsync()
$errTask = $proc.StandardError.ReadLineAsync()
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

while ($null -ne $outTask -or $null -ne $errTask) {
    if ([DateTime]::UtcNow -gt $deadline -and -not $proc.HasExited) {
        Stop-ProcessTree -Process $proc
        [Console]::Error.WriteLine("[codex-subagent] Timeout after ${TimeoutSec}s; process terminated.")
        exit 124
    }
    $didWork = $false
    if ($null -ne $outTask -and $outTask.IsCompleted) {
        $line = $outTask.GetAwaiter().GetResult()
        if ($null -eq $line) { $outTask = $null }
        else { [Console]::Out.WriteLine($line); $outTask = $proc.StandardOutput.ReadLineAsync() }
        $didWork = $true
    }
    if ($null -ne $errTask -and $errTask.IsCompleted) {
        $line = $errTask.GetAwaiter().GetResult()
        if ($null -eq $line) { $errTask = $null }
        else { [Console]::Error.WriteLine($line); $errTask = $proc.StandardError.ReadLineAsync() }
        $didWork = $true
    }
    if (-not $didWork) { Start-Sleep -Milliseconds 30 }
}

$proc.WaitForExit()
exit $proc.ExitCode
