# ===========================================================
# Servy Full-Stack Deployment Manager
# Interactive CLI menu: install / uninstall / start / stop /
# status-check components, change install path, check prereqs.
#
# Usage:
#   .\deploy.ps1                          # Interactive menu
#   .\deploy.ps1 -Force                   # Non-interactive full deploy
#   .\deploy.ps1 -Force -Components frontend,backend  # Non-interactive, selective
#   .\deploy.ps1 -DryRun                  # Preview only, no changes
#   .\deploy.ps1 -DryRun -Components frontend,caddy   # Preview specific components
#
# Files created next to this script:
#   deploy.config.json          - non-secret settings (install path, ports, repos)
#   deploy.secrets.json         - DB/SMTP credentials (auto-added to .gitignore)
#   deploy.secrets.example.json - template with placeholder values
# ===========================================================

#Requires -RunAsAdministrator

param(
    [switch]$DryRun,
    [switch]$Force,
    [ValidateSet("frontend", "backend", "caddy", "cloudflare")]
    [string[]]$Components = @()
)

$ErrorActionPreference = "Continue"

# ===========================================================
# EXECUTION POLICY - auto-bypass if policy blocks unsigned scripts
# This lets users run .\deploy.ps1 without manually setting
# Set-ExecutionPolicy or using the -ExecutionPolicy flag.
# ===========================================================
# Get-ExecutionPolicy (no scope) returns the *effective* policy for this session.
# If run via -ExecutionPolicy Bypass it returns Bypass, so we won't loop infinitely.
$effectivePolicy = Get-ExecutionPolicy -ErrorAction SilentlyContinue
if ($effectivePolicy -in @('Restricted', 'AllSigned')) {
    Write-Host "    [!] Windows restricts running unsigned scripts here." -ForegroundColor Yellow
    Write-Host "    [!] Automatically re-launching with -ExecutionPolicy Bypass ..." -ForegroundColor Yellow
    $self = $MyInvocation.MyCommand.Path
    $bypassArgs = @("-ExecutionPolicy", "Bypass", "-File", $self) + $args
    & powershell.exe $bypassArgs
    exit $LASTEXITCODE
}

# ---------- PATHS ----------
$ScriptRoot   = $PSScriptRoot
$ConfigPath   = Join-Path $ScriptRoot "deploy.config.json"
$SecretsPath  = Join-Path $ScriptRoot "deploy.secrets.json"
$SecretsExamplePath = Join-Path $ScriptRoot "deploy.secrets.example.json"

# ---------- DEFAULT CONFIG ----------
$DefaultConfig = @{
    FrontendRepo = "https://github.com/Posuza/ESS_MO_Fronend.git"
    BackendRepo  = "https://github.com/Posuza/ESS_MO_Backend.git"
    FrontendPort = 3009
    BackendPort  = 8009
    CaddyPort    = 8089
    PublicUrl    = "http://localhost:8089"
    LocalUrl     = "http://localhost:8089"
    ApiPrefix    = "/api/v1"
    InstallRoot  = $null
    TunnelTarget = "caddy"     # what the Cloudflare tunnel exposes: caddy | frontend | backend | custom
    TunnelUrl    = $null       # resolved URL, auto-set from TunnelTarget + port
}

# ---------- GLOBAL STATE ----------
$script:installedComponents = @()   # Track for rollback
$script:startTime = $null
$script:logFile = $null
$script:dryRun = $DryRun
$script:hasErrors = $false
$script:headless = $Force -or ($Components.Count -gt 0)

# ===========================================================
# LOGGING
# ===========================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    if ($script:logFile) {
        Add-Content -Path $script:logFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Initialize-Logger {
    param($Config)
    $logsDir = Join-Path $Config.InstallRoot "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }
    $script:startTime = Get-Date
    $timestamp = $script:startTime.ToString("yyyyMMdd-HHmmss")
    $script:logFile = Join-Path $logsDir "deploy-$timestamp.log"
    Write-Log "=== Deployment started ===" -Level "START"
    Write-Log "Config: $ConfigPath" -Level "INFO"
    Write-Log "Install root: $($Config.InstallRoot)" -Level "INFO"
    if ($script:dryRun) {
        Write-Log "DRY RUN MODE - no changes will be made" -Level "WARN"
    }
}

# ===========================================================
# OUTPUT HELPERS
# ===========================================================
function Write-Step    ($msg) { Write-Host "`n[*] $msg" -ForegroundColor Yellow; Write-Log "STEP: $msg" }
function Write-Success ($msg) { Write-Host "    $msg"   -ForegroundColor Green;   Write-Log "OK: $msg" }
function Write-Err     ($msg) { Write-Host "    $msg"   -ForegroundColor Red;     Write-Log "ERROR: $msg"; $script:hasErrors = $true }
function Write-Warn    ($msg) { Write-Host "    $msg"   -ForegroundColor DarkYellow; Write-Log "WARN: $msg" }

# ===========================================================
# SPINNER - rotating stick animation during long operations
# ===========================================================
function Start-Spinner {
    param([string]$Message)
    if ($script:headless -or $script:dryRun) { return }

    # Use a runspace so the spinner runs in a separate thread
    $script:spinnerPS = [PowerShell]::Create()
    $null = $script:spinnerPS.AddScript({
        param($msg)
        $chars = @('|', '/', '-', '\')
        $i = 0
        try {
            while ($true) {
                [System.Console]::Write("`r $($chars[$i % 4]) $msg ")
                Start-Sleep -Milliseconds 200
                $i++
            }
        } catch {
            # Expected when the spinner is stopped
        }
    }).AddArgument($Message)

    $script:spinnerAsync = $script:spinnerPS.BeginInvoke()
}

function Stop-Spinner {
    if ($null -eq $script:spinnerPS) { return }
    try {
        $script:spinnerPS.Stop()
        Start-Sleep -Milliseconds 150  # Let the thread settle
        $script:spinnerPS.Dispose()
    } catch {}
    # Clear the spinner line
    [System.Console]::Write("`r" + " " * 70 + "`r")
    $script:spinnerPS = $null
    $script:spinnerAsync = $null
}

# Y/n confirmation prompt. Pressing Enter alone accepts the default.
function Confirm-Step {
    param([string]$Message, [bool]$DefaultYes = $true)
    if ($script:headless) { return $DefaultYes }
    $suffix = if ($DefaultYes) { "(Y/n)" } else { "(y/N)" }
    $resp = Read-Host "$Message $suffix"
    if ([string]::IsNullOrWhiteSpace($resp)) { return $DefaultYes }
    return $resp -match '^[Yy]'
}

# ===========================================================
# CONFIG (non-secret settings)
# ===========================================================
function Get-DeployConfig {
    if (Test-Path $ConfigPath) {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        # Ensure all fields exist (may be missing from older config files)
        @('InstallRoot', 'TunnelTarget', 'TunnelUrl', 'LocalUrl') | ForEach-Object {
            if (-not ($cfg | Get-Member -Name $_ -ErrorAction SilentlyContinue)) {
                Add-Member -InputObject $cfg -NotePropertyName $_ -NotePropertyValue $DefaultConfig[$_]
            }
        }
        return $cfg
    }
    Write-Warn "Config file not found, creating default at $ConfigPath"
    $cfg = [PSCustomObject]$DefaultConfig
    $cfg | ConvertTo-Json | Set-Content $ConfigPath
    return $cfg
}

function Save-DeployConfig {
    param($Config)
    $Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath
    Write-Log "Config saved to $ConfigPath"
}

function Select-InstallDrive {
    param($Config)

    # Collect all available drives (any letter that physically exists)
    $availDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[A-Z]$' -and (Test-Path "$($_.Name):\") } |
        ForEach-Object { $_.Name.ToUpper() } |
        Sort-Object

    if ($availDrives.Count -eq 0) {
        Write-Err "No valid drive found. Cannot proceed."
        Write-Log "No valid drives detected" -Level "ERROR"
        return $null
    }

    if ($script:headless) {
        # Headless mode: must have InstallRoot set in config
        if ([string]::IsNullOrWhiteSpace($Config.InstallRoot)) {
            Write-Err "InstallRoot not set in deploy.config.json. Run interactively first or set a path."
            Write-Log "InstallRoot missing in headless mode" -Level "ERROR"
            return $null
        }
        $drive = [System.IO.Path]::GetPathRoot($Config.InstallRoot)
        $driveLetter = $drive.TrimEnd('\').TrimEnd(':')
        if ($driveLetter -notin $availDrives) {
            Write-Err "Drive $drive does not exist. Available: $($availDrives -join ', ')"
            Write-Log "Configured drive $drive not found among available drives" -Level "ERROR"
            return $null
        }
        return $Config.InstallRoot
    }

    # Show what's available
    $hasCurrent = -not [string]::IsNullOrWhiteSpace($Config.InstallRoot)
    $currentLetter = if ($hasCurrent) { ([System.IO.Path]::GetPathRoot($Config.InstallRoot).TrimEnd('\')).TrimEnd(':') } else { $availDrives[0] }
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Install Location" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    if ($hasCurrent) {
        Write-Host " Current: $($Config.InstallRoot)" -ForegroundColor Gray
    }
    Write-Host " Available drives: $($availDrives -join ', ')" -ForegroundColor Gray
    Write-Host ""

    $driveList = $availDrives -join ', or '
    $valid = $false
    do {
        if ($hasCurrent) {
            $prompt = "Select install drive: $driveList (or press Enter for current)"
        } else {
            $prompt = "Select install drive: $driveList"
        }
        $choice = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($choice)) {
            if ($hasCurrent) {
                $choice = $currentLetter
            } else {
                Write-Err "Please select a drive."
                continue
            }
        }
        $choice = $choice.ToUpper().TrimEnd('\').TrimEnd(':')

        if ($choice -notin $availDrives) {
            Write-Err "Only available drives: $($availDrives -join ', ')"
            continue
        }

        $valid = $true
    } while (-not $valid)

    $newRoot = "$choice`:\Ess_Mo"

    if (-not $hasCurrent -or $newRoot -ne $Config.InstallRoot) {
        $Config.InstallRoot = $newRoot
        Save-DeployConfig -Config $Config
        Write-Success "Install path set to: $newRoot"
        Write-Log "Install path changed to: $newRoot"
    }

    return $Config.InstallRoot
}

function Select-CaddyPort {
    param($Config)

    if ($script:headless) {
        # Headless: use whatever is in config or default
        if (-not $Config.CaddyPort -or $Config.CaddyPort -eq 0) {
            $Config.CaddyPort = 8089
        }
        return $Config.CaddyPort
    }

    $hasCurrent = ($Config.CaddyPort -and $Config.CaddyPort -ne 0)
    $defaultPort = if ($hasCurrent) { $Config.CaddyPort } else { 8089 }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Caddy Proxy Port" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Caddy is the reverse proxy that exposes the app to the network." -ForegroundColor Gray
    if ($hasCurrent) {
        Write-Host " Current: $($Config.CaddyPort)" -ForegroundColor Gray
    }
    Write-Host ""

    $valid = $false
    do {
        $prompt = "Enter Caddy port [$defaultPort]"
        $choice = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = $defaultPort
        }

        # Validate it's a number between 1 and 65535
        if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt 65535) {
            Write-Err "Enter a valid port number (1-65535)."
            continue
        }

        $valid = $true
    } while (-not $valid)

    $newPort = [int]$choice

    if (-not $hasCurrent -or $newPort -ne $Config.CaddyPort) {
        $Config.CaddyPort = $newPort
        Save-DeployConfig -Config $Config
        Write-Success "Caddy port set to: $newPort"
        Write-Log "Caddy port changed to: $newPort"
    }

    return $Config.CaddyPort
}

function Select-PublicUrl {
    param($Config)

    if ($script:headless) {
        if ([string]::IsNullOrWhiteSpace($Config.PublicUrl)) {
            $Config.PublicUrl = Resolve-TunnelUrl -Config $Config
        }
        return $Config.PublicUrl
    }

    # Try to read current Cloudflare tunnel URL
    $cfTunnelUrl = $null
    # First try dedicated tunnel URL file (written by Start-AllServices), then parse log
    $urlFile = Join-Path $Config.InstallRoot "cloudflare\current_tunnel_url.txt"
    if (Test-Path $urlFile) {
        $cfTunnelUrl = Get-Content $urlFile -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $cfTunnelUrl) {
        $cfLog = Join-Path $Config.InstallRoot "cloudflare\cloudflare.log"
        if (Test-Path $cfLog) {
            $cfTunnelUrl = Get-Content $cfLog -ErrorAction SilentlyContinue |
                Select-String -Pattern "https://[a-zA-Z0-9-]+\.trycloudflare\.com" |
                ForEach-Object { $_.Matches.Value } | Select-Object -Last 1
        }
    }

    $hasCurrent = -not [string]::IsNullOrWhiteSpace($Config.PublicUrl)

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Public URL" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " The public URL where users access the app." -ForegroundColor Gray
    if ($hasCurrent) {
        Write-Host " Current config : $($Config.PublicUrl)" -ForegroundColor Gray
    }
    if ($cfTunnelUrl) {
        Write-Host " Cloudflare tunnel: $cfTunnelUrl" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host " 1) Keep current" -ForegroundColor Gray
    if ($cfTunnelUrl) {
        Write-Host " 2) Use Cloudflare tunnel URL (auto-refreshed on each restart)" -ForegroundColor Gray
        Write-Host " 3) Enter custom URL / domain (won't be overwritten)" -ForegroundColor Gray
    } else {
        Write-Host " 2) Enter custom URL / domain" -ForegroundColor Gray
    }
    Write-Host ""

    $choice = $null
    $maxOpt = if ($cfTunnelUrl) { 3 } else { 2 }
    do {
        $opt = Read-Host "Select option [1]"
        if ([string]::IsNullOrWhiteSpace($opt)) { $opt = "1" }
        switch ($opt) {
            "1" {
                if ($hasCurrent) { $choice = $Config.PublicUrl }
                else { Write-Err "No current URL set. Pick another option." }
            }
            "2" {
                if ($cfTunnelUrl) {
                    $choice = $cfTunnelUrl
                    # Also update backend .env immediately
                    $envPath = Join-Path $Config.InstallRoot "backend\.env"
                    if (Test-Path $envPath) {
                        (Get-Content $envPath) -replace '^FRONTEND_URL=.*', "FRONTEND_URL=$cfTunnelUrl" | Set-Content $envPath
                        Write-Success "Backend .env FRONTEND_URL updated"
                    }
                }
                else {
                    $custom = Read-Host "Enter public URL (e.g. https://yourdomain.com)"
                    if ($custom -match '^https?://') { $choice = $custom }
                    else { Write-Err "Enter a URL starting with http:// or https://" }
                }
            }
            "3" {
                if ($cfTunnelUrl) {
                    $custom = Read-Host "Enter public URL (e.g. https://yourdomain.com)"
                    if ($custom -match '^https?://') { $choice = $custom }
                    else { Write-Err "Enter a URL starting with http:// or https://" }
                } else { Write-Err "Invalid option." }
            }
            default { Write-Err "Select 1-$maxOpt" }
        }
    } while ($null -eq $choice)

    if ($choice -ne $Config.PublicUrl) {
        $Config.PublicUrl = $choice
        Save-DeployConfig -Config $Config
        Write-Success "Public URL set to: $choice"
        Write-Log "Public URL changed to: $choice"
    }

    return $Config.PublicUrl
}

function Resolve-TunnelUrl {
    param($Config)
    switch ($Config.TunnelTarget) {
        "caddy"    { return "http://127.0.0.1:$($Config.CaddyPort)" }
        "frontend" { return "http://127.0.0.1:$($Config.FrontendPort)" }
        "backend"  { return "http://127.0.0.1:$($Config.BackendPort)" }
        "custom"   {
            if ([string]::IsNullOrWhiteSpace($Config.TunnelUrl)) {
                return "http://127.0.0.1:$($Config.CaddyPort)"
            }
            return $Config.TunnelUrl
        }
        default { return "http://127.0.0.1:$($Config.CaddyPort)" }
    }
}

function Select-TunnelTarget {
    param($Config)

    if ($script:headless) {
        $Config.TunnelUrl = Resolve-TunnelUrl -Config $Config
        return $Config.TunnelUrl
    }

    $currentUrl = Resolve-TunnelUrl -Config $Config

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Cloudflare Tunnel Target" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " What should the Cloudflare tunnel expose?" -ForegroundColor Gray
    Write-Host " Current: $currentUrl" -ForegroundColor Gray
    Write-Host ""
    Write-Host " 1) Caddy reverse proxy  (port $($Config.CaddyPort))" -ForegroundColor Gray
    Write-Host " 2) Frontend directly     (port $($Config.FrontendPort))" -ForegroundColor Gray
    Write-Host " 3) Backend directly      (port $($Config.BackendPort))" -ForegroundColor Gray
    Write-Host " 4) Custom URL / port" -ForegroundColor Gray
    Write-Host ""

    $valid = $false
    do {
        $choice = Read-Host "Select target [current: $($Config.TunnelTarget)]"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = switch ($Config.TunnelTarget) {
                "caddy"    { "1" }
                "frontend" { "2" }
                "backend"  { "3" }
                "custom"   { "4" }
                default    { "1" }
            }
        }
        switch ($choice) {
            "1" {
                $Config.TunnelTarget = "caddy"
                $Config.TunnelUrl = "http://127.0.0.1:$($Config.CaddyPort)"
                $valid = $true
            }
            "2" {
                $Config.TunnelTarget = "frontend"
                $Config.TunnelUrl = "http://127.0.0.1:$($Config.FrontendPort)"
                $valid = $true
            }
            "3" {
                $Config.TunnelTarget = "backend"
                $Config.TunnelUrl = "http://127.0.0.1:$($Config.BackendPort)"
                $valid = $true
            }
            "4" {
                $customUrl = Read-Host "Enter custom URL (e.g. http://127.0.0.1:3009)"
                if ($customUrl -match '^https?://') {
                    $Config.TunnelTarget = "custom"
                    $Config.TunnelUrl = $customUrl
                    $valid = $true
                } else {
                    Write-Err "Enter a valid URL starting with http:// or https://"
                }
            }
            default { Write-Err "Select 1-4" }
        }
    } while (-not $valid)

    Save-DeployConfig -Config $Config
    Write-Success "Tunnel target set to: $($Config.TunnelUrl)"
    Write-Log "Tunnel target changed to: $($Config.TunnelTarget) -> $($Config.TunnelUrl)"
    return $Config.TunnelUrl
}

function Initialize-InstallRoot {
    param($Config)
    if ($script:dryRun) { Write-Warn "[DRY-RUN] Would create: $($Config.InstallRoot)"; return }
    New-Item -Path $Config.InstallRoot -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $Config.InstallRoot "logs") -ItemType Directory -Force | Out-Null
    Write-Log "Install root created at $($Config.InstallRoot)"
}

# ===========================================================
# SECRETS (DB / SMTP credentials, stored outside the script)
# Nested structure: db.host, db.port, db.name, db.user, db.password
#                   smtp.host, smtp.port, smtp.user, smtp.pass, smtp.from
# ===========================================================
function Protect-SecretsFile {
    $gitignore = Join-Path $PSScriptRoot ".gitignore"
    $entry = "deploy.secrets.json"
    if (-not (Test-Path $gitignore)) {
        Set-Content -Path $gitignore -Value $entry
        Write-Log "Created .gitignore with $entry"
    } elseif (-not (Select-String -Path $gitignore -Pattern ([regex]::Escape($entry)) -Quiet)) {
        Add-Content -Path $gitignore -Value $entry
        Write-Log "Added $entry to .gitignore"
    }
}

function ConvertFrom-SecureToPlain {
    param($SecureString)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-OrCreateSecrets {
    if ($script:headless) {
        if (Test-Path $SecretsPath) {
            Write-Log "Secrets loaded from $SecretsPath"
            return Get-Content $SecretsPath -Raw | ConvertFrom-Json
        }
        Write-Err "No secrets file found and running in headless mode. Create deploy.secrets.json first."
        Write-Host "  Template: $SecretsExamplePath" -ForegroundColor Gray
        exit 1
    }

    # Ask user: load from file or enter credentials manually
    do {
        $useFile = Read-Host "Load DB/SMTP credentials from deploy.secrets.json? (Y/n)  n = enter manually"
        if ($useFile -eq '' -or $useFile -match '^[Yy]') {
            if (Test-Path $SecretsPath) {
                Write-Success "Secrets loaded from $SecretsPath"
                Write-Log "Secrets loaded from $SecretsPath"
                return Get-Content $SecretsPath -Raw | ConvertFrom-Json
            } else {
                Write-Warn "File not found: $SecretsPath"
                Write-Host "  Place deploy.secrets.json next to this script, or type 'n' to enter credentials manually." -ForegroundColor Gray
                # Loop back and ask again
            }
        } else {
            break
        }
    } while ($true)

    Write-Host "These are saved locally only and used to generate the backend's .env file.`n" -ForegroundColor Gray

    # Database settings
    Write-Host "-- Database --" -ForegroundColor Cyan
    $dbHostIn = Read-Host "DB Host [192.168.1.140]";  if (-not $dbHostIn) { $dbHostIn = "192.168.1.140" }
    $dbPort   = Read-Host "DB Port [3306]";            if (-not $dbPort)   { $dbPort   = "3306" }
    $dbUser   = Read-Host "DB User [root]";            if (-not $dbUser)   { $dbUser   = "root" }
    $dbName   = Read-Host "DB Name [ess]";             if (-not $dbName)   { $dbName   = "ess" }
    $dbPassSec   = Read-Host "DB Password" -AsSecureString

    # SMTP settings
    Write-Host "-- SMTP --" -ForegroundColor Cyan
    $smtpHostIn  = Read-Host "SMTP Host [smtp.gmail.com]"; if (-not $smtpHostIn) { $smtpHostIn = "smtp.gmail.com" }
    $smtpPort    = Read-Host "SMTP Port [587]";        if (-not $smtpPort) { $smtpPort = "587" }
    $smtpUser    = Read-Host "SMTP User (email address)"
    $smtpPassSec = Read-Host "SMTP App Password" -AsSecureString
    $emailFrom   = Read-Host "Email 'From' address [$smtpUser]"; if (-not $emailFrom) { $emailFrom = $smtpUser }

    $secrets = [PSCustomObject]@{
        db = [PSCustomObject]@{
            host     = $dbHostIn
            port     = $dbPort
            name     = $dbName
            user     = $dbUser
            password = (ConvertFrom-SecureToPlain $dbPassSec)
        }
        smtp = [PSCustomObject]@{
            host = $smtpHostIn
            port = $smtpPort
            user = $smtpUser
            pass = (ConvertFrom-SecureToPlain $smtpPassSec)
            from = $emailFrom
        }
    }
    $secrets | ConvertTo-Json | Set-Content $SecretsPath
    Protect-SecretsFile
    Write-Success "Saved to $SecretsPath (excluded from git via .gitignore)."
    Write-Log "Secrets created at $SecretsPath"
    return $secrets
}

# ===========================================================
# PREREQUISITES
# ===========================================================
# ===========================================================
# PREREQUISITES
# ===========================================================
function Test-Prerequisites {
    Write-Step "Checking prerequisites"
    $ok = $true
    $missing = @()
    $installed = @()

    $tools = @(
        @{ Cmd = "git";    Name = "Git";          WingetId = "Git.Git";           Url = "https://git-scm.com" },
        @{ Cmd = "node";   Name = "Node.js 22+";  WingetId = "OpenJS.NodeJS.LTS"; Url = "https://nodejs.org" },
        @{ Cmd = "python"; Name = "Python 3.13+"; WingetId = "Python.Python.3.13"; Url = "https://python.org" }
    )

    # Pass 1: check everything and report
    Write-Host ""
    foreach ($tool in $tools) {
        if (Get-Command $tool.Cmd -ErrorAction SilentlyContinue) {
            Write-Host "    $($tool.Name): OK" -ForegroundColor Green
            $installed += $tool
        } else {
            Write-Host "    $($tool.Name): MISSING" -ForegroundColor Red
            $missing += $tool
        }
    }

    # Servy check
    if (Get-Command servy-cli -ErrorAction SilentlyContinue) {
        Write-Host "    Servy: OK" -ForegroundColor Green
    } else {
        Write-Host "    Servy: MISSING" -ForegroundColor Red
        $missing += @{ Cmd = "servy-cli"; Name = "Servy CLI"; WingetId = "servy"; Url = "https://github.com/servy-community/servy" }
    }

    Write-Host ""

    # Pass 2: install all missing at once
    if ($missing.Count -gt 0) {
        $missingNames = ($missing | ForEach-Object { $_.Name }) -join ', '
        if ($script:headless) {
            Write-Err "Missing prerequisites (headless mode): $missingNames"
            Write-Log "Missing prerequisites (headless): $missingNames" -Level "ERROR"
            return $false
        }
        if (Confirm-Step "Install missing prerequisites: $missingNames?" -DefaultYes:$true) {
            $allSucceeded = $true
            foreach ($tool in $missing) {
                Write-Host "    Installing $($tool.Name)..." -ForegroundColor Gray
                Write-Log "Installing $($tool.Name) via winget ($($tool.WingetId))"
                if ($tool.WingetId -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                    winget install $tool.WingetId --accept-package-agreements --silent 2>&1 | Out-Null
                }
                # Try downloading for servy if winget didn't work
                if (-not (Get-Command $tool.Cmd -ErrorAction SilentlyContinue)) {
                    # Refresh PATH
                    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
                    if (-not (Get-Command $tool.Cmd -ErrorAction SilentlyContinue)) {
                        Write-Err "    $($tool.Name) install may have failed."
                        Write-Host "    Install manually: $($tool.Url)" -ForegroundColor Gray
                        $allSucceeded = $false
                    } else {
                        Write-Success "    $($tool.Name): installed"
                    }
                } else {
                    Write-Success "    $($tool.Name): installed"
                }
            }
            # Refresh PATH once more after all installs
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
            if ($allSucceeded) { Write-Success "All prerequisites installed." }
        } else {
            Write-Warn "Skipping installation. Deployment may fail."
            $ok = $false
        }
    } else {
        Write-Success "All prerequisites are already installed."
    }

    # Pass 3: offer to update existing tools
    if ($installed.Count -gt 0 -and -not $script:headless) {
        if (Confirm-Step "Update existing tools to latest versions?" -DefaultYes:$false) {
            foreach ($tool in $installed) {
                if ($tool.WingetId -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                    Write-Host "    Updating $($tool.Name)..." -ForegroundColor Gray
                    Write-Log "Updating $($tool.Name) via winget"
                    winget upgrade $tool.WingetId --accept-package-agreements --silent 2>&1 | Out-Null
                }
            }
            Write-Success "Updates applied."
        }
    }

    if (-not $ok) { return $false }
    return $true
}

# ===========================================================
# HEALTH VERIFICATION
# ===========================================================
function Test-Endpoint {
    param([string]$Url, [string]$Name, [int]$TimeoutSec = 5)
    try {
        Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
        Write-Success "$Name ($Url): responding"
        Write-Log "Health check passed: $Name ($Url)"
        return $true
    } catch {
        Write-Err "$Name ($Url): not responding"
        Write-Log "Health check failed: $Name ($Url) - $_" -Level "ERROR"
        return $false
    }
}

function Verify-Health {
    param($Config)
    $allOk = $true
    Write-Step "Verifying service health"

    if (Get-Service -Name ess-mo-backend -ErrorAction SilentlyContinue) {
        if (-not (Test-Endpoint -Url "http://localhost:$($Config.BackendPort)$($Config.ApiPrefix)/health" -Name "Backend API")) { $allOk = $false }
    }
    if (Get-Service -Name ess-mo-frontend -ErrorAction SilentlyContinue) {
        if (-not (Test-Endpoint -Url "http://localhost:$($Config.FrontendPort)" -Name "Frontend")) { $allOk = $false }
    }
    if (Get-Service -Name ess-mo-caddy -ErrorAction SilentlyContinue) {
        if (-not (Test-Endpoint -Url "http://localhost:$($Config.CaddyPort)$($Config.ApiPrefix)/health" -Name "Caddy proxy")) { $allOk = $false }
    }

    return $allOk
}

# ===========================================================
# COMPONENT INSTALLERS
# Service name pattern: ess-mo-<key>   Folder pattern: <InstallRoot>\<key>
# ===========================================================
function Install-Frontend {
    param($Config)
    Initialize-InstallRoot -Config $Config
    Write-Step "Installing Frontend"

    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would install Frontend from $($Config.FrontendRepo) on port $($Config.FrontendPort)"
        return $true
    }

    try {
        $tempDir = Join-Path $env:TEMP "essmo_frontend_clone"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

        git clone $Config.FrontendRepo $tempDir 2>&1 |
            Tee-Object -FilePath (Join-Path $Config.InstallRoot "logs\frontend_clone.log")

        $destDir = Join-Path $Config.InstallRoot "frontend"
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$tempDir\*" -Destination $destDir -Recurse -Force

        Push-Location $destDir
        npm install 2>&1 | Tee-Object -FilePath (Join-Path $Config.InstallRoot "logs\frontend_install.log")
        npm install serve 2>&1 | Tee-Object -FilePath (Join-Path $Config.InstallRoot "logs\frontend_serve.log")
        $env:VITE_API_URL = $Config.ApiPrefix
        npm run build 2>&1 | Tee-Object -FilePath (Join-Path $Config.InstallRoot "logs\frontend_build.log")
        Pop-Location

        if (-not (Test-Path (Join-Path $destDir "dist"))) {
            throw "Frontend build failed - dist folder not created"
        }
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        # cmd.exe needs the inner command double-quoted, and Servy needs that
        # quoting preserved literally -> hence the doubled quotes here.
        $paramStr = "/c `"`"cd /d $destDir && npx serve -s dist -l $($Config.FrontendPort)`"`""

        servy-cli uninstall --name="ess-mo-frontend" --silent 2>&1 | Out-Null
        servy-cli install --name="ess-mo-frontend" --path="C:\Windows\System32\cmd.exe" --params="$paramStr"

        if (-not (Get-Service -Name ess-mo-frontend -ErrorAction SilentlyContinue)) {
            throw "Service 'ess-mo-frontend' was not created by servy-cli"
        }
        Write-Success "Frontend service installed."
        $script:installedComponents += "frontend"
        Write-Log "Frontend installed successfully on port $($Config.FrontendPort)"
        return $true
    } catch {
        Write-Err "Frontend setup failed: $_"
        Write-Log "Frontend installation failed: $_" -Level "ERROR"
        return $false
    }
}

function Install-Backend {
    param($Config, $Secrets)
    Initialize-InstallRoot -Config $Config
    Write-Step "Installing Backend"

    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would install Backend from $($Config.BackendRepo) on port $($Config.BackendPort)"
        return $true
    }

    try {
        $tempDir = Join-Path $env:TEMP "essmo_backend_clone"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

        git clone $Config.BackendRepo $tempDir 2>&1 |
            Tee-Object -FilePath (Join-Path $Config.InstallRoot "logs\backend_clone.log")

        $destDir = Join-Path $Config.InstallRoot "backend"
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$tempDir\*" -Destination $destDir -Recurse -Force

        Push-Location $destDir
        python -m venv venv
        if (-not (Test-Path (Join-Path $destDir "venv\Scripts\python.exe"))) {
            throw "Virtual environment was not created"
        }
        & (Join-Path $destDir "venv\Scripts\pip") install -r requirements.txt 2>&1 |
            Tee-Object -FilePath (Join-Path $Config.InstallRoot "logs\backend_pip.log")
        Pop-Location
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host "    Generating .env file..." -ForegroundColor Gray
        $generatedKey = & (Join-Path $destDir "venv\Scripts\python") -c "import secrets; print(secrets.token_hex(32))"
        $envContent = @"
DB_ENGINE=mysql
DB_HOST=$($Secrets.db.host)
DB_PORT=$($Secrets.db.port)
DB_USER=$($Secrets.db.user)
DB_PASSWORD=$($Secrets.db.password)
DB_NAME=$($Secrets.db.name)

SECRET_KEY=$generatedKey
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30

SMTP_HOST=$($Secrets.smtp.host)
SMTP_PORT=$($Secrets.smtp.port)
SMTP_USER=$($Secrets.smtp.user)
SMTP_PASS=$($Secrets.smtp.pass)
EMAIL_FROM=$($Secrets.smtp.from)
FRONTEND_URL=$($Config.PublicUrl)
"@
        Set-Content -Path (Join-Path $destDir ".env") -Value $envContent -Force

        $pythonExe = Join-Path $destDir "venv\Scripts\python.exe"
        $paramStr = "/c `"`"cd /d $destDir && $pythonExe -m uvicorn app.main:app --host 0.0.0.0 --port $($Config.BackendPort)`"`""

        servy-cli uninstall --name="ess-mo-backend" --silent 2>&1 | Out-Null
        servy-cli install --name="ess-mo-backend" --path="C:\Windows\System32\cmd.exe" --params="$paramStr"

        if (-not (Get-Service -Name ess-mo-backend -ErrorAction SilentlyContinue)) {
            throw "Service 'ess-mo-backend' was not created by servy-cli"
        }
        Write-Success "Backend service installed."
        $script:installedComponents += "backend"
        Write-Log "Backend installed successfully on port $($Config.BackendPort)"
        return $true
    } catch {
        Write-Err "Backend setup failed: $_"
        Write-Log "Backend installation failed: $_" -Level "ERROR"
        return $false
    }
}

function Install-Caddy {
    param($Config)
    Initialize-InstallRoot -Config $Config
    Write-Step "Installing Caddy"

    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would install Caddy proxy on port $($Config.CaddyPort)"
        return $true
    }

    try {
        $caddyDir = Join-Path $Config.InstallRoot "caddy"
        New-Item -Path $caddyDir -ItemType Directory -Force | Out-Null
        $caddyExe = Join-Path $caddyDir "caddy.exe"

        if (-not (Test-Path $caddyExe)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Write-Host "    Downloading Caddy..." -ForegroundColor Gray
            Invoke-WebRequest -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile $caddyExe -UseBasicParsing
            if (-not (Test-Path $caddyExe)) { throw "Caddy download failed" }
            Write-Log "Caddy downloaded from caddyserver.com"
        } else {
            Write-Host "    Caddy already downloaded, skipping." -ForegroundColor Gray
        }

        # Use custom routes from config if available, otherwise defaults
        $caddyRoutes = @()
        if ($Config.CaddyRoutes -and @($Config.CaddyRoutes).Count -gt 0) {
            $caddyRoutes = @($Config.CaddyRoutes)
        } else {
            $caddyRoutes = @(
                [PSCustomObject]@{ Path = "$($Config.ApiPrefix)/*"; Target = "127.0.0.1:$($Config.BackendPort)" }
                [PSCustomObject]@{ Path = "/*";                    Target = "127.0.0.1:$($Config.FrontendPort)" }
            )
        }

        $caddyfilePath = Join-Path $caddyDir "Caddyfile"
        $caddyfileLines = @()
        $caddyfileLines += ":$($Config.CaddyPort) {"
        foreach ($r in $caddyRoutes) {
            $caddyfileLines += "    handle $($r.Path) {"
            $caddyfileLines += "        reverse_proxy $($r.Target)"
            $caddyfileLines += "    }"
        }
        $caddyfileLines += "    header {"
        $caddyfileLines += '        X-Frame-Options "SAMEORIGIN"'
        $caddyfileLines += '        X-Content-Type-Options "nosniff"'
        $caddyfileLines += '        X-XSS-Protection "1; mode=block"'
        $caddyfileLines += "    }"
        $caddyfileLines += "}"
        $caddyfileContent = $caddyfileLines -join "`n"
        Set-Content -Path $caddyfilePath -Value $caddyfileContent -Force

        servy-cli uninstall --name="ess-mo-caddy" --silent 2>&1 | Out-Null
        servy-cli install --name="ess-mo-caddy" --path="$caddyExe" --params="run --config $caddyfilePath"

        if (-not (Get-Service -Name ess-mo-caddy -ErrorAction SilentlyContinue)) {
            throw "Service 'ess-mo-caddy' was not created by servy-cli"
        }
        Write-Success "Caddy service installed."
        $script:installedComponents += "caddy"
        Write-Log "Caddy installed successfully on port $($Config.CaddyPort)"
        return $true
    } catch {
        Write-Err "Caddy setup failed: $_"
        Write-Log "Caddy installation failed: $_" -Level "ERROR"
        return $false
    }
}

function Install-Cloudflare {
    param($Config)
    Initialize-InstallRoot -Config $Config
    Write-Step "Installing Cloudflare Tunnel"

    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would install Cloudflare tunnel for $($Config.TunnelUrl)"
        return $true
    }

    try {
        if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                Write-Host "    cloudflared not found, installing via winget..." -ForegroundColor Gray
                winget install Cloudflare.cloudflared --accept-package-agreements --silent 2>&1 |
                    Tee-Object -FilePath (Join-Path $Config.InstallRoot "logs\cloudflare_install.log")
                $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
            }
        }
        if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
            Write-Warn "cloudflared not available. Install it: winget install Cloudflare.cloudflared"
            return $false
        }

        $cfDir = Join-Path $Config.InstallRoot "cloudflare"
        New-Item -Path $cfDir -ItemType Directory -Force | Out-Null
        $cfPath  = (Get-Command cloudflared).Source
        $logPath = Join-Path $cfDir "cloudflare.log"

        # Resolve tunnel URL (fallback if config is from old version)
        if ([string]::IsNullOrWhiteSpace($Config.TunnelUrl)) {
            $Config.TunnelUrl = Resolve-TunnelUrl -Config $Config
        }

        servy-cli uninstall --name="ess-mo-cloudflare" --silent 2>&1 | Out-Null
        servy-cli install --name="ess-mo-cloudflare" --path="$cfPath" --params="tunnel --url $($Config.TunnelUrl) --logfile $logPath"

        if (-not (Get-Service -Name ess-mo-cloudflare -ErrorAction SilentlyContinue)) {
            throw "Service 'ess-mo-cloudflare' was not created by servy-cli"
        }
        Write-Success "Cloudflare service installed."
        Write-Success "Tunnel exposes: $($Config.TunnelUrl)"
        $script:installedComponents += "cloudflare"
        Write-Log "Cloudflare tunnel installed, target: $($Config.TunnelUrl)"
        return $true
    } catch {
        Write-Err "Cloudflare setup failed: $_"
        Write-Log "Cloudflare installation failed: $_" -Level "ERROR"
        return $false
    }
}

# ===========================================================
# ROLLBACK
# ===========================================================
function Invoke-Rollback {
    param($Config)
    if ($script:installedComponents.Count -eq 0) { return }
    Write-Step "ROLLING BACK installed components"
    Write-Log "Rollback started" -Level "WARN"
    # Roll back in reverse install order
    [array]::Reverse($script:installedComponents)
    foreach ($key in $script:installedComponents) {
        Write-Warn "Rolling back: $key"
        Remove-Component -Key $key -Config $Config -DeleteFiles
        Write-Log "Rolled back: $key" -Level "WARN"
    }
    $script:installedComponents = @()
    Write-Warn "Rollback complete."
}

# ===========================================================
# COMPONENT REGISTRY / DISPATCH
# ===========================================================
function Get-Components {
    return @(
        [PSCustomObject]@{ Num = 1; Key = "frontend";   Service = "ess-mo-frontend";   Display = "Frontend (Node / Vite)" }
        [PSCustomObject]@{ Num = 2; Key = "backend";    Service = "ess-mo-backend";    Display = "Backend (FastAPI)" }
        [PSCustomObject]@{ Num = 3; Key = "caddy";      Service = "ess-mo-caddy";      Display = "Caddy reverse proxy" }
        [PSCustomObject]@{ Num = 4; Key = "cloudflare"; Service = "ess-mo-cloudflare"; Display = "Cloudflare tunnel" }
    )
}

function Invoke-ComponentInstall {
    param($Key, $Config)
    $result = $false
    switch ($Key) {
        "frontend"   { $result = Install-Frontend -Config $Config }
        "backend"    { $secrets = Get-OrCreateSecrets; $result = Install-Backend -Config $Config -Secrets $secrets }
        "caddy"      { $result = Install-Caddy -Config $Config }
        "cloudflare" { Select-TunnelTarget -Config $Config | Out-Null; $result = Install-Cloudflare -Config $Config }
    }
    if (-not $result -and -not $script:dryRun) {
        Write-Err "Component '$Key' failed to install."
        Write-Log "Component install failed: $Key" -Level "ERROR"
        return $false
    }
    return $result
}

function Remove-Component {
    param($Key, $Config, [switch]$DeleteFiles)
    $svcName = "ess-mo-$Key"
    Write-Step "Removing $Key"
    if (-not $script:dryRun) {
        Stop-Service -Name $svcName -ErrorAction SilentlyContinue
        servy-cli uninstall --name="$svcName" --silent 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500

        if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
            Write-Warn "$svcName is still registered - restart your computer and re-run uninstall."
        } else {
            Write-Success "$svcName service removed."
        }

        if ($DeleteFiles) {
            $path = Join-Path $Config.InstallRoot $Key
            if (Test-Path $path) {
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Success "Deleted $path"
            }
        }
    } else {
        Write-Warn "[DRY-RUN] Would remove $Key service and $(if($DeleteFiles){'delete'}else{'keep'}) its files"
    }
    Write-Log "Component removed: $Key"
}

# ===========================================================
# SERVICE CONTROL / STATUS
# ===========================================================
function Start-AllServices {
    param($Config)
    Write-Step "Starting services"
    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would start all installed services"
        return
    }
    $hasCloudflare = $false
    foreach ($c in Get-Components) {
        if (-not (Get-Service -Name $c.Service -ErrorAction SilentlyContinue)) {
            Write-Host "    Skipping $($c.Display) (not installed)" -ForegroundColor Gray
            continue
        }
        try {
            Start-Service -Name $c.Service -ErrorAction Stop
            Write-Success "Started $($c.Display)"
            Write-Log "Service started: $($c.Service)"
            if ($c.Key -eq "cloudflare") { $hasCloudflare = $true }
        } catch {
            Write-Err "Failed to start $($c.Display): $_"
            Write-Log "Failed to start $($c.Service): $_" -Level "ERROR"
        }
    }

    # After starting Cloudflare tunnel, auto-capture its URL to a file
    if ($hasCloudflare) {
        Write-Host "    Waiting for Cloudflare tunnel URL..." -ForegroundColor Gray
        Start-Sleep -Seconds 4
        $cfLog = Join-Path $Config.InstallRoot "cloudflare\cloudflare.log"
        if (Test-Path $cfLog) {
            $tunnelUrl = Get-Content $cfLog -ErrorAction SilentlyContinue |
                Select-String -Pattern "https://[a-zA-Z0-9-]+\.trycloudflare\.com" |
                ForEach-Object { $_.Matches.Value } | Select-Object -Last 1
            if ($tunnelUrl) {
                Write-Success "Cloudflare tunnel: $tunnelUrl"
                # Save to a dedicated file (source of truth for other functions)
                $urlFile = Join-Path $Config.InstallRoot "cloudflare\current_tunnel_url.txt"
                Set-Content -Path $urlFile -Value $tunnelUrl -Force
                # Refresh backend .env if it currently has a tunnel URL (not a custom domain)
                $envPath = Join-Path $Config.InstallRoot "backend\.env"
                if (Test-Path $envPath) {
                    $currentFrontendUrl = Select-String -Path $envPath -Pattern '^FRONTEND_URL=(.*)$' | ForEach-Object { $_.Matches.Groups[1].Value }
                    if ($currentFrontendUrl -match '\.trycloudflare\.com') {
                        (Get-Content $envPath) -replace '^FRONTEND_URL=.*', "FRONTEND_URL=$tunnelUrl" | Set-Content $envPath
                        Write-Success "Backend .env FRONTEND_URL refreshed"
                        Write-Log "Refreshed backend .env FRONTEND_URL to tunnel: $tunnelUrl"
                    }
                }
            } else {
                Write-Host "    Tunnel URL not yet available - check later via option 8" -ForegroundColor DarkYellow
            }
        }
    }
}

function Stop-AllServices {
    param($Config)
    Write-Step "Stopping services"
    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would stop all running services"
        return
    }
    foreach ($c in Get-Components) {
        if (-not (Get-Service -Name $c.Service -ErrorAction SilentlyContinue)) { continue }
        Stop-Service -Name $c.Service -ErrorAction SilentlyContinue
        Write-Success "Stopped $($c.Display)"
        Write-Log "Service stopped: $($c.Service)"
    }
}

function Show-Status {
    param($Config)
    Write-Step "Service status"
    $rows = foreach ($c in Get-Components) {
        $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Component = $c.Display
            Service   = $c.Service
            State     = if ($svc) { $svc.Status } else { "Not installed" }
        }
    }
    $rows | Format-Table -AutoSize | Out-Host

    # Health checks
    Verify-Health -Config $Config

    # Show Cloudflare tunnel URL if available
    $cfLog = Join-Path $Config.InstallRoot "cloudflare\cloudflare.log"
    if (Test-Path $cfLog) {
        $tunnelUrl = Get-Content $cfLog -ErrorAction SilentlyContinue |
            Select-String -Pattern "https://[a-zA-Z0-9-]+\.trycloudflare\.com" |
            ForEach-Object { $_.Matches.Value } | Select-Object -Last 1
        if ($tunnelUrl) { Write-Success "Cloudflare tunnel: $tunnelUrl" }
    }

    Write-Log "Status check completed"
}

# ===========================================================
# FULL DEPLOYMENT (shared between interactive and headless)
# ===========================================================
function Invoke-FullDeploy {
    param($Config)

    # 1. Validate install drive exists (prompt already happened at entry)
    $drive = [System.IO.Path]::GetPathRoot($Config.InstallRoot)
    if (-not (Test-Path $drive)) {
        Write-Err "Drive $drive does not exist. Select a valid drive from the menu (option 10)."
        Write-Log "Install drive $drive not found" -Level "ERROR"
        return
    }

    Initialize-Logger -Config $Config

    # 2. Quick connectivity check (git repos, npm, pip all need internet)
    Write-Step "Checking network access"
    try {
        $testResult = Invoke-WebRequest -Uri "https://github.com" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-Success "Internet: OK"
        Write-Log "Internet connectivity verified"
    } catch {
        Write-Warn "Internet: unreachable - git clone, npm install, and pip install will fail."
        Write-Log "Internet check failed" -Level "WARN"
        if (-not $script:headless) {
            if (-not (Confirm-Step "Continue without internet?" -DefaultYes:$false)) {
                Write-Warn "Deployment cancelled."
                return
            }
        }
    }

    # 3. Check prerequisites
    $prereqResult = Test-Prerequisites
    if ("BACK" -eq $prereqResult -or -not $prereqResult) {
        if ("BACK" -eq $prereqResult) {
            Write-Warn "Returning to menu."
        } else {
            Write-Err "Resolve missing prerequisites first."
        }
        return
    }
    if (-not $script:headless -or $Components.Count -eq 0 -or ($Components -contains "backend")) {
        $secrets = Get-OrCreateSecrets
    }

    # Determine which components to deploy
    $targetComponents = if ($script:headless -and $Components.Count -gt 0) {
        $Components
    } else {
        @("frontend", "backend", "caddy", "cloudflare")
    }
    $allSucceeded = $true

    if ($targetComponents -contains "frontend") {
        if (Confirm-Step "Install Frontend (port $($Config.FrontendPort))?") {
            Start-Spinner "Installing Frontend ..."
            $frontendOk = Install-Frontend -Config $Config
            Stop-Spinner
            if ($frontendOk) {
                Write-Success "Frontend installed successfully on port $($Config.FrontendPort)"
                Write-Log "Frontend installed successfully on port $($Config.FrontendPort)"
            } else {
                Write-Err "Frontend installation FAILED - check logs for details"
                $allSucceeded = $false
            }
        } else { Write-Warn "Skipped Frontend." }
        if (-not $script:headless) { Read-Host "`nPress Enter to continue" | Out-Null }
    }

    if ($targetComponents -contains "backend") {
        if (Confirm-Step "Install Backend (port $($Config.BackendPort))?") {
            $secrets = Get-OrCreateSecrets
            Start-Spinner "Installing Backend ..."
            $backendOk = Install-Backend -Config $Config -Secrets $secrets
            Stop-Spinner
            if ($backendOk) {
                Write-Success "Backend installed successfully on port $($Config.BackendPort)"
                Write-Log "Backend installed successfully on port $($Config.BackendPort)"
            } else {
                Write-Err "Backend installation FAILED - check logs for details"
                $allSucceeded = $false
            }
        } else { Write-Warn "Skipped Backend." }
        if (-not $script:headless) { Read-Host "`nPress Enter to continue" | Out-Null }
    }

    if ($targetComponents -contains "caddy") {
        if (Confirm-Step "Install Caddy reverse proxy (port $($Config.CaddyPort))?") {
            # Prompt for Caddy port right before installing
            Select-CaddyPort -Config $Config | Out-Null
            Start-Spinner "Installing Caddy ..."
            $caddyOk = Install-Caddy -Config $Config
            Stop-Spinner
            if ($caddyOk) {
                Write-Success "Caddy installed successfully on port $($Config.CaddyPort)"
                Write-Log "Caddy installed successfully on port $($Config.CaddyPort)"
            } else {
                Write-Err "Caddy installation FAILED - check logs for details"
                $allSucceeded = $false
            }
        } else { Write-Warn "Skipped Caddy." }
        if (-not $script:headless) { Read-Host "`nPress Enter to continue" | Out-Null }
    }

    if ($targetComponents -contains "cloudflare") {
        if (Confirm-Step "Expose this app publicly via a Cloudflare quick tunnel?" -DefaultYes:$false) {
            # Prompt: what should the tunnel expose? (Caddy / Frontend / Backend / custom)
            Select-TunnelTarget -Config $Config | Out-Null
            Start-Spinner "Installing Cloudflare tunnel ..."
            $cfOk = Install-Cloudflare -Config $Config
            Stop-Spinner
            if ($cfOk) {
                Write-Success "Cloudflare tunnel installed successfully."
                Write-Log "Cloudflare tunnel installed successfully"
            } else {
                Write-Err "Cloudflare tunnel installation FAILED - check logs for details"
                $allSucceeded = $false
            }
        } else { Write-Warn "Skipped Cloudflare tunnel." }
        if (-not $script:headless) { Read-Host "`nPress Enter to continue" | Out-Null }
    }

    # Roll back on failure (only in non-dry-run mode)
    if (-not $allSucceeded -and -not $script:dryRun) {
        if ($script:headless -or (Confirm-Step "Some components failed. Roll back installed components?" -DefaultYes:$true)) {
            Invoke-Rollback -Config $Config
            Write-Log "Deployment rolled back due to failures" -Level "ERROR"
            return
        }
    }

    # IIS warning - port 80 conflicts with Windows web server
    if ($targetComponents -contains "caddy") {
        if ($Config.CaddyPort -eq 80) {
            Write-Host "    [!] Port 80 is used by IIS (Windows web server)." -ForegroundColor Yellow
            if ($script:headless) {
                Write-Warn "[HEADLESS] Port 80 conflicts with IIS. Set CaddyPort in config to a different value."
                Write-Log "Port 80 conflict with IIS in headless mode" -Level "WARN"
            } elseif (Confirm-Step "Stop IIS to free port 80?") {
                if ($script:dryRun) {
                    Write-Warn "[DRY-RUN] Would stop IIS (W3SVC) and set startup to Disabled"
                } else {
                    Stop-Service -Name W3SVC -ErrorAction SilentlyContinue
                    Set-Service  -Name W3SVC -StartupType Disabled -ErrorAction SilentlyContinue
                    Write-Log "IIS (W3SVC) stopped and disabled"
                }
            } else {
                # User declined to stop IIS - offer alternative port
                $newPort = Read-Host "Enter a different port for Caddy (e.g. 8080, 443, 8443)"
                if ($newPort -match '^\d+$') {
                    $Config.CaddyPort = [int]$newPort
                    Write-Success "Caddy port changed to $($Config.CaddyPort)"
                    Write-Log "Caddy port changed to $($Config.CaddyPort) to avoid IIS conflict"
                } else {
                    Write-Warn "Invalid port. Caddy will attempt port 80 anyway - may conflict with IIS."
                    Write-Log "Invalid port entered for Caddy - keeping port 80" -Level "WARN"
                }
            }
        } else {
            Write-Host "    [i] Caddy uses port $($Config.CaddyPort) - no IIS conflict." -ForegroundColor Gray
            Write-Log "Caddy port $($Config.CaddyPort) - IIS not affected"
        }
    }

    # Start services and verify
    if (Confirm-Step "Start all installed services now?") {
        Start-AllServices -Config $Config
        if (-not $script:dryRun) {
            Start-Sleep -Seconds 5
            Verify-Health -Config $Config
        }
    }

    # Summary
    if ($script:dryRun) {
        Write-Step "DRY RUN COMPLETE - No changes were made"
    } elseif ($allSucceeded) {
        Write-Step "DEPLOYMENT COMPLETE"
        $duration = (Get-Date) - $script:startTime
        Write-Success "Duration: $($duration.Minutes)m $($duration.Seconds)s"
        Write-Success "Log: $($script:logFile)"
    } else {
        Write-Warn "Deployment finished with errors. Check log: $($script:logFile)"
    }
}

# ===========================================================
# MENU
# ===========================================================
function Show-MainMenu {
    param($Config)
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Servy Full-Stack Deployment Manager" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($Config.InstallRoot)) {
        Write-Host " [!] Install path: NOT SET - restart the script to set it" -ForegroundColor Red
    } else {
        Write-Host " Install path: $($Config.InstallRoot)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  1) Check prerequisites" -ForegroundColor White
    Write-Host "  2) Install components" -ForegroundColor White
    Write-Host "  3) Uninstall components" -ForegroundColor White
    Write-Host "  4) Service status / health check" -ForegroundColor White
    Write-Host "  5) Start services" -ForegroundColor White
    Write-Host "  6) Stop services" -ForegroundColor White
    Write-Host "  7) Caddy network config" -ForegroundColor White
    Write-Host "  8) Public network config (Cloudflare / URL)" -ForegroundColor White
    Write-Host "  9) Open logs folder" -ForegroundColor White
    Write-Host "  Q) Quit" -ForegroundColor White
    Write-Host ""
}

function Show-CaddyConfig {
    param($Config)
    do {
        $changed = $false

        # Available targets (services that Caddy can proxy to)
        $targets = @(
            [PSCustomObject]@{ Name = "Frontend (Node / Vite)"; Target = "127.0.0.1:$($Config.FrontendPort)"; DefaultPath = "/*" }
            [PSCustomObject]@{ Name = "Backend (FastAPI)";      Target = "127.0.0.1:$($Config.BackendPort)"; DefaultPath = "$($Config.ApiPrefix)/*" }
        )

        # Current Caddy routes from config (or defaults)
        $routes = @()
        if ($Config.CaddyRoutes -and @($Config.CaddyRoutes).Count -gt 0) {
            $routes = @($Config.CaddyRoutes)
        } else {
            $routes = @(
                [PSCustomObject]@{ Path = "/*";                    Target = "127.0.0.1:$($Config.FrontendPort)"; Label = "Frontend" }
                [PSCustomObject]@{ Path = "$($Config.ApiPrefix)/*"; Target = "127.0.0.1:$($Config.BackendPort)";  Label = "Backend" }
            )
        }

        # Determine which targets are NOT yet registered as routes
        $routedTargets = @($routes | ForEach-Object { $_.Target })
        $availableTargets = @($targets | Where-Object { $_.Target -notin $routedTargets })

        Write-Host ""
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host " Caddy Reverse Proxy Configuration" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host " Caddy listener : 127.0.0.1:$($Config.CaddyPort)" -ForegroundColor White
        Write-Host ""
        Write-Host " Available targets:" -ForegroundColor White
        if ($availableTargets.Count -gt 0) {
            $i = 1
            foreach ($t in $availableTargets) {
                Write-Host "   $i) $($t.Name) → $($t.Target)" -ForegroundColor Gray
                $i++
            }
        } else {
            Write-Host "   (all targets already registered)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host " Caddy routes:" -ForegroundColor White
        for ($i = 0; $i -lt $routes.Count; $i++) {
            Write-Host "   $($i+1)) $($routes[$i].Path) → $($routes[$i].Target)  [$($routes[$i].Label)]" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host " 1) Add route to Caddy" -ForegroundColor Gray
        Write-Host " 2) Remove route from Caddy" -ForegroundColor Gray
        Write-Host " 3) Change Caddy listening port  [$($Config.CaddyPort)]" -ForegroundColor Gray
        Write-Host " B) Back to main menu" -ForegroundColor Gray
        Write-Host ""
        $sub = Read-Host "Select option"

        switch ($sub) {
            "1" {
                # --- Add route ---
                $addOptions = @()
                $optNum = 1
                foreach ($t in $availableTargets) {
                    $addOptions += [PSCustomObject]@{ OptNum = $optNum; Name = $t.Name; Target = $t.Target; DefaultPath = $t.DefaultPath }
                    $optNum++
                }
                $addOptions += [PSCustomObject]@{ OptNum = $optNum; Name = "Custom target (enter your own)"; Target = $null; DefaultPath = "" }

                Write-Host ""
                Write-Host "--- Add Route ---" -ForegroundColor Cyan
                foreach ($o in $addOptions) {
                    if ($o.Target) {
                        Write-Host " $($o.OptNum)) $($o.Name)  →  $($o.Target)" -ForegroundColor Gray
                    } else {
                        Write-Host " $($o.OptNum)) $($o.Name)" -ForegroundColor Gray
                    }
                }
                Write-Host " B) Back" -ForegroundColor Gray
                $pick = Read-Host "`nSelect target"
                if ($pick -match '^[Bb]$') { break }

                $targetAddr = $null
                $defaultPath = $null
                $label = $null

                if ($pick -match '^\d+$') {
                    $selected = $addOptions | Where-Object { $_.OptNum -eq [int]$pick } | Select-Object -First 1
                    if ($selected) {
                        if (-not $selected.Target) {
                            # Custom target
                            $targetAddr = Read-Host "Enter target address (e.g. 127.0.0.1:9090)"
                            if (-not $targetAddr) { break }
                            $label = Read-Host "Enter label/name for this route"
                            if (-not $label) { $label = "Custom" }
                        } else {
                            $targetAddr = $selected.Target
                            $defaultPath = $selected.DefaultPath
                            $label = $selected.Name
                        }
                    }
                }

                if ($targetAddr) {
                    $path = Read-Host "Path prefix (e.g. /custom/*) [$defaultPath]"
                    if (-not $path) { $path = $defaultPath }
                    if ($path -and $path.StartsWith('/')) {
                        $routes += [PSCustomObject]@{ Path = $path; Target = $targetAddr; Label = $label }
                        $Config | Add-Member -NotePropertyName 'CaddyRoutes' -NotePropertyValue $routes -Force
                        Save-DeployConfig -Config $Config
                        $changed = $true
                        Write-Success "Route added: $path → $targetAddr"
                    } else {
                        Write-Err "Path must start with /"
                    }
                }
            }
            "2" {
                # --- Remove route ---
                if ($routes.Count -eq 0) {
                    Write-Warn "No routes to remove."
                    break
                }
                Write-Host ""
                Write-Host "--- Remove Route ---" -ForegroundColor Cyan
                for ($i = 0; $i -lt $routes.Count; $i++) {
                    Write-Host " $($i+1)) $($routes[$i].Path) → $($routes[$i].Target)  [$($routes[$i].Label)]" -ForegroundColor Gray
                }
                Write-Host " B) Back" -ForegroundColor Gray
                $pick = Read-Host "`nSelect route to remove"
                if ($pick -match '^[Bb]$') { break }
                if ($pick -match '^\d+$') {
                    $idx = [int]$pick - 1
                    if ($idx -ge 0 -and $idx -lt $routes.Count) {
                        if (Confirm-Step "Remove route '$($routes[$idx].Path) → $($routes[$idx].Target)'?" -DefaultYes:$false) {
                            $routes = @($routes | Where-Object { $_ -ne $routes[$idx] })
                            if ($routes.Count -gt 0) {
                                $Config | Add-Member -NotePropertyName 'CaddyRoutes' -NotePropertyValue $routes -Force
                            } else {
                                $Config.PSObject.Properties.Remove('CaddyRoutes')
                            }
                            Save-DeployConfig -Config $Config
                            $changed = $true
                            Write-Success "Route removed."
                        }
                    } else {
                        Write-Err "Invalid route number."
                    }
                }
            }
            "3" {
                Select-CaddyPort -Config $Config | Out-Null
                $changed = $true
            }
            "[Bb]" { break }
            default { Write-Warn "Unknown option." }
        }

        # If Caddy is installed and something changed, regenerate Caddyfile and restart
        if ($changed -and (Get-Service -Name ess-mo-caddy -ErrorAction SilentlyContinue)) {
            if (Confirm-Step "Regenerate Caddyfile and restart Caddy?" -DefaultYes:$true) {
                $caddyDir = Join-Path $Config.InstallRoot "caddy"
                $caddyfilePath = Join-Path $caddyDir "Caddyfile"

                # Get final routes for Caddyfile
                $finalRoutes = @()
                if ($Config.CaddyRoutes -and @($Config.CaddyRoutes).Count -gt 0) {
                    $finalRoutes = @($Config.CaddyRoutes)
                } else {
                    $finalRoutes = @(
                        [PSCustomObject]@{ Path = "$($Config.ApiPrefix)/*"; Target = "127.0.0.1:$($Config.BackendPort)" }
                        [PSCustomObject]@{ Path = "/*";                    Target = "127.0.0.1:$($Config.FrontendPort)" }
                    )
                }

                $caddyfileLines = @()
                $caddyfileLines += ":$($Config.CaddyPort) {"
                foreach ($r in $finalRoutes) {
                    $caddyfileLines += "    handle $($r.Path) {"
                    $caddyfileLines += "        reverse_proxy $($r.Target)"
                    $caddyfileLines += "    }"
                }
                $caddyfileLines += "    header {"
                $caddyfileLines += '        X-Frame-Options "SAMEORIGIN"'
                $caddyfileLines += '        X-Content-Type-Options "nosniff"'
                $caddyfileLines += '        X-XSS-Protection "1; mode=block"'
                $caddyfileLines += "    }"
                $caddyfileLines += "}"
                $caddyfileContent = $caddyfileLines -join "`n"

                Set-Content -Path $caddyfilePath -Value $caddyfileContent -Force
                Restart-Service -Name ess-mo-caddy -ErrorAction SilentlyContinue
                Write-Success "Caddy restarted with new config"
            }
        }
    } while ($sub -notmatch '^[Bb]$')
}

function Show-NetworkConfig {
    param($Config)
    do {
        # Read current Cloudflare tunnel URL if available
        $cfTunnelUrl = $null
        $urlFile = Join-Path $Config.InstallRoot "cloudflare\current_tunnel_url.txt"
        if (Test-Path $urlFile) {
            $cfTunnelUrl = Get-Content $urlFile -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        # Static Cloudflare tunnel URL from cloudflare.log if not found in the dedicated file
        if (-not $cfTunnelUrl) {
            $cfLog = Join-Path $Config.InstallRoot "cloudflare\cloudflare.log"
            if (Test-Path $cfLog) {
                $cfTunnelUrl = Get-Content $cfLog -ErrorAction SilentlyContinue |
                    Select-String -Pattern "https://[a-zA-Z0-9-]+\.trycloudflare\.com" |
                    ForEach-Object { $_.Matches.Value } | Select-Object -Last 1
            }
        }
        # Ensure LocalUrl default if never set
        $localUrl = $Config.LocalUrl
        if ([string]::IsNullOrWhiteSpace($localUrl)) {
            $localUrl = "http://localhost:$($Config.CaddyPort)"
        }

        Write-Host ""
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host " Network & Port Configuration" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host " Current URLs:" -ForegroundColor White
        Write-Host "   Public URL    : $($Config.PublicUrl)" -ForegroundColor Gray
        Write-Host "   Local URL     : $localUrl" -ForegroundColor Gray
        if ($cfTunnelUrl) {
            Write-Host "   Cloudflare    : $cfTunnelUrl" -ForegroundColor Green
        } else {
            Write-Host "   Cloudflare    : (not started)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host " 1) Public URL" -ForegroundColor Gray
        Write-Host " 2) Local URL" -ForegroundColor Gray
        Write-Host " 3) Cloudflare tunnel" -ForegroundColor Gray
        Write-Host " B) Back to main menu" -ForegroundColor Gray
        Write-Host ""
        $sub = Read-Host "Select option"
        switch ($sub) {
            "1" {
                # Public URL submenu - delegate to existing function
                Select-PublicUrl -Config $Config | Out-Null
            }
            "2" {
                # Local URL submenu
                do {
                    Write-Host ""
                    Write-Host "============================================" -ForegroundColor Cyan
                    Write-Host " Local URL" -ForegroundColor Cyan
                    Write-Host "============================================" -ForegroundColor Cyan
                    Write-Host " The URL used for local network access." -ForegroundColor Gray
                    Write-Host " Current: $localUrl" -ForegroundColor Gray
                    Write-Host ""
                    Write-Host " 1) Change URL" -ForegroundColor Gray
                    Write-Host " 2) Exit" -ForegroundColor Gray
                    Write-Host ""
                    $opt = Read-Host "Select option"
                    switch ($opt) {
                        "1" {
                            $newUrl = Read-Host "Enter local URL (e.g. http://192.168.1.100:$($Config.CaddyPort))"
                            if ($newUrl) {
                                if ($newUrl -match '^https?://') {
                                    $Config.LocalUrl = $newUrl
                                    $localUrl = $newUrl
                                    Save-DeployConfig -Config $Config
                                    Write-Success "Local URL updated to: $newUrl"
                                } else {
                                    Write-Err "Enter a URL starting with http:// or https://"
                                }
                            }
                        }
                        "2" { break }
                        default { Write-Warn "Unknown option." }
                    }
                } while ($opt -ne "2")
            }
            "3" {
                # Cloudflare tunnel - display only
                Write-Host ""
                Write-Host "============================================" -ForegroundColor Cyan
                Write-Host " Cloudflare Tunnel URL" -ForegroundColor Cyan
                Write-Host "============================================" -ForegroundColor Cyan
                if ($cfTunnelUrl) {
                    Write-Host ""
                    Write-Host " Your Cloudflare tunnel is active at:" -ForegroundColor White
                    Write-Host "   $cfTunnelUrl" -ForegroundColor Green
                    Write-Host ""
                    Write-Host " This URL is auto-generated by Cloudflare and may change" -ForegroundColor Gray
                    Write-Host " each time the tunnel restarts." -ForegroundColor Gray
                } else {
                    Write-Host ""
                    Write-Host " No Cloudflare tunnel URL detected." -ForegroundColor Yellow
                    Write-Host " Start the Cloudflare service first (option 5 from main menu)." -ForegroundColor Gray
                    Write-Host " The URL will appear here automatically once the tunnel is running." -ForegroundColor Gray
                }
                Write-Host ""
                Read-Host "Press Enter to continue" | Out-Null
            }
            "[Bb]" { break }
            default { Write-Warn "Unknown option." }
        }
    } while ($sub -notmatch '^[Bb]$')
}

function Select-Component {
    param([string]$ActionLabel)
    $compList = Get-Components
    Write-Host ""
    foreach ($c in $compList) {
        $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Green -NoNewline
            Write-Host "  [RUNNING]" -ForegroundColor Green
        } elseif ($svc) {
            Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Gray -NoNewline
            Write-Host "  [STOPPED]" -ForegroundColor DarkYellow
        } else {
            Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray -NoNewline
            Write-Host "  [NOT INSTALLED]" -ForegroundColor DarkGray
        }
    }
    Write-Host " B) Back" -ForegroundColor Gray
    $sel = Read-Host "`nSelect a component to $ActionLabel"
    if ($sel -match '^[Bb]$') { return $null }
    return $compList | Where-Object { "$($_.Num)" -eq $sel } | Select-Object -First 1
}

# ===========================================================
# ENTRY POINT
# ===========================================================
$Config = Get-DeployConfig

if ($script:headless) {
    # Non-interactive mode - validate drive then run
    $installRoot = Select-InstallDrive -Config $Config
    if (-not $installRoot) { exit 1 }
    $Config.InstallRoot = $installRoot
    Invoke-FullDeploy -Config $Config
    if ($script:hasErrors) {
        exit 1
    }
    exit 0
}

# Interactive menu mode - prompt for install drive at start
$installRoot = Select-InstallDrive -Config $Config
if ($installRoot) { $Config.InstallRoot = $installRoot }
do {
    Show-MainMenu -Config $Config
    $choice = Read-Host "Select an option"

    switch -Regex ($choice) {
        "^1$" {
            # Check prerequisites
            Test-Prerequisites | Out-Null
        }
        "^2$" {
            # Install components - sub-prompt
            $compList = Get-Components
            Write-Host ""
            Write-Host " A) Install everything (full deployment)" -ForegroundColor White
            foreach ($c in $compList) {
                $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Green -NoNewline
                    Write-Host "  [RUNNING]" -ForegroundColor Green
                } elseif ($svc) {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Gray -NoNewline
                    Write-Host "  [STOPPED]" -ForegroundColor DarkYellow
                } else {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray
                }
            }
            Write-Host " B) Back" -ForegroundColor Gray
            $sub = Read-Host "`nSelect to install"
            if ($sub -match '^[Aa]$') {
                Invoke-FullDeploy -Config $Config
            } elseif ($sub -match '^\d+$') {
                $c = $compList | Where-Object { "$($_.Num)" -eq $sub } | Select-Object -First 1
                if ($c -and (Confirm-Step "Install $($c.Display)?")) {
                    Initialize-Logger -Config $Config
                    Invoke-ComponentInstall -Key $c.Key -Config $Config | Out-Null
                }
            }
        }
        "^3$" {
            # Uninstall components - sub-prompt
            $compList = Get-Components
            Write-Host ""
            Write-Host " A) Uninstall everything" -ForegroundColor White
            foreach ($c in $compList) {
                $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Green -NoNewline
                    Write-Host "  [RUNNING]" -ForegroundColor Green
                } elseif ($svc) {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Gray -NoNewline
                    Write-Host "  [STOPPED]" -ForegroundColor DarkYellow
                } else {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray -NoNewline
                    Write-Host "  [NOT INSTALLED]" -ForegroundColor DarkGray
                }
            }
            Write-Host " B) Back" -ForegroundColor Gray
            $sub = Read-Host "`nSelect to uninstall"
            if ($sub -match '^[Aa]$') {
                # Uninstall all
                Write-Step "Currently installed services"
                $anyInstalled = $false
                foreach ($c in $compList) {
                    $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                    if ($svc) { $anyInstalled = $true }
                }
                if (-not $anyInstalled) {
                    Write-Warn "No services are currently installed. Nothing to uninstall."
                } else {
                    $confirm = Read-Host "`nThis will remove ALL installed services. Type YES to confirm"
                    if ($confirm -eq "YES") {
                        # Remove all component services and their folders first
                        $delFiles = (Read-Host "Delete component files (frontend/, backend/, caddy/, cloudflare/)? (y/N)") -match '^[Yy]'
                        foreach ($c in $compList) {
                            Remove-Component -Key $c.Key -Config $Config -DeleteFiles:$delFiles
                        }
                        # Then ask about logs and root folder
                        if ($delFiles -and (Confirm-Step "Delete logs/ folder and Ess_Mo root folder too?" -DefaultYes:$false)) {
                            $logsPath = Join-Path $Config.InstallRoot "logs"
                            if (Test-Path $logsPath) {
                                Remove-Item $logsPath -Recurse -Force -ErrorAction SilentlyContinue
                                Write-Success "Deleted logs/ folder"
                            }
                            if (Test-Path $Config.InstallRoot -and $Config.InstallRoot -match '\\[^\\]+$') {
                                # Only delete root if it's empty (after removing component + logs folders)
                                $remaining = Get-ChildItem $Config.InstallRoot -ErrorAction SilentlyContinue
                                if (-not $remaining) {
                                    Remove-Item $Config.InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
                                    Write-Success "Deleted root folder: $($Config.InstallRoot)"
                                } else {
                                    Write-Warn "Root folder not empty, skipping: $($Config.InstallRoot)"
                                    Write-Host "    Remaining items: $($remaining.Name -join ', ')" -ForegroundColor Gray
                                }
                            }
                        }
                    }
                }
            } elseif ($sub -match '^\d+$') {
                $c = $compList | Where-Object { "$($_.Num)" -eq $sub } | Select-Object -First 1
                if ($c -and (Confirm-Step "Uninstall $($c.Display)?" -DefaultYes:$false)) {
                    $compPath = Join-Path $Config.InstallRoot $c.Key
                    $del = (Read-Host "Also delete its files`? ($compPath) (y/N)") -match '^[Yy]'
                    Remove-Component -Key $c.Key -Config $Config -DeleteFiles:$del
                }
            }
        }
        "^4$" {
            # Service status / health check
            Show-Status -Config $Config
        }
        "^5$" {
            # Start services - sub-prompt
            Write-Host ""
            Write-Host " A) Start all services" -ForegroundColor White
            foreach ($c in Get-Components) {
                $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Green -NoNewline
                    Write-Host "  [ALREADY RUNNING]" -ForegroundColor Green
                } elseif ($svc) {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkYellow -NoNewline
                    Write-Host "  [STOPPED]" -ForegroundColor DarkYellow
                } else {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray -NoNewline
                    Write-Host "  [NOT INSTALLED]" -ForegroundColor DarkGray
                }
            }
            Write-Host " B) Back" -ForegroundColor Gray
            $sub = Read-Host "`nSelect to start"
            if ($sub -match '^[Aa]$') {
                Start-AllServices -Config $Config
            } elseif ($sub -match '^\d+$') {
                $c = Get-Components | Where-Object { "$($_.Num)" -eq $sub } | Select-Object -First 1
                if ($c) {
                    $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                    if (-not $svc) {
                        Write-Warn "$($c.Display) is not installed."
                    } elseif ($svc.Status -eq 'Running') {
                        Write-Warn "$($c.Display) is already running."
                    } else {
                        Start-Service -Name $c.Service -ErrorAction Stop
                        Write-Success "Started $($c.Display)"
                    }
                }
            }
        }
        "^6$" {
            # Stop services - sub-prompt
            Write-Host ""
            Write-Host " A) Stop all services" -ForegroundColor White
            foreach ($c in Get-Components) {
                $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Green -NoNewline
                    Write-Host "  [RUNNING]" -ForegroundColor Green
                } elseif ($svc) {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkYellow -NoNewline
                    Write-Host "  [STOPPED]" -ForegroundColor DarkYellow
                } else {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray -NoNewline
                    Write-Host "  [NOT INSTALLED]" -ForegroundColor DarkGray
                }
            }
            Write-Host " B) Back" -ForegroundColor Gray
            $sub = Read-Host "`nSelect to stop"
            if ($sub -match '^[Aa]$') {
                Stop-AllServices -Config $Config
            } elseif ($sub -match '^\d+$') {
                $c = Get-Components | Where-Object { "$($_.Num)" -eq $sub } | Select-Object -First 1
                if ($c) {
                    $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                    if (-not $svc) {
                        Write-Warn "$($c.Display) is not installed."
                    } elseif ($svc.Status -ne 'Running') {
                        Write-Warn "$($c.Display) is already stopped."
                    } else {
                        Stop-Service -Name $c.Service -ErrorAction Stop
                        Write-Success "Stopped $($c.Display)"
                    }
                }
            }
        }
        "^7$" { Show-CaddyConfig -Config $Config }
        "^8$" {
            # Public network config (Cloudflare / URL / ports)
            Show-NetworkConfig -Config $Config
        }
        "^9$" {
            # Open logs folder
            $logsPath = Join-Path $Config.InstallRoot "logs"
            if (Test-Path $logsPath) { Invoke-Item $logsPath } else { Write-Warn "No logs folder yet." }
        }
        "^[Qq]$" { Write-Host "`nBye." -ForegroundColor Cyan }
        default  { Write-Warn "Unknown option." }
    }

    if ($choice -notmatch '^[Qq]$') { Read-Host "`nPress Enter to continue" | Out-Null }

} while ($choice -notmatch '^[Qq]$')
