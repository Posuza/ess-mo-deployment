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
# EXECUTION POLICY — auto-bypass if policy blocks unsigned scripts
# This lets users run .\deploy.ps1 without manually setting
# Set-ExecutionPolicy or using the -ExecutionPolicy flag.
# ===========================================================
# Get-ExecutionPolicy (no scope) returns the *effective* policy for this session.
# If run via -ExecutionPolicy Bypass it returns Bypass, so we won't loop infinitely.
$effectivePolicy = Get-ExecutionPolicy -ErrorAction SilentlyContinue
if ($effectivePolicy -in @('Restricted', 'AllSigned')) {
    Write-Warning "Execution policy is '$effectivePolicy' — re-launching with Bypass..."
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
    ApiPrefix    = "/api/v1"
    InstallRoot  = $null
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
        # Ensure InstallRoot exists (may be missing from older config files)
        if (-not ($cfg | Get-Member -Name 'InstallRoot' -ErrorAction SilentlyContinue)) {
            Add-Member -InputObject $cfg -NotePropertyName 'InstallRoot' -NotePropertyValue $null
        }
        return $cfg
    }
    Write-Warn "Config file not found, creating default at $ConfigPath"
    $cfg = [PSCustomObject]$DefaultConfig
    Add-Member -InputObject $cfg -NotePropertyName 'InstallRoot' -NotePropertyValue $null
    $cfg | ConvertTo-Json | Set-Content $ConfigPath
    return $cfg
}

function Save-DeployConfig {
    param($Config)
    $Config | ConvertTo-Json | Set-Content $ConfigPath
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
            $prompt = "Select install drive ($driveList, or press Enter for current)"
        } else {
            $prompt = "Select install drive ($driveList)"
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
        $choice = $choice.ToUpper().TrimEnd(':').TrimEnd('\')

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
            $Config.PublicUrl = "http://localhost:$($Config.CaddyPort)"
        }
        return $Config.PublicUrl
    }

    $hasCurrent = -not [string]::IsNullOrWhiteSpace($Config.PublicUrl)
    $defaultUrl = if ($hasCurrent) { $Config.PublicUrl } else { "http://localhost:$($Config.CaddyPort)" }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Public URL" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " The public URL where users access the app." -ForegroundColor Gray
    Write-Host " Change this to your real domain, Cloudflare tunnel," -ForegroundColor Gray
    Write-Host " or server IP when deploying for real use." -ForegroundColor Gray
    if ($hasCurrent) {
        Write-Host " Current: $($Config.PublicUrl)" -ForegroundColor Gray
    }
    Write-Host ""

    $prompt = "Public URL [$defaultUrl]"
    $choice = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($choice)) {
        $choice = $defaultUrl
    }

    if (-not $hasCurrent -or $choice -ne $Config.PublicUrl) {
        $Config.PublicUrl = $choice
        Save-DeployConfig -Config $Config
        Write-Success "Public URL set to: $choice"
        Write-Log "Public URL changed to: $choice"
    }

    return $Config.PublicUrl
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
    if (Test-Path $SecretsPath) {
        Write-Log "Secrets loaded from $SecretsPath"
        return Get-Content $SecretsPath -Raw | ConvertFrom-Json
    }

    # Check if example file exists and suggest copying
    if (Test-Path $SecretsExamplePath) {
        Write-Host "`nNo secrets file found." -ForegroundColor Yellow
        Write-Host "Tip: Copy deploy.secrets.example.json to deploy.secrets.json and fill in your real values." -ForegroundColor Gray
        Write-Host "Or enter them interactively below.`n" -ForegroundColor Gray
    } else {
        Write-Host "`nNo secrets file found at $SecretsPath - let's create one." -ForegroundColor Yellow
    }

    if ($script:headless) {
        Write-Err "No secrets file found and running in headless mode. Create deploy.secrets.json first."
        Write-Host "  Template: $SecretsExamplePath" -ForegroundColor Gray
        exit 1
    }

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
function Install-MissingPrerequisite {
    param([string]$Name, [string]$CmdName, [string]$WingetId, [string]$Url)

    if ($script:headless) {
        # Headless mode — can't prompt, just report
        Write-Err "$Name is required but not installed. Install manually: $Url"
        Write-Log "Prerequisite missing (headless): $Name" -Level "ERROR"
        return $false
    }

    # Ask user if they want to install
    $resp = Read-Host "$Name is not installed. Install now? (Y/n/B=Back to menu)"

    # B = back to menu immediately
    if ($resp -match '^[Bb]$') {
        Write-Warn "Returning to menu. $Name must be installed before deployment."
        return "BACK"
    }

    # Y/Enter = try to install
    if ($resp -eq '' -or $resp -match '^[Yy]') {
        # Try winget first
        if ($WingetId -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Host "    Installing $Name via winget..." -ForegroundColor Gray
            Write-Log "Installing $Name via winget ($WingetId)"
            winget install $WingetId --accept-package-agreements --silent 2>&1 | Out-Null
            # Refresh PATH so the command is found
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
            if (Get-Command $CmdName -ErrorAction SilentlyContinue) {
                Write-Success "$Name installed successfully."
                Write-Log "$Name installed via winget"
                return $true
            }
        }
        # Winget didn't work — tell user to install manually
        Write-Warn "Could not auto-install $Name."
        Write-Host "    Install manually from: $Url" -ForegroundColor Gray
        Write-Log "$Name auto-install failed" -Level "WARN"

        # After failed install, ask again
        $resp2 = Read-Host "Go back to menu? (Y/n)"
        if ($resp2 -eq '' -or $resp2 -match '^[Yy]') {
            return "BACK"
        }
        return $false
    }

    # n = skip, then ask if they want to go back
    $resp3 = Read-Host "Go back to menu? (Y/n)"
    if ($resp3 -eq '' -or $resp3 -match '^[Yy]') {
        return "BACK"
    }
    Write-Warn "Skipping $Name — deployment may fail later."
    Write-Log "Prerequisite skipped: $Name" -Level "WARN"
    return $false
}

function Test-Prerequisites {
    Write-Step "Checking prerequisites"
    $ok = $true

    foreach ($tool in @(
        @{ Cmd = "git";    Name = "Git";          WingetId = "Git.Git";           Url = "https://git-scm.com" },
        @{ Cmd = "node";   Name = "Node.js 22+";  WingetId = "OpenJS.NodeJS.LTS"; Url = "https://nodejs.org" },
        @{ Cmd = "python"; Name = "Python 3.13+"; WingetId = "Python.Python.3.13"; Url = "https://python.org" }
    )) {
        if (Get-Command $tool.Cmd -ErrorAction SilentlyContinue) {
            Write-Success "$($tool.Name): OK"
            Write-Log "Prerequisite OK: $($tool.Name)"
        } else {
            Write-Err "$($tool.Name): missing"
            $result = Install-MissingPrerequisite -Name $tool.Name -CmdName $tool.Cmd -WingetId $tool.WingetId -Url $tool.Url
            if ($result -eq "BACK") { return "BACK" }
            if (-not $result) { $ok = $false }
        }
    }

    # Servy — auto-install via winget, or manual URL
    if (Get-Command servy-cli -ErrorAction SilentlyContinue) {
        Write-Success "Servy: OK"
        Write-Log "Prerequisite OK: Servy"
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Warn "Servy not found, installing via winget..."
        Write-Log "Installing Servy via winget"
        winget install servy --accept-package-agreements --silent 2>&1 | Out-Null
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        if (Get-Command servy-cli -ErrorAction SilentlyContinue) {
            Write-Success "Servy: installed"
            Write-Log "Servy installed successfully"
        } else {
            Write-Err "Servy installed but not on PATH yet — restart PowerShell and re-run."
            $ok = $false
        }
    } else {
        Write-Err "Servy CLI missing and winget unavailable — install manually: https://github.com/servy-community/servy"
        $ok = $false
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

        $caddyfilePath = Join-Path $caddyDir "Caddyfile"
        $caddyfileContent = @"
:$($Config.CaddyPort) {
    handle $($Config.ApiPrefix)/* {
        reverse_proxy 127.0.0.1:$($Config.BackendPort)
    }
    handle /* {
        reverse_proxy 127.0.0.1:$($Config.FrontendPort)
    }
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
    }
}
"@
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
        Write-Warn "[DRY-RUN] Would install Cloudflare tunnel for http://127.0.0.1:$($Config.CaddyPort)"
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
            Write-Warn "cloudflared not available. Install manually: winget install Cloudflare.cloudflared"
            return $false
        }

        $cfDir = Join-Path $Config.InstallRoot "cloudflare"
        New-Item -Path $cfDir -ItemType Directory -Force | Out-Null
        $cfPath  = (Get-Command cloudflared).Source
        $logPath = Join-Path $cfDir "cloudflare.log"

        servy-cli uninstall --name="ess-mo-cloudflare" --silent 2>&1 | Out-Null
        servy-cli install --name="ess-mo-cloudflare" --path="$cfPath" --params="tunnel --url http://127.0.0.1:$($Config.CaddyPort) --logfile $logPath"

        if (-not (Get-Service -Name ess-mo-cloudflare -ErrorAction SilentlyContinue)) {
            throw "Service 'ess-mo-cloudflare' was not created by servy-cli"
        }
        Write-Success "Cloudflare service installed."
        $script:installedComponents += "cloudflare"
        Write-Log "Cloudflare tunnel installed"
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
        "cloudflare" { $result = Install-Cloudflare -Config $Config }
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
            Write-Warn "$svcName is still registered - you may need to restart Windows and re-run uninstall."
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
    foreach ($c in Get-Components) {
        if (-not (Get-Service -Name $c.Service -ErrorAction SilentlyContinue)) {
            Write-Host "    Skipping $($c.Display) (not installed)" -ForegroundColor Gray
            continue
        }
        try {
            Start-Service -Name $c.Service -ErrorAction Stop
            Write-Success "Started $($c.Display)"
            Write-Log "Service started: $($c.Service)"
        } catch {
            Write-Err "Failed to start $($c.Display): $_"
            Write-Log "Failed to start $($c.Service): $_" -Level "ERROR"
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
        Write-Warn "Internet: unreachable — git clone, npm install, and pip install will fail."
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
    if ($prereqResult -eq "BACK" -or -not $prereqResult) {
        if ($prereqResult -eq "BACK") {
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
        if (Confirm-Step "Install Frontend?") {
            if (-not (Install-Frontend -Config $Config)) { $allSucceeded = $false }
        } else { Write-Warn "Skipped Frontend." }
    }

    if ($targetComponents -contains "backend") {
        if (Confirm-Step "Install Backend?") {
            $secrets = Get-OrCreateSecrets
            if (-not (Install-Backend -Config $Config -Secrets $secrets)) { $allSucceeded = $false }
        } else { Write-Warn "Skipped Backend." }
    }

    if ($targetComponents -contains "caddy") {
        if (Confirm-Step "Install Caddy reverse proxy?") {
            if (-not (Install-Caddy -Config $Config)) { $allSucceeded = $false }
        } else { Write-Warn "Skipped Caddy." }
    }

    if ($targetComponents -contains "cloudflare") {
        if (Confirm-Step "Expose this app publicly via a Cloudflare quick tunnel?" -DefaultYes:$false) {
            if (-not (Install-Cloudflare -Config $Config)) { $allSucceeded = $false }
        } else { Write-Warn "Skipped Cloudflare tunnel." }
    }

    # Roll back on failure (only in non-dry-run mode)
    if (-not $allSucceeded -and -not $script:dryRun) {
        if ($script:headless -or (Confirm-Step "Some components failed. Roll back installed components?" -DefaultYes:$true)) {
            Invoke-Rollback -Config $Config
            Write-Log "Deployment rolled back due to failures" -Level "ERROR"
            return
        }
    }

    # IIS warning — port 80 conflicts with Windows web server
    if ($targetComponents -contains "caddy") {
        if ($Config.CaddyPort -eq 80) {
            Write-Host "    ⚠ Port 80 is used by IIS (Windows web server)." -ForegroundColor Yellow
            if (Confirm-Step "Stop IIS to free port 80?") {
                if ($script:dryRun) {
                    Write-Warn "[DRY-RUN] Would stop IIS (W3SVC) and set startup to Disabled"
                } else {
                    Stop-Service -Name W3SVC -ErrorAction SilentlyContinue
                    Set-Service  -Name W3SVC -StartupType Disabled -ErrorAction SilentlyContinue
                    Write-Log "IIS (W3SVC) stopped and disabled"
                }
            }
        } else {
            Write-Host "    [i] Caddy uses port $($Config.CaddyPort) — no IIS conflict." -ForegroundColor Gray
            Write-Log "Caddy port $($Config.CaddyPort) — IIS not affected"
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
    Write-Host " Install path: $($Config.InstallRoot)" -ForegroundColor Gray
    Write-Host ""
    Write-Host " 1) Full deployment (install everything)"
    Write-Host " 2) Install a component"
    Write-Host " 3) Uninstall a component"
    Write-Host " 4) Uninstall everything"
    Write-Host " 5) Start services"
    Write-Host " 6) Stop services"
    Write-Host " 7) Restart services"
    Write-Host " 8) Status / health check"
    Write-Host " 9) Check prerequisites"
    Write-Host "10) Change install path"
    Write-Host "11) Open logs folder"
    Write-Host " Q) Quit"
    Write-Host ""
}

function Select-Component {
    param([string]$ActionLabel)
    $components = Get-Components
    Write-Host ""
    foreach ($c in $components) { Write-Host " $($c.Num)) $($c.Display)" }
    Write-Host " B) Back"
    $sel = Read-Host "`nSelect a component to $ActionLabel"
    if ($sel -match '^[Bb]$') { return $null }
    return $components | Where-Object { "$($_.Num)" -eq $sel } | Select-Object -First 1
}

# ===========================================================
# ENTRY POINT
# ===========================================================
$Config = Get-DeployConfig

if ($script:headless) {
    # Non-interactive mode — validate drive + port then run
    $installRoot = Select-InstallDrive -Config $Config
    if (-not $installRoot) { exit 1 }
    $Config.InstallRoot = $installRoot
    $caddyPort = Select-CaddyPort -Config $Config
    if (-not $caddyPort) { exit 1 }
    $Config.CaddyPort = $caddyPort
    $publicUrl = Select-PublicUrl -Config $Config
    if ($publicUrl) { $Config.PublicUrl = $publicUrl }
    Invoke-FullDeploy -Config $Config
    if ($script:hasErrors) {
        exit 1
    }
    exit 0
}

# Interactive menu mode — prompt for install drive + Caddy port + public URL at start
$installRoot = Select-InstallDrive -Config $Config
if ($installRoot) { $Config.InstallRoot = $installRoot }
$caddyPort = Select-CaddyPort -Config $Config
if ($caddyPort) { $Config.CaddyPort = $caddyPort }
$publicUrl = Select-PublicUrl -Config $Config
if ($publicUrl) { $Config.PublicUrl = $publicUrl }
do {
    Show-MainMenu -Config $Config
    $choice = Read-Host "Select an option"

    switch -Regex ($choice) {
        "^1$" {
            Invoke-FullDeploy -Config $Config
        }
        "^2$" {
            $c = Select-Component -ActionLabel "install"
            if ($c -and (Confirm-Step "Install $($c.Display)?")) {
                Initialize-Logger -Config $Config
                Invoke-ComponentInstall -Key $c.Key -Config $Config | Out-Null
            }
        }
        "^3$" {
            $c = Select-Component -ActionLabel "uninstall"
            if ($c -and (Confirm-Step "Uninstall $($c.Display)?" -DefaultYes:$false)) {
                $del = Read-Host "Also delete its files? (y/N)"
                Remove-Component -Key $c.Key -Config $Config -DeleteFiles:($del -match '^[Yy]')
            }
        }
        "^4$" {
            $confirm = Read-Host "This removes ALL services. Type YES to confirm"
            if ($confirm -eq "YES") {
                $del = Read-Host "Also delete all installed files? (y/N)"
                foreach ($c in Get-Components) {
                    Remove-Component -Key $c.Key -Config $Config -DeleteFiles:($del -match '^[Yy]')
                }
            }
        }
        "^5$"  { Start-AllServices -Config $Config }
        "^6$"  { Stop-AllServices -Config $Config }
        "^7$"  { Stop-AllServices -Config $Config; Start-Sleep -Seconds 2; Start-AllServices -Config $Config }
        "^8$"  { Show-Status -Config $Config }
        "^9$"  { Test-Prerequisites | Out-Null }
        "^10$" {
            $newPath = Read-Host "New install path [$($Config.InstallRoot)]"
            if ($newPath) {
                $Config.InstallRoot = $newPath
                Save-DeployConfig -Config $Config
                Write-Success "Install path updated. Re-run install for components to use it."
            }
        }
        "^11$" {
            $logsPath = Join-Path $Config.InstallRoot "logs"
            if (Test-Path $logsPath) { Invoke-Item $logsPath } else { Write-Warn "No logs folder yet." }
        }
        "^[Qq]$" { Write-Host "`nBye." -ForegroundColor Cyan }
        default  { Write-Warn "Unknown option." }
    }

    if ($choice -notmatch '^[Qq]$') { Read-Host "`nPress Enter to continue" | Out-Null }

} while ($choice -notmatch '^[Qq]$')
