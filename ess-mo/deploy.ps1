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
    [ValidateSet("frontend", "backend", "caddy")]
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
        # Ensure InstallRoot exists (may be missing from older config files)
        if (-not ($cfg | Get-Member -Name 'InstallRoot' -ErrorAction SilentlyContinue)) {
            Add-Member -InputObject $cfg -NotePropertyName 'InstallRoot' -NotePropertyValue $null
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

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Caddy Proxy Port" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Caddy is the reverse proxy that exposes the app to the network." -ForegroundColor Gray
    if ($hasCurrent) {
        Write-Host " Current: $($Config.CaddyPort)" -ForegroundColor Gray
    }
    Write-Host ""

    if ($hasCurrent) {
        $confirm = Read-Host "Change port? (y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Success "Caddy port kept at $($Config.CaddyPort)"
            return $Config.CaddyPort
        }
    }

    $defaultPort = if ($hasCurrent) { $Config.CaddyPort } else { 8089 }
    $valid = $false
    do {
        $prompt = "Enter new Caddy port [$defaultPort]"
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

    if ($newPort -ne $Config.CaddyPort) {
        $Config.CaddyPort = $newPort
        Save-DeployConfig -Config $Config
        Write-Success "Caddy port changed to: $newPort"
        Write-Log "Caddy port changed to: $newPort"
    } else {
        Write-Success "Caddy port kept at $($Config.CaddyPort)"
    }

    return $Config.CaddyPort
}

function Initialize-InstallRoot {
    param($Config)
    if ($script:dryRun) { Write-Warn "[DRY-RUN] Would create: $($Config.InstallRoot)"; return }
    New-Item -Path $Config.InstallRoot -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $Config.InstallRoot "logs") -ItemType Directory -Force | Out-Null
    Write-Log "Install root created at $($Config.InstallRoot)"
}

# ===========================================================
# SECRETS PROTECTION — ensures deploy.secrets.json is gitignored
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

# ===========================================================
# PREREQUISITES
# ===========================================================
# ===========================================================
# PREREQUISITES
# ===========================================================
function Test-Prerequisites {
    param([switch]$CheckOnly)
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

    # Check-only mode: just report, no install/update offers
    if ($CheckOnly) {
        if ($missing.Count -gt 0) {
            $missingNames = ($missing | ForEach-Object { $_.Name }) -join ', '
            Write-Err "Missing prerequisites: $missingNames — install them manually or use menu option 1"
            Write-Log "Missing prerequisites (check-only): $missingNames" -Level "ERROR"
            return $false
        }
        Write-Success "All prerequisites are installed."
        return $true
    }

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
        $logsDir = Join-Path $Config.InstallRoot "logs"
        $svcTimestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $installLog = Join-Path $logsDir "frontend_installing_${svcTimestamp}.log"
        Set-Content -Path $installLog -Value "" -Force

        $tempDir = Join-Path $env:TEMP "essmo_frontend_clone"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

        "--- git clone ---" | Out-File -FilePath $installLog -Append
        git clone $Config.FrontendRepo $tempDir 2>&1 |
            Tee-Object -FilePath $installLog -Append

        $destDir = Join-Path $Config.InstallRoot "frontend"
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$tempDir\*" -Destination $destDir -Recurse -Force

        Push-Location $destDir
        "--- npm install ---" | Out-File -FilePath $installLog -Append
        npm install 2>&1 | Tee-Object -FilePath $installLog -Append
        "--- npm install serve ---" | Out-File -FilePath $installLog -Append
        npm install serve 2>&1 | Tee-Object -FilePath $installLog -Append
        $env:VITE_API_URL = $Config.ApiPrefix
        "--- npm run build ---" | Out-File -FilePath $installLog -Append
        npm run build 2>&1 | Tee-Object -FilePath $installLog -Append
        Pop-Location

        if (-not (Test-Path (Join-Path $destDir "dist"))) {
            throw "Frontend build failed - dist folder not created"
        }
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        # Runtime log: capture all stdout/stderr from the running service
        $frontendLog = Join-Path $logsDir "frontend_service_${svcTimestamp}.log"
        Write-Host "    Service log: $frontendLog" -ForegroundColor Gray

        # cmd.exe needs the inner command double-quoted, and Servy needs that
        # quoting preserved literally -> hence the doubled quotes here.
        $paramStr = "/c `"`"echo ========== Service started at %DATE% %TIME% ========== >> `"$frontendLog`" & cd /d $destDir && npx serve -s dist -l $($Config.FrontendPort) >> `"$frontendLog`" 2>&1`"`""

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
    param($Config)
    Initialize-InstallRoot -Config $Config
    Write-Step "Installing Backend"

    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would install Backend from $($Config.BackendRepo) on port $($Config.BackendPort)"
        return $true
    }

    try {
        $logsDir = Join-Path $Config.InstallRoot "logs"
        $svcTimestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $installLog = Join-Path $logsDir "backend_installing_${svcTimestamp}.log"
        Set-Content -Path $installLog -Value "" -Force

        # Show spinner during setup (git clone, venv, pip install)
        Start-Spinner "Installing Backend ..."

        $tempDir = Join-Path $env:TEMP "essmo_backend_clone"
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }

        "--- git clone ---" | Out-File -FilePath $installLog -Append
        git clone $Config.BackendRepo $tempDir 2>&1 |
            Tee-Object -FilePath $installLog -Append

        $destDir = Join-Path $Config.InstallRoot "backend"
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$tempDir\*" -Destination $destDir -Recurse -Force

        Push-Location $destDir
        "--- python -m venv ---" | Out-File -FilePath $installLog -Append
        python -m venv venv 2>&1 |
            Tee-Object -FilePath $installLog -Append
        if (-not (Test-Path (Join-Path $destDir "venv\Scripts\python.exe"))) {
            throw "Virtual environment was not created"
        }
        "--- pip install -r requirements.txt ---" | Out-File -FilePath $installLog -Append
        & (Join-Path $destDir "venv\Scripts\pip") install -r requirements.txt 2>&1 |
            Tee-Object -FilePath $installLog -Append
        Pop-Location
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        # Hide spinner before opening the interactive editor
        Stop-Spinner

        Write-Host "    Preparing .env file..." -ForegroundColor Gray
        "--- generating SECRET_KEY ---" | Out-File -FilePath $installLog -Append
        $generatedKey = & (Join-Path $destDir "venv\Scripts\python") -c "import secrets; print(secrets.token_hex(32))" 2>&1 |
            Tee-Object -FilePath $installLog -Append
        $envContent = @"
DB_ENGINE=mysql
DB_HOST=192.168.1.172
DB_PORT=3306
DB_USER="root"
DB_PASSWORD="your_db_password"
DB_NAME=ess

SECRET_KEY=$generatedKey
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30

SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER="your_email@gmail.com"
SMTP_PASS="your_app_password"
EMAIL_FROM="your_email@gmail.com"
"@

        # ---- .env cursor editor (free-move cursor, footer navigation) ----
        $envFilePath = Join-Path $destDir ".env"
        $saveConfirmed = $false

        # Write defaults first
        Set-Content -Path $envFilePath -Value $envContent -Force

        function Test-EnvFileValid {
            param([string]$Path)
            $content = Get-Content -Path $Path -Raw
            $missing = @()
            foreach ($key in @("DB_HOST", "DB_USER", "DB_PASSWORD", "DB_NAME", "SECRET_KEY")) {
                if ($content -notmatch "(?m)^$key=.+") { $missing += $key }
            }
            return $missing
        }

        $originalDefaults = ($envContent -split "`r?`n") | Where-Object { $_ -ne "" }
        $lines = Get-Content -Path $envFilePath
        $sel = 0
        $col = 0

        # Footer items — navigable like content lines
        $footerItems = @("  Save and exit", "  Cancel (revert to defaults)")
        $totalItems = $lines.Count + $footerItems.Count

        do {
            # Capture anchor at each iteration so terminal scrolling doesn't drift
            $startTop = [Console]::CursorTop

            # Clear area
            $rowsToClear = $totalItems + 6
            for ($r = 0; $r -lt $rowsToClear; $r++) {
                [Console]::SetCursorPosition(0, $startTop + $r)
                Write-Host (" " * [Console]::WindowWidth) -NoNewline
            }
            [Console]::SetCursorPosition(0, $startTop)

            Write-Host ""
            Write-Host "  " + "─" * 55 -ForegroundColor DarkGray
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $num = ($i + 1).ToString().PadLeft(2)
                $isDiff = $i -lt $originalDefaults.Count -and $originalDefaults[$i] -and $lines[$i] -ne $originalDefaults[$i]
                $cur = if ($i -eq $sel) { ">" } else { " " }
                if ($i -eq $sel) {
                    Write-Host " $cur$num  $($lines[$i])" -ForegroundColor Black -BackgroundColor Cyan
                } elseif ($isDiff) {
                    Write-Host " $cur$num  $($lines[$i])" -ForegroundColor Yellow
                } else {
                    Write-Host " $cur$num  $($lines[$i])" -ForegroundColor Gray
                }
            }
            Write-Host "  " + "─" * 55 -ForegroundColor DarkGray

            # Footer items (navigable)
            for ($i = 0; $i -lt $footerItems.Count; $i++) {
                $idx = $lines.Count + $i
                $cur = if ($idx -eq $sel) { ">" } else { " " }
                if ($idx -eq $sel) {
                    Write-Host "  $cur$($footerItems[$i])" -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host "  $cur$($footerItems[$i])" -ForegroundColor Gray
                }
            }
            Write-Host "  " + "─" * 55 -ForegroundColor DarkGray
            Write-Host "  " + ([char]0x2191) + ([char]0x2193) + " navigate  " + ([char]0x2190) + ([char]0x2192) + " within line  Type to edit  Enter=select" -ForegroundColor Gray

            # Position cursor
            if ($sel -lt $lines.Count) {
                $cursorRow = $startTop + 2 + $sel
                $cursorCol = 6 + [Math]::Min($col, $lines[$sel].Length)
            } else {
                $cursorRow = $startTop + 2 + $lines.Count + 1 + ($sel - $lines.Count)
                $cursorCol = 4
            }
            [Console]::SetCursorPosition($cursorCol, $cursorRow)

            $keyInfo = [Console]::ReadKey($true)
            $key = $keyInfo.Key
            $char = $keyInfo.KeyChar

            if ($key -eq 'Enter') {
                if ($sel -eq $lines.Count) {
                    # Save and exit
                    $missing = Test-EnvFileValid -Path $envFilePath
                    if ($missing.Count -gt 0) {
                        Write-Warn "Missing required fields: $($missing -join ', ')"
                        if (-not (Confirm-Step "Save anyway?" -DefaultYes:$false)) {
                            continue
                        }
                    }
                    $saveConfirmed = $true
                    break
                } elseif ($sel -eq $lines.Count + 1) {
                    # Cancel — revert to defaults
                    Write-Warn "Using default .env values."
                    Set-Content -Path $envFilePath -Value $envContent -Force
                    $lines = Get-Content -Path $envFilePath
                    $saveConfirmed = $true
                    break
                }
            } elseif ($key -eq 'Escape') {
                # Quick cancel from anywhere
                Write-Warn "Using default .env values."
                Set-Content -Path $envFilePath -Value $envContent -Force
                $lines = Get-Content -Path $envFilePath
                $saveConfirmed = $true
                break
            } elseif ($key -eq 'UpArrow') {
                if ($sel -gt 0) {
                    $sel--
                    if ($sel -lt $lines.Count) { $col = [Math]::Min($col, $lines[$sel].Length) }
                }
            } elseif ($key -eq 'DownArrow') {
                if ($sel -lt $totalItems - 1) {
                    $sel++
                    if ($sel -lt $lines.Count) { $col = [Math]::Min($col, $lines[$sel].Length) }
                }
            } elseif ($key -eq 'LeftArrow' -and $sel -lt $lines.Count) {
                if ($col -gt 0) { $col-- }
            } elseif ($key -eq 'RightArrow' -and $sel -lt $lines.Count) {
                if ($col -lt $lines[$sel].Length) { $col++ }
            } elseif ($key -eq 'Home' -and $sel -lt $lines.Count) {
                $col = 0
            } elseif ($key -eq 'End' -and $sel -lt $lines.Count) {
                $col = $lines[$sel].Length
            } elseif ($key -eq 'Backspace' -and $sel -lt $lines.Count) {
                if ($col -gt 0) {
                    $lines[$sel] = $lines[$sel].Remove($col - 1, 1)
                    $col--
                }
            } elseif ($key -eq 'Delete' -and $sel -lt $lines.Count) {
                if ($col -lt $lines[$sel].Length) {
                    $lines[$sel] = $lines[$sel].Remove($col, 1)
                }
            } elseif ($key -eq 'Tab' -and $sel -lt $lines.Count) {
                $lines[$sel] = $lines[$sel].Insert($col, "    ")
                $col += 4
            } elseif ($char -ge ' ' -and $char -ne [char]127 -and $sel -lt $lines.Count) {
                # Printable character - insert at cursor
                $lines[$sel] = $lines[$sel].Insert($col, $char)
                $col++
            }
        } while (-not $saveConfirmed)

        # Write final content to file
        Set-Content -Path $envFilePath -Value ($lines -join "`r`n") -Force
        Write-Success ".env file ready at $envFilePath"
        # ---- End .env cursor editor ----

        $pythonExe = Join-Path $destDir "venv\Scripts\python.exe"

        # Runtime log: capture all uvicorn request/error logs
        $backendLog = Join-Path $logsDir "backend_service_${svcTimestamp}.log"
        Write-Host "    Service log: $backendLog" -ForegroundColor Gray

        $paramStr = "/c `"`"echo ========== Service started at %DATE% %TIME% ========== >> `"$backendLog`" & cd /d $destDir && $pythonExe -m uvicorn app.main:app --host 0.0.0.0 --port $($Config.BackendPort) >> `"$backendLog`" 2>&1`"`""

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
        $logsDir = Join-Path $Config.InstallRoot "logs"
        $svcTimestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $installLog = Join-Path $logsDir "caddy_installing_${svcTimestamp}.log"
        Set-Content -Path $installLog -Value "" -Force

        $caddyDir = Join-Path $Config.InstallRoot "caddy"
        New-Item -Path $caddyDir -ItemType Directory -Force | Out-Null
        $caddyExe = Join-Path $caddyDir "caddy.exe"

        if (-not (Test-Path $caddyExe)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Write-Host "    Downloading Caddy..." -ForegroundColor Gray
            "--- downloading Caddy ---" | Out-File -FilePath $installLog -Append
            Invoke-WebRequest -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile $caddyExe -UseBasicParsing 2>&1 |
                Tee-Object -FilePath $installLog -Append
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
        $originalCaddyLines = $caddyfileContent -split "`r?`n"
        $editCaddyLines = @() + $originalCaddyLines
        $caddySaved = $false

        # ---- Caddyfile cursor editor (footer navigation) ----
        $sel = 0
        $col = 0

        # Footer items — navigable like content lines
        $caddyFooterItems = @("  Save and exit", "  Cancel (revert to defaults)")
        $caddyTotalItems = $editCaddyLines.Count + $caddyFooterItems.Count

        do {
            # Capture anchor at each iteration so terminal scrolling doesn't drift
            $caddyStartTop = [Console]::CursorTop

            # Clear area
            $rowsToClear = $caddyTotalItems + 6
            for ($r = 0; $r -lt $rowsToClear; $r++) {
                [Console]::SetCursorPosition(0, $caddyStartTop + $r)
                Write-Host (" " * [Console]::WindowWidth) -NoNewline
            }
            [Console]::SetCursorPosition(0, $caddyStartTop)

            Write-Host ""
            Write-Host "  " + "─" * 55 -ForegroundColor DarkGray
            for ($i = 0; $i -lt $editCaddyLines.Count; $i++) {
                $num = ($i + 1).ToString().PadLeft(2)
                $isDiff = $i -lt $originalCaddyLines.Count -and $editCaddyLines[$i] -ne $originalCaddyLines[$i]
                $cur = if ($i -eq $sel) { ">" } else { " " }
                if ($i -eq $sel) {
                    Write-Host " $cur$num  $($editCaddyLines[$i])" -ForegroundColor Black -BackgroundColor Cyan
                } elseif ($isDiff) {
                    Write-Host " $cur$num  $($editCaddyLines[$i])" -ForegroundColor Yellow
                } else {
                    Write-Host " $cur$num  $($editCaddyLines[$i])" -ForegroundColor Gray
                }
            }
            Write-Host "  " + "─" * 55 -ForegroundColor DarkGray

            # Footer items (navigable)
            for ($i = 0; $i -lt $caddyFooterItems.Count; $i++) {
                $idx = $editCaddyLines.Count + $i
                $cur = if ($idx -eq $sel) { ">" } else { " " }
                if ($idx -eq $sel) {
                    Write-Host "  $cur$($caddyFooterItems[$i])" -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host "  $cur$($caddyFooterItems[$i])" -ForegroundColor Gray
                }
            }
            Write-Host "  " + "─" * 55 -ForegroundColor DarkGray
            Write-Host "  " + ([char]0x2191) + ([char]0x2193) + " navigate  " + ([char]0x2190) + ([char]0x2192) + " within line  Type to edit  Enter=select" -ForegroundColor Gray

            # Position cursor
            if ($sel -lt $editCaddyLines.Count) {
                $cursorRow = $caddyStartTop + 2 + $sel
                $cursorCol = 6 + [Math]::Min($col, $editCaddyLines[$sel].Length)
            } else {
                $footerIdx = $sel - $editCaddyLines.Count
                $cursorRow = $caddyStartTop + 2 + $editCaddyLines.Count + 1 + $footerIdx
                $cursorCol = 4
            }
            [Console]::SetCursorPosition($cursorCol, $cursorRow)

            $keyInfo = [Console]::ReadKey($true)
            $key = $keyInfo.Key
            $char = $keyInfo.KeyChar

            if ($key -eq 'Enter') {
                if ($sel -eq $editCaddyLines.Count) {
                    # Save and exit
                    $caddySaved = $true
                    break
                } elseif ($sel -eq $editCaddyLines.Count + 1) {
                    # Cancel — revert to defaults
                    Write-Warn "Using default Caddyfile."
                    $caddySaved = $false
                    break
                }
            } elseif ($key -eq 'Escape') {
                # Quick cancel from anywhere
                Write-Warn "Using default Caddyfile."
                $caddySaved = $false
                break
            } elseif ($key -eq 'UpArrow') {
                if ($sel -gt 0) {
                    $sel--
                    if ($sel -lt $editCaddyLines.Count) { $col = [Math]::Min($col, $editCaddyLines[$sel].Length) }
                }
            } elseif ($key -eq 'DownArrow') {
                if ($sel -lt $caddyTotalItems - 1) {
                    $sel++
                    if ($sel -lt $editCaddyLines.Count) { $col = [Math]::Min($col, $editCaddyLines[$sel].Length) }
                }
            } elseif ($key -eq 'LeftArrow' -and $sel -lt $editCaddyLines.Count) {
                if ($col -gt 0) { $col-- }
            } elseif ($key -eq 'RightArrow' -and $sel -lt $editCaddyLines.Count) {
                if ($col -lt $editCaddyLines[$sel].Length) { $col++ }
            } elseif ($key -eq 'Home' -and $sel -lt $editCaddyLines.Count) {
                $col = 0
            } elseif ($key -eq 'End' -and $sel -lt $editCaddyLines.Count) {
                $col = $editCaddyLines[$sel].Length
            } elseif ($key -eq 'Backspace' -and $sel -lt $editCaddyLines.Count) {
                if ($col -gt 0) {
                    $editCaddyLines[$sel] = $editCaddyLines[$sel].Remove($col - 1, 1)
                    $col--
                }
            } elseif ($key -eq 'Delete' -and $sel -lt $editCaddyLines.Count) {
                if ($col -lt $editCaddyLines[$sel].Length) {
                    $editCaddyLines[$sel] = $editCaddyLines[$sel].Remove($col, 1)
                }
            } elseif ($key -eq 'Tab' -and $sel -lt $editCaddyLines.Count) {
                $editCaddyLines[$sel] = $editCaddyLines[$sel].Insert($col, "    ")
                $col += 4
            } elseif ($char -ge ' ' -and $char -ne [char]127 -and $sel -lt $editCaddyLines.Count) {
                # Printable character - insert at cursor
                $editCaddyLines[$sel] = $editCaddyLines[$sel].Insert($col, $char)
                $col++
            }
        } while ($true)
        # ---- End Caddyfile cursor editor ----

        $finalCaddyfile = $editCaddyLines -join "`n"
        if ($caddySaved) {
            Set-Content -Path $caddyfilePath -Value $finalCaddyfile -Force
            Write-Success "Caddyfile written to $caddyfilePath"
        } else {
            Set-Content -Path $caddyfilePath -Value $caddyfileContent -Force
        }
        "--- Caddyfile ---" | Out-File -FilePath $installLog -Append
        $finalCaddyfile | Out-File -FilePath $installLog -Append

        # Runtime log: capture Caddy access/error logs
        $caddyLog = Join-Path $logsDir "caddy_service_${svcTimestamp}.log"
        Write-Host "    Service log: $caddyLog" -ForegroundColor Gray

        # Wrap in cmd.exe to capture stdout/stderr (consistent with frontend/backend)
        $paramStr = "/c `"`"echo ========== Service started at %DATE% %TIME% ========== >> `"$caddyLog`" & cd /d $caddyDir && `"$caddyExe`" run --config `"$caddyfilePath`" >> `"$caddyLog`" 2>&1`"`""

        servy-cli uninstall --name="ess-mo-caddy" --silent 2>&1 | Out-Null
        servy-cli install --name="ess-mo-caddy" --path="C:\Windows\System32\cmd.exe" --params="$paramStr"

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
    )
}

function Invoke-ComponentInstall {
    param($Key, $Config)
    $result = $false
    switch ($Key) {
        "frontend"   { $result = Install-Frontend -Config $Config }
        "backend"    { $result = Install-Backend -Config $Config }
        "caddy"      { $result = Install-Caddy -Config $Config }
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
        $logsDir = Join-Path $Config.InstallRoot "logs"
        $uninstallLog = Join-Path $logsDir "${Key}_uninstalling_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        "--- Stopping service $svcName ---" | Out-File -FilePath $uninstallLog -Append

        Stop-Service -Name $svcName -ErrorAction SilentlyContinue 2>&1 | Out-File -FilePath $uninstallLog -Append
        "--- servy-cli uninstall ---" | Out-File -FilePath $uninstallLog -Append
        servy-cli uninstall --name="$svcName" --silent 2>&1 | Out-File -FilePath $uninstallLog -Append
        Start-Sleep -Milliseconds 500

        if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
            Write-Warn "$svcName is still registered - restart your computer and re-run uninstall."
            "WARN: $svcName still registered" | Out-File -FilePath $uninstallLog -Append
        } else {
            Write-Success "$svcName service removed."
            "OK: $svcName removed" | Out-File -FilePath $uninstallLog -Append
        }

        if ($DeleteFiles) {
            $path = Join-Path $Config.InstallRoot $Key
            if (Test-Path $path) {
                "--- deleting $path ---" | Out-File -FilePath $uninstallLog -Append
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue 2>&1 | Out-File -FilePath $uninstallLog -Append
                Write-Success "Deleted $path"
            }
        }
        Write-Success "Uninstall log: $uninstallLog"
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

    # 3. Check prerequisites — check-only, no install/update prompts
    $prereqResult = Test-Prerequisites -CheckOnly
    if ("BACK" -eq $prereqResult -or -not $prereqResult) {
        if ("BACK" -eq $prereqResult) {
            Write-Warn "Returning to menu."
        } else {
            Write-Err "Resolve missing prerequisites first."
        }
        return
    }
    # Determine which components to deploy
    $targetComponents = if ($script:headless -and $Components.Count -gt 0) {
        $Components
    } else {
        @("frontend", "backend", "caddy")
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
            $backendOk = Install-Backend -Config $Config
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

        # Routing diagram — show the full access path
        if ($targetComponents -contains "caddy") {
            Write-Host ""
            Write-Host "  " + "─" * 55 -ForegroundColor DarkGray
            Write-Host "  Access your app at: http://localhost:$($Config.CaddyPort)" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Caddy (: $($Config.CaddyPort))" -ForegroundColor Green
            if ($targetComponents -contains "backend") {
                Write-Host "    ├── $($Config.ApiPrefix)/*  →  backend  (127.0.0.1:$($Config.BackendPort))" -ForegroundColor Gray
            }
            if ($targetComponents -contains "frontend") {
                Write-Host "    └── /*                  →  frontend (127.0.0.1:$($Config.FrontendPort))" -ForegroundColor Gray
            }
            Write-Host "  " + "─" * 55 -ForegroundColor DarkGray
            Write-Host ""
        }
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
    Write-Host "  8) Open logs folder" -ForegroundColor White
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
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray -NoNewline
                    Write-Host "  [NOT INSTALLED]" -ForegroundColor DarkGray
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
                            if ((Test-Path $Config.InstallRoot) -and ($Config.InstallRoot -match '\\[^\\]+$')) {
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
            # Open logs folder
            $logsPath = Join-Path $Config.InstallRoot "logs"
            if (Test-Path $logsPath) { Invoke-Item $logsPath } else { Write-Warn "No logs folder yet." }
        }
        "^[Qq]$" { Write-Host "`nBye." -ForegroundColor Cyan }
        default  { Write-Warn "Unknown option." }
    }

    if ($choice -notmatch '^[Qq]$') { Read-Host "`nPress Enter to continue" | Out-Null }

} while ($choice -notmatch '^[Qq]$')
