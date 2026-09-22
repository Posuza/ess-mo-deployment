# ===========================================================
# ESS MO Full-Stack Deployment Manager
# FACE-ESS style versioned deployment architecture
#
# Components are independent deployment units:
#   frontend       -> <InstallRoot>\frontend\repo
#   backend        -> <InstallRoot>\backend\repo
#   report-worker  -> shared backend source + <InstallRoot>\report-worker\venv
#   caddy          -> <InstallRoot>\caddy
#
# Backend and report-worker share one backend Git checkout. They keep
# separate Python virtual environments, runners, logs and services.
#
# Usage:
#   .\deploy.ps1
#   .\deploy.ps1 -Force
#   .\deploy.ps1 -Force -Components frontend,backend,report-worker,caddy
#   .\deploy.ps1 -DryRun
#
# Local files next to this script:
#   deploy.config.json
#   deploy.secrets.json
#   deploy.secrets.example.json
#
# Runtime state:
#   <InstallRoot>\deployment-state.json
# Keeps the current and previous complete known-good deployments.
# ===========================================================

#Requires -RunAsAdministrator

param(
    [switch]$DryRun,
    [switch]$Force,
    [ValidateSet("frontend", "backend", "report-worker", "caddy")]
    [string[]]$Components = @()
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Auto-bypass restrictive execution policy for this process only.
$effectivePolicy = Get-ExecutionPolicy -ErrorAction SilentlyContinue
if ($effectivePolicy -in @('Restricted', 'AllSigned')) {
    Write-Host "    [!] Re-launching with -ExecutionPolicy Bypass ..." -ForegroundColor Yellow
    $self = $MyInvocation.MyCommand.Path
    $bypassArgs = @("-ExecutionPolicy", "Bypass", "-File", $self) + $args
    & powershell.exe $bypassArgs
    exit $LASTEXITCODE
}

# ---------- PATHS ----------
$ScriptRoot = $PSScriptRoot
$ConfigPath = Join-Path $ScriptRoot "deploy.config.json"
$SecretsPath = Join-Path $ScriptRoot "deploy.secrets.json"
$SecretsExamplePath = Join-Path $ScriptRoot "deploy.secrets.example.json"

# ---------- DEFAULT CONFIG ----------
$DefaultConfig = [ordered]@{
    Environment = "production"

    FrontendRepo = "https://github.com/Posuza/ESS_MO_Fronend.git"
    FrontendBranch = "main"

    BackendRepo = "https://github.com/Posuza/ESS_MO_Backend.git"
    BackendBranch = "main"

    FrontendPort = 3009
    BackendPort = 8009
    CaddyPort = 9089
    CaddyAdminPort = 2019
    CaddyVersion = "2.11.4"
    CaddyWindowsAmd64Sha256 = "1708333f79e274c7697285afe6d592ab39314e0b131e9ec6bea08ad27df62ebf"
    ApiPrefix = "/api/v1"
    FrontendPublicUrl = $null
    MediaStoragePath = "E:\ESS\storage\face-images"

    MoReportWorkerPollSeconds = 5
    MoReportRetentionMinutes = 1
    MoReportSweepMinutes = 0.1

    InstallRoot = "C:\\ESS\\Ess_MO"
}

# ---------- GLOBAL STATE ----------
$script:startTime = $null
$script:logFile = $null
$script:dryRun = $DryRun
$script:hasErrors = $false
$script:headless = $Force -or ($Components.Count -gt 0)
$script:deploymentTransaction = $false
$script:deploymentCandidates = @{}
$script:deploymentStateBeforeRun = $null
$script:liveComponentsChanged = @()

# ===========================================================
# NAMES / COMPONENTS
# ===========================================================
function Get-DeployEnvironment {
    param($Config)
    return ("$($Config.Environment)").Trim().ToLowerInvariant()
}

function Get-InstallFolderName {
    param($Config)
    if ((Get-DeployEnvironment -Config $Config) -eq "development") { return "Ess_MO_dev" }
    return "Ess_MO"
}

function Get-ServicePrefix {
    param($Config)
    if ((Get-DeployEnvironment -Config $Config) -eq "development") { return "ess-mo-dev" }
    return "ess-mo"
}

function Get-DeployServiceName {
    param($Config, [Parameter(Mandatory=$true)][string]$Component)
    return "$(Get-ServicePrefix -Config $Config)-$Component"
}

function Get-ComponentKeys {
    return @("frontend", "backend", "report-worker", "caddy")
}

function Get-Components {
    param($Config)
    return @(
        [PSCustomObject]@{ Num = 1; Key = "frontend";      Service = (Get-DeployServiceName -Config $Config -Component "frontend");      Display = "Frontend (Node / Vite)" }
        [PSCustomObject]@{ Num = 2; Key = "backend";       Service = (Get-DeployServiceName -Config $Config -Component "backend");       Display = "Backend API (FastAPI)" }
        [PSCustomObject]@{ Num = 3; Key = "report-worker"; Service = (Get-DeployServiceName -Config $Config -Component "report-worker"); Display = "MO Report Worker" }
        [PSCustomObject]@{ Num = 4; Key = "caddy";         Service = (Get-DeployServiceName -Config $Config -Component "caddy");         Display = "Caddy reverse proxy" }
    )
}

function Get-ServiceComponents {
    param($Config)
    return Get-Components -Config $Config
}

# ===========================================================
# LOGGING / OUTPUT
# ===========================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if ($script:logFile) { Add-Content -Path $script:logFile -Value $line -ErrorAction SilentlyContinue }
}

function Write-FileLog {
    param([string]$Path, [string]$Text)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    $line | Out-File -FilePath $Path -Append -Encoding utf8
}

filter Add-FileLog {
    param([string]$Path)
    Write-Host "$_"
    if ($null -ne $_ -and "$_" -ne '') { Write-FileLog -Path $Path -Text "$_" }
}

function Write-Step    ($msg) { Write-Host "`n[*] $msg" -ForegroundColor Yellow; Write-Log "STEP: $msg" }
function Write-Success ($msg) { Write-Host "    $msg" -ForegroundColor Green; Write-Log "OK: $msg" }
function Write-Err     ($msg) { Write-Host "    $msg" -ForegroundColor Red; Write-Log "ERROR: $msg" -Level "ERROR"; $script:hasErrors = $true }
function Write-Warn    ($msg) { Write-Host "    $msg" -ForegroundColor DarkYellow; Write-Log "WARN: $msg" -Level "WARN" }

function Confirm-Step {
    param([string]$Message, [bool]$DefaultYes = $true)
    if ($script:headless) { return $DefaultYes }
    $suffix = if ($DefaultYes) { "(Y/n)" } else { "(y/N)" }
    $resp = Read-Host "$Message $suffix"
    if ([string]::IsNullOrWhiteSpace($resp)) { return $DefaultYes }
    return $resp -match '^[Yy]'
}

function Initialize-Logger {
    param($Config)
    $logsDir = Join-Path $Config.InstallRoot "logs"
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    $script:startTime = Get-Date
    $script:logFile = Join-Path $logsDir ("deploy-{0}.log" -f $script:startTime.ToString("yyyyMMdd-HHmmss"))
    Write-Log "=== ESS MO deployment started ===" -Level "START"
    Write-Log "Environment: $(Get-DeployEnvironment -Config $Config)"
    Write-Log "Install root: $($Config.InstallRoot)"
    if ($script:dryRun) { Write-Log "DRY RUN MODE" -Level "WARN" }
}

# ===========================================================
# CONFIG
# ===========================================================
function Get-DeployConfig {
    if (Test-Path $ConfigPath) {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($key in $DefaultConfig.Keys) {
            if (-not ($cfg | Get-Member -Name $key -ErrorAction SilentlyContinue)) {
                Add-Member -InputObject $cfg -NotePropertyName $key -NotePropertyValue $DefaultConfig[$key]
            }
        }
        $cfg.Environment = Get-DeployEnvironment -Config $cfg
        if ($cfg.Environment -notin @("production", "development")) {
            throw "Invalid Environment '$($cfg.Environment)'. Use production or development."
        }
        $cfg.ApiPrefix = "$($cfg.ApiPrefix)".Trim().TrimEnd('/')
        if ($cfg.ApiPrefix -ne "/api/v1") {
            throw "Invalid ApiPrefix '$($cfg.ApiPrefix)'. This backend is mounted at /api/v1."
        }
        if (-not [string]::IsNullOrWhiteSpace("$($cfg.FrontendPublicUrl)")) {
            $publicUrl = "$($cfg.FrontendPublicUrl)".Trim().TrimEnd('/')
            if ($publicUrl -notmatch '^https?://[^\s]+$') {
                throw "Invalid FrontendPublicUrl '$publicUrl'. Use an absolute http:// or https:// URL, or null."
            }
            $cfg.FrontendPublicUrl = $publicUrl
        }
        $mediaPath = "$($cfg.MediaStoragePath)".Trim().TrimEnd('\')
        if ($mediaPath -notmatch '^[A-Za-z]:\\.+') {
            throw "Invalid MediaStoragePath '$mediaPath'. Use an absolute Windows path below a drive root."
        }
        $cfg.MediaStoragePath = $mediaPath
        return $cfg
    }

    $cfg = [PSCustomObject]$DefaultConfig
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
    return $cfg
}

function Save-DeployConfig {
    param($Config)
    $Config | ConvertTo-Json -Depth 8 | Set-Content $ConfigPath -Encoding UTF8
}

function Select-InstallDrive {
    param($Config)
    $avail = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[A-Z]$' -and (Test-Path "$($_.Name):\\") } |
        ForEach-Object { $_.Name.ToUpper() } | Sort-Object)

    if ($avail.Count -eq 0) { Write-Err "No valid drive found."; return $null }

    $folder = Get-InstallFolderName -Config $Config
    if ($script:headless) {
        $root = [System.IO.Path]::GetPathRoot("$($Config.InstallRoot)")
        $letter = $root.TrimEnd('\\').TrimEnd(':')
        if ($letter -notin $avail) { Write-Err "Configured drive $root does not exist."; return $null }
        $Config.InstallRoot = "$letter`:\\ESS\\$folder"
        Save-DeployConfig -Config $Config
        return $Config.InstallRoot
    }

    Write-Host "`nAvailable drives: $($avail -join ', ')" -ForegroundColor Gray
    $current = [System.IO.Path]::GetPathRoot("$($Config.InstallRoot)").TrimEnd('\\').TrimEnd(':')
    $choice = Read-Host "Install drive [$current]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $current }
    $choice = $choice.ToUpper().TrimEnd('\\').TrimEnd(':')
    if ($choice -notin $avail) { Write-Err "Invalid drive. Available: $($avail -join ', ')"; return $null }
    $Config.InstallRoot = "$choice`:\\ESS\\$folder"
    Save-DeployConfig -Config $Config
    Write-Success "Install path: $($Config.InstallRoot)"
    return $Config.InstallRoot
}

function Initialize-InstallRoot {
    param($Config)
    if ($script:dryRun) { return }
    New-Item -Path $Config.InstallRoot -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $Config.InstallRoot "logs") -ItemType Directory -Force | Out-Null
}

function Test-AppInstallRoot {
    param($Config)
    $root = "$($Config.InstallRoot)"
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    $leaf = Split-Path -Path $root -Leaf
    $parent = Split-Path -Path $root -Parent
    $parentLeaf = Split-Path -Path $parent -Leaf
    return ($leaf -eq (Get-InstallFolderName -Config $Config) -and $parentLeaf -eq "ESS")
}

# ===========================================================
# SECRETS
# ===========================================================
function Protect-SecretsFile {
    $gitignore = Join-Path $ScriptRoot ".gitignore"
    $entry = "deploy.secrets.json"
    if (-not (Test-Path $gitignore)) { Set-Content $gitignore $entry }
    elseif (-not (Select-String -Path $gitignore -Pattern '^deploy\.secrets\.json$' -Quiet)) { Add-Content $gitignore $entry }
}

function New-DefaultSecrets {
    return [PSCustomObject]@{
        db = [PSCustomObject]@{ host = "192.168.1.172"; port = 3306; name = "ess"; user = "root"; password = "" }
        smtp = [PSCustomObject]@{ host = "smtp.gmail.com"; port = 587; user = ""; pass = ""; from = "" }
        app = [PSCustomObject]@{ secret_key = "" }
    }
}

function Ensure-AppSecretKey {
    param($Secrets)
    if (-not ($Secrets | Get-Member -Name "app" -ErrorAction SilentlyContinue) -or -not $Secrets.app) {
        Add-Member -InputObject $Secrets -NotePropertyName app -NotePropertyValue ([PSCustomObject]@{ secret_key = "" }) -Force
    }
    if (-not ($Secrets.app | Get-Member -Name "secret_key" -ErrorAction SilentlyContinue)) {
        Add-Member -InputObject $Secrets.app -NotePropertyName secret_key -NotePropertyValue "" -Force
    }
    if ([string]::IsNullOrWhiteSpace("$($Secrets.app.secret_key)")) {
        $Secrets.app.secret_key = [System.Guid]::NewGuid().ToString("N") + [System.Guid]::NewGuid().ToString("N")
        $Secrets | ConvertTo-Json -Depth 6 | Set-Content $SecretsPath -Encoding UTF8
        Write-Log "Generated persistent application SECRET_KEY"
    }
    return $Secrets
}

function Get-SecretsOrInitialize {
    Protect-SecretsFile
    $s = $null
    if (Test-Path $SecretsPath) {
        try { $s = Get-Content $SecretsPath -Raw | ConvertFrom-Json } catch { $s = $null }
    }
    if (-not $s) {
        $s = New-DefaultSecrets
        $s | ConvertTo-Json -Depth 6 | Set-Content $SecretsPath -Encoding UTF8
        Write-Warn "Created $SecretsPath. Fill in your DB/SMTP credentials, then run deployment again."
        if (-not $script:headless) { Start-Process notepad.exe $SecretsPath -ErrorAction SilentlyContinue | Out-Null }
        return $null
    }

    # Backward compatibility for old MO secrets files.
    if (-not ($s | Get-Member -Name smtp -ErrorAction SilentlyContinue)) {
        Add-Member -InputObject $s -NotePropertyName smtp -NotePropertyValue ([PSCustomObject]@{ host="smtp.gmail.com";port=587;user="";pass="";from="" }) -Force
    }
    $s = Ensure-AppSecretKey -Secrets $s

    $placeholderPattern = 'REPLACE_WITH_|YOUR_|CHANGE_THIS|PLACEHOLDER'
    $invalid = @()
    foreach ($pair in @(
        @{ n='db.host'; v="$($s.db.host)" }, @{ n='db.name'; v="$($s.db.name)" },
        @{ n='db.user'; v="$($s.db.user)" }, @{ n='db.password'; v="$($s.db.password)" }
    )) {
        if ([string]::IsNullOrWhiteSpace($pair.v) -or $pair.v -match $placeholderPattern) { $invalid += $pair.n }
    }
    if ($invalid.Count -gt 0) {
        Write-Warn "Secrets incomplete: $($invalid -join ', ')"
        Write-Host " Edit: $SecretsPath" -ForegroundColor Cyan
        return $null
    }
    return $s
}

function Confirm-DeploymentCredentials {
    param($Secrets)
    if ($script:headless) { return $true }
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host " Deployment Credentials" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " DB configuration : configured" -ForegroundColor Green
    Write-Host (" SMTP             : " + $(if (-not [string]::IsNullOrWhiteSpace("$($Secrets.smtp.user)")) { "configured" } else { "not configured" })) -ForegroundColor Gray
    Write-Host " SECRET_KEY        : persistent / configured" -ForegroundColor Green
    Write-Host " Source            : $SecretsPath" -ForegroundColor Gray
    return (Confirm-Step "Continue deployment?" -DefaultYes:$true)
}

function Convert-ToEnvValue {
    param([AllowNull()][object]$Value)
    $s = "$Value"
    return $s.Replace('\\','\\\\').Replace('"','\\"')
}

function Write-MoEnvFile {
    param($Config, $Secrets, [Parameter(Mandatory=$true)][string]$RepoDir)
    $dbHost = Convert-ToEnvValue $Secrets.db.host
    $dbPort = if ($Secrets.db.port) { $Secrets.db.port } else { 3306 }
    $dbUser = Convert-ToEnvValue $Secrets.db.user
    $dbPass = Convert-ToEnvValue $Secrets.db.password
    $dbName = Convert-ToEnvValue $Secrets.db.name
    $smtpHost = Convert-ToEnvValue $Secrets.smtp.host
    $smtpPort = if ($Secrets.smtp.port) { $Secrets.smtp.port } else { 587 }
    $smtpUser = Convert-ToEnvValue $Secrets.smtp.user
    $smtpPass = Convert-ToEnvValue $Secrets.smtp.pass
    $smtpFrom = Convert-ToEnvValue $Secrets.smtp.from
    $secretKey = Convert-ToEnvValue $Secrets.app.secret_key
    $frontendUrl = if ([string]::IsNullOrWhiteSpace("$($Config.FrontendPublicUrl)")) {
        "http://localhost:$($Config.CaddyPort)"
    } else {
        "$($Config.FrontendPublicUrl)".Trim().TrimEnd('/')
    }
    $mediaStoragePath = "$($Config.MediaStoragePath)"

    $envContent = @"
DB_ENGINE=mysql
DB_HOST=$dbHost
DB_PORT=$dbPort
DB_USER="$dbUser"
DB_PASSWORD="$dbPass"
DB_NAME=$dbName

SECRET_KEY=$secretKey
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30

SMTP_HOST=$smtpHost
SMTP_PORT=$smtpPort
SMTP_USER="$smtpUser"
SMTP_PASS="$smtpPass"
EMAIL_FROM="$smtpFrom"
FRONTEND_URL=$frontendUrl

MEDIA_STORAGE_PATH=$mediaStoragePath

MO_REPORT_EXPORT_WORKER_POLL_SECONDS=$($Config.MoReportWorkerPollSeconds)
MO_REPORT_EXPORT_RETENTION_MINUTES=$($Config.MoReportRetentionMinutes)
MO_REPORT_EXPORT_SWEEP_INTERVAL_MINUTES=$($Config.MoReportSweepMinutes)
MO_REPORT_EXPORT_WORKER_LOG_LEVEL=INFO
"@
    Set-Content -Path (Join-Path $RepoDir ".env") -Value $envContent -Encoding UTF8 -Force
}

# ===========================================================
# PREREQUISITES / PORT / HEALTH
# ===========================================================
function Test-Prerequisites {
    param([switch]$CheckOnly)
    Write-Step "Checking prerequisites"
    $missing = @()
    $tools = @(
        @{ Cmd="git"; Name="Git"; WingetId="Git.Git"; Url="https://git-scm.com" },
        @{ Cmd="node"; Name="Node.js 22+"; WingetId="OpenJS.NodeJS.LTS"; Url="https://nodejs.org" },
        @{ Cmd="python"; Name="Python 3.11+"; WingetId="Python.Python.3.13"; Url="https://python.org" },
        @{ Cmd="servy-cli"; Name="Servy CLI"; WingetId="servy"; Url="https://github.com/servy-community/servy" }
    )
    foreach ($t in $tools) {
        if (Get-Command $t.Cmd -ErrorAction SilentlyContinue) { Write-Host "    $($t.Name): OK" -ForegroundColor Green }
        else { Write-Host "    $($t.Name): MISSING" -ForegroundColor Red; $missing += $t }
    }
    if ($missing.Count -eq 0) { return $true }
    if ($CheckOnly -or $script:headless) { return $false }
    if (-not (Confirm-Step "Install missing prerequisites?" -DefaultYes:$true)) { return $false }
    foreach ($t in $missing) {
        if ($t.WingetId -and (Get-Command winget -ErrorAction SilentlyContinue)) {
            winget install $t.WingetId --accept-package-agreements --accept-source-agreements --silent | Out-Null
        }
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
    foreach ($t in $missing) {
        if (-not (Get-Command $t.Cmd -ErrorAction SilentlyContinue)) {
            Write-Err "$($t.Name) still missing. Install manually: $($t.Url)"
            return $false
        }
    }
    return $true
}

function Test-PortInUse {
    param([int]$Port)
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne(500)
        if ($connected -and $tcp.Connected) { $tcp.EndConnect($iar); return $true }
    } catch {} finally { if ($tcp) { $tcp.Close() } }
    return $false
}

function Test-Endpoint {
    param([string]$Url, [string]$Name, [int]$TimeoutSec=5, [int]$Retries=7, [int]$RetryDelaySec=2)
    for ($i=0; $i -le $Retries; $i++) {
        try {
            Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
            Write-Success "$Name ($Url): responding"
            return $true
        } catch {
            if ($i -lt $Retries) { Start-Sleep -Seconds $RetryDelaySec }
        }
    }
    Write-Err "$Name ($Url): not responding"
    return $false
}

function Get-CaddyActualPorts {
    param($Config)
    $file = Join-Path (Join-Path $Config.InstallRoot "caddy") "caddy-ports.json"
    $result = @{ proxy=[int]$Config.CaddyPort; admin=[int]$Config.CaddyAdminPort }
    if (Test-Path $file) {
        try {
            $d = Get-Content $file -Raw | ConvertFrom-Json
            if ($d.proxy) { $result.proxy = [int]$d.proxy }
            if ($d.admin) { $result.admin = [int]$d.admin }
        } catch {}
    }
    return $result
}

function Verify-Health {
    param($Config)
    $ok = $true
    $be = Get-DeployServiceName -Config $Config -Component "backend"
    $worker = Get-DeployServiceName -Config $Config -Component "report-worker"
    $fe = Get-DeployServiceName -Config $Config -Component "frontend"
    $caddy = Get-DeployServiceName -Config $Config -Component "caddy"

    Write-Step "Verifying service health"
    if (Get-Service $be -ErrorAction SilentlyContinue) {
        if (-not (Test-Endpoint -Url "http://127.0.0.1:$($Config.BackendPort)$($Config.ApiPrefix)/health" -Name "Backend API")) { $ok=$false }
    }
    $ws = Get-Service $worker -ErrorAction SilentlyContinue
    if ($ws -and $ws.Status -ne 'Running') { Write-Err "MO report worker: $($ws.Status)"; $ok=$false }
    elseif ($ws) { Write-Success "MO report worker: running" }
    if (Get-Service $fe -ErrorAction SilentlyContinue) {
        if (-not (Test-Endpoint -Url "http://127.0.0.1:$($Config.FrontendPort)" -Name "Frontend")) { $ok=$false }
    }
    if (Get-Service $caddy -ErrorAction SilentlyContinue) {
        $ports = Get-CaddyActualPorts -Config $Config
        if (-not (Test-Endpoint -Url "http://127.0.0.1:$($ports.proxy)$($Config.ApiPrefix)/health" -Name "Caddy proxy")) { $ok=$false }
    }
    return $ok
}

# ===========================================================
# DEPLOYMENT STATE -- no rollback folder required
# ===========================================================
function Get-DeploymentStatePath { param($Config); return (Join-Path $Config.InstallRoot "deployment-state.json") }

function New-EmptyDeploymentComponents {
    return [PSCustomObject]@{
        frontend      = [PSCustomObject]@{ current=$null; previous=$null }
        backend       = [PSCustomObject]@{ current=$null; previous=$null }
        'report-worker' = [PSCustomObject]@{ current=$null; previous=$null }
        caddy         = [PSCustomObject]@{ current=$null; previous=$null }
    }
}

function Get-DeploymentState {
    param($Config)
    $path = Get-DeploymentStatePath -Config $Config
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw | ConvertFrom-Json } catch { Write-Warn "Invalid deployment state: $path"; return $null }
}

function Save-DeploymentState {
    param($Config, $State)
    if ($script:dryRun) { return }
    $path = Get-DeploymentStatePath -Config $Config
    $tmp = "$path.tmp"
    $State | ConvertTo-Json -Depth 12 | Set-Content $tmp -Encoding UTF8 -Force
    Move-Item $tmp $path -Force
}

function Copy-ObjectDeep { param($Object); if ($null -eq $Object) { return $null }; return ($Object | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }

function Get-CurrentDeploymentVersion {
    param($Config)
    $s=Get-DeploymentState -Config $Config
    if (-not $s -or -not $s.deploymentVersions -or @($s.deploymentVersions).Count -eq 0) { return $null }
    return @($s.deploymentVersions)[0]
}

function Get-DeploymentComponentCurrent {
    param($Config,[string]$Component)
    $v=Get-CurrentDeploymentVersion -Config $Config
    if (-not $v -or -not $v.components) { return $null }
    $cs = $v.components.$Component
    if (-not $cs) { return $null }
    return "$($cs.current)".Trim()
}

function Get-GitHead {
    param([string]$RepoDir)
    if (-not (Test-Path (Join-Path $RepoDir ".git"))) { return $null }
    $h = (& git -C $RepoDir rev-parse HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace("$h")) { return $null }
    return "$h".Trim()
}

function Ensure-GitCommitAvailable {
    param([string]$RepoDir,[string]$Commit)
    & git -C $RepoDir cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }
    & git -C $RepoDir fetch origin $Commit 2>$null
    & git -C $RepoDir cat-file -e "$Commit^{commit}" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-ComponentInstalled {
    param($Config,[string]$Component)
    $svc=Get-Service -Name (Get-DeployServiceName -Config $Config -Component $Component) -ErrorAction SilentlyContinue
    $base=Join-Path $Config.InstallRoot $Component
    switch ($Component) {
        "frontend"      { return [bool]($svc -and (Test-Path (Join-Path $base "repo\\.git"))) }
        "backend"       { return [bool]($svc -and (Test-Path (Join-Path $base "repo\\.git"))) }
        "report-worker" {
            $sharedRepo=Join-Path $Config.InstallRoot "backend\repo\.git"
            $workerPython=Join-Path $base "venv\Scripts\python.exe"
            return [bool]($svc -and (Test-Path $sharedRepo) -and (Test-Path $workerPython))
        }
        "caddy"         { return [bool]($svc -and (Test-Path (Join-Path $base "caddy.exe"))) }
    }
    return $false
}

function Test-AnyComponentInstalled { param($Config); foreach($k in (Get-ComponentKeys)){if(Test-ComponentInstalled -Config $Config -Component $k){return $true}}; return $false }
function Test-AllComponentsInstalled { param($Config); foreach($k in (Get-ComponentKeys)){if(-not(Test-ComponentInstalled -Config $Config -Component $k)){return $false}}; return $true }
function Test-DeploymentRollbackAvailable { param($Config); $s=Get-DeploymentState -Config $Config; return [bool]($s -and $s.deploymentVersions -and @($s.deploymentVersions).Count -ge 2) }

function Get-NextDeploymentVersionName {
    param($State)
    $max=0
    if($State -and $State.deploymentVersions){foreach($v in @($State.deploymentVersions)){if("$($v.versionName)" -match '^v(\d+)$'){if([int]$Matches[1] -gt $max){$max=[int]$Matches[1]}}}}
    return "v$($max+1)"
}

function Ensure-DeploymentStateForFirstSuccess {
    param($Config)
    $s=Get-DeploymentState -Config $Config
    if($s -and $s.deploymentVersions -and @($s.deploymentVersions).Count -gt 0){return $s}
    return [PSCustomObject]@{ deploymentVersions=@([PSCustomObject]@{versionName="v1";components=(New-EmptyDeploymentComponents)}) }
}

function Register-SuccessfulComponentDeployment {
    param($Config,[string]$Component,[string]$Commit)
    if($script:deploymentTransaction){$script:deploymentCandidates[$Component]=$Commit; return}
    $s=Ensure-DeploymentStateForFirstSuccess -Config $Config
    $v=@($s.deploymentVersions)[0]
    $cs=$v.components.$Component
    if(-not $cs){$cs=[PSCustomObject]@{current=$null;previous=$null};$v.components|Add-Member -NotePropertyName $Component -NotePropertyValue $cs -Force}
    $old="$($cs.current)".Trim()
    if($old -ne $Commit){$cs.previous=if([string]::IsNullOrWhiteSpace($old)){$null}else{$old};$cs.current=$Commit}
    Save-DeploymentState -Config $Config -State $s
}

function Test-FullDeploymentHasChanges {
    param($Config)
    $s=Get-DeploymentState -Config $Config
    if(-not $s -or -not $s.deploymentVersions){return $true}
    $v=@($s.deploymentVersions)[0]
    foreach($k in (Get-ComponentKeys)){
        if(-not $script:deploymentCandidates.ContainsKey($k)){continue}
        if("$($script:deploymentCandidates[$k])".Trim() -ne "$($v.components.$k.current)".Trim()){return $true}
    }
    return $false
}

function Complete-FullDeploymentState {
    param($Config)
    $s=Get-DeploymentState -Config $Config
    if(-not $s -or -not $s.deploymentVersions -or @($s.deploymentVersions).Count -eq 0){
        $components=New-EmptyDeploymentComponents
        foreach($k in (Get-ComponentKeys)){if($script:deploymentCandidates.ContainsKey($k)){$components.$k.current="$($script:deploymentCandidates[$k])"}}
        $s=[PSCustomObject]@{deploymentVersions=@([PSCustomObject]@{versionName="v1";components=$components})}
        Save-DeploymentState -Config $Config -State $s
        Write-Success "Deployment version created: v1"
        return
    }
    if(-not(Test-FullDeploymentHasChanges -Config $Config)){Write-Success "Everything is already current; no new deployment version created.";return}
    $old=@($s.deploymentVersions)[0]
    $new=Copy-ObjectDeep $old
    $new.versionName=Get-NextDeploymentVersionName -State $s
    foreach($k in (Get-ComponentKeys)){
        if(-not $script:deploymentCandidates.ContainsKey($k)){continue}
        $candidate="$($script:deploymentCandidates[$k])".Trim()
        $cs=$new.components.$k
        if(-not $cs){$cs=[PSCustomObject]@{current=$null;previous=$null};$new.components|Add-Member -NotePropertyName $k -NotePropertyValue $cs -Force}
        $oldCommit="$($old.components.$k.current)".Trim()
        if($candidate -ne $oldCommit){$cs.previous=if([string]::IsNullOrWhiteSpace($oldCommit)){$null}else{$oldCommit};$cs.current=$candidate}
    }
    $s.deploymentVersions=@($new,$old)
    Save-DeploymentState -Config $Config -State $s
    Write-Success "Deployment promoted: $($new.versionName)"
}

# ===========================================================
# COMMON SERVICE / GIT HELPERS
# ===========================================================
function Get-PythonCreator {
    $py=Get-Command py -ErrorAction SilentlyContinue
    if($py){& py -3.11 -c "import sys" 2>$null;if($LASTEXITCODE -eq 0){return @{File="py";Args=@("-3.11")}};& py -3 -c "import sys" 2>$null;if($LASTEXITCODE -eq 0){return @{File="py";Args=@("-3")}}}
    $python=Get-Command python -ErrorAction SilentlyContinue
    if($python){return @{File=$python.Source;Args=@()}}
    throw "No usable Python found."
}

function Install-OrKeepService {
    param([string]$ServiceName,[string]$RunnerScript,[string]$LogPath)
    $svc=Get-Service $ServiceName -ErrorAction SilentlyContinue
    if($svc){Write-Success "$ServiceName service registration kept";return}
    $powershellExe="C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    $paramStr="-ExecutionPolicy Bypass -File `"$RunnerScript`""
    servy-cli install --name="$ServiceName" --path="$powershellExe" --params="$paramStr" 2>&1 | Add-FileLog -Path $LogPath
    if(-not(Get-Service $ServiceName -ErrorAction SilentlyContinue)){throw "Service '$ServiceName' was not created."}
    sc.exe config "$ServiceName" start= delayed-auto 2>&1 | Add-FileLog -Path $LogPath
    sc.exe failure "$ServiceName" reset= 86400 actions= restart/5000/restart/15000/restart/60000 2>&1 | Add-FileLog -Path $LogPath
    sc.exe failureflag "$ServiceName" 1 2>&1 | Add-FileLog -Path $LogPath
    Write-Success "$ServiceName service created"
}

function Stop-ServiceIfRunning {
    param([string]$ServiceName)
    $svc=Get-Service $ServiceName -ErrorAction SilentlyContinue
    if($svc -and $svc.Status -ne 'Stopped'){Stop-Service $ServiceName -Force -ErrorAction Stop;$svc.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))}
}

function Get-RemoteHead {
    param([string]$RepoDir,[string]$Branch,[string]$LogPath)
    git -C $RepoDir fetch --prune origin "+refs/heads/${Branch}:refs/remotes/origin/${Branch}" 2>&1 | Add-FileLog -Path $LogPath
    if($LASTEXITCODE -ne 0){throw "Could not fetch branch '$Branch'."}
    $h=(& git -C $RepoDir rev-parse "origin/$Branch" 2>$null | Select-Object -First 1)
    if([string]::IsNullOrWhiteSpace("$h")){throw "Could not resolve origin/$Branch"}
    return "$h".Trim()
}

# ===========================================================
# FRONTEND
# ===========================================================
function Install-Frontend {
    param($Config)
    Initialize-InstallRoot -Config $Config
    $appDir=Join-Path $Config.InstallRoot "frontend"
    $repoDir=Join-Path $appDir "repo"
    $logsDir=Join-Path $Config.InstallRoot "logs\\frontend"
    New-Item $logsDir -ItemType Directory -Force | Out-Null
    $log=Join-Path $logsDir ("frontend_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $svcName=Get-DeployServiceName -Config $Config -Component "frontend"
    $wasInstalled=Test-ComponentInstalled -Config $Config -Component "frontend"
    $oldGood=Get-DeploymentComponentCurrent -Config $Config -Component "frontend"
    if([string]::IsNullOrWhiteSpace($oldGood)){$oldGood=Get-GitHead $repoDir}
    $liveChanged=$false
    Write-Step ($(if($wasInstalled){"Updating Frontend"}else{"Installing Frontend"}))
    if($script:dryRun){return $true}

    try{
        New-Item $appDir -ItemType Directory -Force | Out-Null
        if(Test-Path (Join-Path $repoDir ".git")){
            $remote=Get-RemoteHead -RepoDir $repoDir -Branch $Config.FrontendBranch -LogPath $log
            $local=Get-GitHead $repoDir
            if($wasInstalled -and $local -eq $remote){Write-Success "Frontend already current: $local";Register-SuccessfulComponentDeployment $Config "frontend" $local;return $true}

            if($wasInstalled){
                $candidateDir=Join-Path $appDir "_candidate"
                & git -C $repoDir worktree remove --force $candidateDir 2>$null | Out-Null
                Remove-Item $candidateDir -Recurse -Force -ErrorAction SilentlyContinue
                & git -C $repoDir worktree prune 2>$null | Out-Null
                try{
                    git -C $repoDir worktree add --detach $candidateDir $remote 2>&1 | Add-FileLog -Path $log
                    if($LASTEXITCODE -ne 0){throw "Could not create frontend candidate worktree."}
                    Push-Location $candidateDir
                    try{
                        npm install --legacy-peer-deps 2>&1 | Add-FileLog -Path $log
                        if($LASTEXITCODE -ne 0){throw "Candidate npm install failed."}
                        $env:VITE_API_URL=$Config.ApiPrefix
                        npm run build 2>&1 | Add-FileLog -Path $log
                        if($LASTEXITCODE -ne 0 -or -not(Test-Path (Join-Path $candidateDir "dist"))){throw "Candidate frontend build failed."}
                    }finally{Pop-Location}
                }finally{
                    & git -C $repoDir worktree remove --force $candidateDir 2>$null | Out-Null
                    Remove-Item $candidateDir -Recurse -Force -ErrorAction SilentlyContinue
                    & git -C $repoDir worktree prune 2>$null | Out-Null
                }
            }
            Stop-ServiceIfRunning $svcName
            $liveChanged=$true;$script:liveComponentsChanged += "frontend"
            git -C $repoDir reset --hard "origin/$($Config.FrontendBranch)" 2>&1 | Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){throw "Frontend git reset failed."}
            git -C $repoDir clean -fd 2>&1 | Add-FileLog -Path $log
        }else{
            if(Test-Path $repoDir){Remove-Item $repoDir -Recurse -Force}
            git clone --branch $Config.FrontendBranch $Config.FrontendRepo $repoDir 2>&1 | Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){throw "Frontend clone failed."}
        }

        Push-Location $repoDir
        try{
            npm install --legacy-peer-deps 2>&1 | Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){throw "Frontend npm install failed."}
            if(-not(Test-Path (Join-Path $repoDir "node_modules\\serve\\build\\main.js"))){npm install --no-save serve --legacy-peer-deps 2>&1 | Add-FileLog -Path $log}
            $env:VITE_API_URL=$Config.ApiPrefix
            npm run build 2>&1 | Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){throw "Frontend build failed."}
        }finally{Pop-Location}
        if(-not(Test-Path (Join-Path $repoDir "dist"))){throw "Frontend dist not created."}

        $runner=Join-Path $appDir "frontend-run.ps1"
        $runnerContent=@'
$ErrorActionPreference="Stop"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$repo=Join-Path $root "repo"
$dist=Join-Path $repo "dist"
$serve=Join-Path $repo "node_modules\serve\build\main.js"
$logs=Join-Path (Split-Path $root -Parent) "logs\frontend"
New-Item $logs -ItemType Directory -Force | Out-Null
$log=Join-Path $logs ("frontend_service_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
function Log($m){"[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$m|Add-Content $log}
try{$node=(Get-Command node.exe -ErrorAction Stop).Source;Log "Serving $dist";& $node $serve -s $dist -l "__PORT__" 2>&1|ForEach-Object{Log "$_"};exit $LASTEXITCODE}catch{Log "ERROR: $($_.Exception.Message)";exit 1}
'@
        $runnerContent=$runnerContent.Replace('__PORT__',"$($Config.FrontendPort)")
        Set-Content $runner $runnerContent -Encoding UTF8 -Force
        Install-OrKeepService -ServiceName $svcName -RunnerScript $runner -LogPath $log
        Stop-ServiceIfRunning $svcName
        Start-Service $svcName -ErrorAction Stop
        if(-not(Test-Endpoint -Url "http://127.0.0.1:$($Config.FrontendPort)" -Name "Frontend")){throw "Frontend health failed."}
        $candidate=Get-GitHead $repoDir
        Register-SuccessfulComponentDeployment $Config "frontend" $candidate
        return $true
    }catch{
        Write-Err "Frontend setup failed: $_"
        if($liveChanged -and -not[string]::IsNullOrWhiteSpace($oldGood) -and (Ensure-GitCommitAvailable $repoDir $oldGood)){
            Write-Warn "Restoring frontend known-good commit: $oldGood"
            Stop-ServiceIfRunning $svcName
            git -C $repoDir reset --hard $oldGood | Out-Null
            Push-Location $repoDir;try{npm install --legacy-peer-deps|Out-Null;$env:VITE_API_URL=$Config.ApiPrefix;npm run build|Out-Null}finally{Pop-Location}
            Start-Service $svcName -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# ===========================================================
# PYTHON STACK: backend / report-worker
# One shared repository, with independent venvs, runners and services.
# ===========================================================
function Install-StackRequirements {
    param($Config,[string]$Python,[string]$Requirements,[string]$LogPath,[string]$Label)
    if(-not(Test-Path $Requirements)){throw "$Label requirements file not found: $Requirements"}
    $cache=Join-Path $Config.InstallRoot "pip-cache"
    New-Item $cache -ItemType Directory -Force|Out-Null
    & $Python -m pip install --upgrade pip setuptools wheel 2>&1|Add-FileLog -Path $LogPath
    if($LASTEXITCODE -ne 0){throw "$Label pip bootstrap failed."}
    & $Python -m pip install --cache-dir $cache -r $Requirements 2>&1|Add-FileLog -Path $LogPath
    if($LASTEXITCODE -ne 0){throw "$Label dependency install failed."}
}

function New-StackVenv {
    param([string]$Path,[string]$LogPath)
    if(Test-Path $Path){Remove-Item $Path -Recurse -Force -ErrorAction Stop}
    New-Item (Split-Path $Path -Parent) -ItemType Directory -Force|Out-Null
    $creator=Get-PythonCreator
    $args=@();$args+=$creator.Args;$args+=@("-m","venv",$Path)
    & $creator.File @args 2>&1|Add-FileLog -Path $LogPath
    $python=Join-Path $Path "Scripts\python.exe"
    if($LASTEXITCODE -ne 0 -or -not(Test-Path $python)){throw "Python venv was not created: $Path"}
    return $python
}

function Get-WorkerRequirementsPath {
    param([string]$RepoDir)
    $workerRequirements=Join-Path $RepoDir "requirements-worker.txt"
    if(Test-Path $workerRequirements){return $workerRequirements}
    Write-Warn "requirements-worker.txt is unavailable at this commit; using full requirements for compatibility."
    return (Join-Path $RepoDir "requirements.txt")
}

function Initialize-BackendStackRuntime {
    param($Config,$Secrets,[string]$LogPath)
    $backendDir=Join-Path $Config.InstallRoot "backend"
    $repoDir=Join-Path $backendDir "repo"
    $workerDir=Join-Path $Config.InstallRoot "report-worker"
    $backendVenv=Join-Path $repoDir "venv"
    $workerVenv=Join-Path $workerDir "venv"
    $backendSvc=Get-DeployServiceName $Config "backend"
    $workerSvc=Get-DeployServiceName $Config "report-worker"
    New-Item $workerDir -ItemType Directory -Force|Out-Null

    $backendPython=New-StackVenv -Path $backendVenv -LogPath $LogPath
    Install-StackRequirements -Config $Config -Python $backendPython -Requirements (Join-Path $repoDir "requirements.txt") -LogPath $LogPath -Label "Backend"
    $workerPython=New-StackVenv -Path $workerVenv -LogPath $LogPath
    Install-StackRequirements -Config $Config -Python $workerPython -Requirements (Get-WorkerRequirementsPath $repoDir) -LogPath $LogPath -Label "Report worker"
    Write-MoEnvFile -Config $Config -Secrets $Secrets -RepoDir $repoDir

    Push-Location $repoDir
    try{
        $backendCheck=& $backendPython -X faulthandler -c "import app.main; print('APP_OK')" 2>&1
        if($LASTEXITCODE -ne 0 -or ($backendCheck -join ' ') -notmatch 'APP_OK'){throw "Backend import failed: $backendCheck"}
        $workerCheck=& $workerPython -X faulthandler -c "import app.workers.mo_report_export_worker; print('WORKER_OK')" 2>&1
        if($LASTEXITCODE -ne 0 -or ($workerCheck -join ' ') -notmatch 'WORKER_OK'){throw "Worker import failed: $workerCheck"}
    }finally{Pop-Location}

    $backendRunner=Join-Path $backendDir "backend-run.ps1"
    $backendRunnerContent=@'
$ErrorActionPreference="Continue";$ProgressPreference="SilentlyContinue";$env:PYTHONUNBUFFERED="1";$env:PYTHONFAULTHANDLER="1"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path;$repo=Join-Path $root "repo";$python=Join-Path $repo "venv\Scripts\python.exe";$logs=Join-Path (Split-Path $root -Parent) "logs\backend";New-Item $logs -ItemType Directory -Force|Out-Null
$ts=Get-Date -Format "yyyyMMdd-HHmmss";$out=Join-Path $logs "backend_stdout_$ts.log";$err=Join-Path $logs "backend_stderr_$ts.log"
Set-Location $repo
$p=Start-Process -FilePath $python -ArgumentList @("-X","faulthandler","-u","-m","uvicorn","app.main:app","--host","0.0.0.0","--port","__PORT__","--no-use-colors") -WorkingDirectory $repo -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait -PassThru
exit $p.ExitCode
'@
    $backendRunnerContent=$backendRunnerContent.Replace('__PORT__',"$($Config.BackendPort)")
    Set-Content $backendRunner $backendRunnerContent -Encoding UTF8 -Force

    $workerRunner=Join-Path $workerDir "mo-report-worker-run.ps1"
    $workerRunnerContent=@'
$ErrorActionPreference="Continue";$ProgressPreference="SilentlyContinue";$env:PYTHONUNBUFFERED="1";$env:PYTHONFAULTHANDLER="1"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path;$installRoot=Split-Path $root -Parent;$repo=Join-Path $installRoot "backend\repo";$python=Join-Path $root "venv\Scripts\python.exe";$logs=Join-Path $installRoot "logs\report-worker";New-Item $logs -ItemType Directory -Force|Out-Null
$ts=Get-Date -Format "yyyyMMdd-HHmmss";$out=Join-Path $logs "worker_stdout_$ts.log";$err=Join-Path $logs "worker_stderr_$ts.log"
Set-Location $repo
$p=Start-Process -FilePath $python -ArgumentList @("-X","faulthandler","-u","-m","app.workers.mo_report_export_worker") -WorkingDirectory $repo -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait -PassThru
exit $p.ExitCode
'@
    Set-Content $workerRunner $workerRunnerContent -Encoding UTF8 -Force

    Install-OrKeepService -ServiceName $backendSvc -RunnerScript $backendRunner -LogPath $LogPath
    Install-OrKeepService -ServiceName $workerSvc -RunnerScript $workerRunner -LogPath $LogPath
    Start-Service $backendSvc -ErrorAction Stop
    if(-not(Test-Endpoint -Url "http://127.0.0.1:$($Config.BackendPort)$($Config.ApiPrefix)/health" -Name "Backend API")){throw "Backend health failed."}
    Start-Service $workerSvc -ErrorAction Stop
    Start-Sleep -Seconds 2
    $workerStatus=Get-Service $workerSvc -ErrorAction SilentlyContinue
    if(-not $workerStatus -or $workerStatus.Status -ne 'Running'){throw "Report worker service did not remain running."}
    Write-Success "MO report worker: running on shared backend source"
}

function Install-BackendStack {
    param($Config,$Secrets)
    Initialize-InstallRoot -Config $Config
    $backendDir=Join-Path $Config.InstallRoot "backend"
    $repoDir=Join-Path $backendDir "repo"
    $workerDir=Join-Path $Config.InstallRoot "report-worker"
    $logsDir=Join-Path $Config.InstallRoot "logs\backend-stack"
    New-Item $logsDir -ItemType Directory -Force|Out-Null
    $log=Join-Path $logsDir ("backend-stack_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $backendSvc=Get-DeployServiceName $Config "backend"
    $workerSvc=Get-DeployServiceName $Config "report-worker"
    $oldGood=Get-DeploymentComponentCurrent $Config "backend"
    if([string]::IsNullOrWhiteSpace($oldGood)){$oldGood=Get-GitHead $repoDir}
    $liveChanged=$false
    Write-Step "Installing/updating Backend API and MO Report Worker"
    if($script:dryRun){return $true}

    try{
        New-Item $backendDir -ItemType Directory -Force|Out-Null
        New-Item $workerDir -ItemType Directory -Force|Out-Null
        if(Test-Path (Join-Path $repoDir ".git")){
            $remote=Get-RemoteHead -RepoDir $repoDir -Branch $Config.BackendBranch -LogPath $log
            $local=Get-GitHead $repoDir
            $workerRunner=Join-Path $workerDir "mo-report-worker-run.ps1"
            $sharedWorkerReady=(Test-ComponentInstalled $Config "report-worker") -and (Test-Path $workerRunner) -and (Select-String -Path $workerRunner -SimpleMatch 'backend\repo' -Quiet -ErrorAction SilentlyContinue)
            if((Test-ComponentInstalled $Config "backend") -and $sharedWorkerReady -and $local -eq $remote){
                foreach($svcName in @($backendSvc,$workerSvc)){$svc=Get-Service $svcName -ErrorAction SilentlyContinue;if($svc -and $svc.Status -ne 'Running'){Start-Service $svcName -ErrorAction Stop}}
                Register-SuccessfulComponentDeployment $Config "backend" $local
                Register-SuccessfulComponentDeployment $Config "report-worker" $local
                Write-Success "Backend and report worker already current: $local"
                return $true
            }

            if($local -ne $remote){
                $candidateDir=Join-Path $backendDir "_candidate"
                & git -C $repoDir worktree remove --force $candidateDir 2>$null|Out-Null
                Remove-Item $candidateDir -Recurse -Force -ErrorAction SilentlyContinue
                & git -C $repoDir worktree prune 2>$null|Out-Null
                try{
                    git -C $repoDir worktree add --detach $candidateDir $remote 2>&1|Add-FileLog -Path $log
                    if($LASTEXITCODE -ne 0){throw "Could not create backend stack candidate worktree."}
                    $candidateBackendPython=New-StackVenv -Path (Join-Path $candidateDir ".candidate-backend-venv") -LogPath $log
                    Install-StackRequirements $Config $candidateBackendPython (Join-Path $candidateDir "requirements.txt") $log "Backend candidate"
                    $candidateWorkerPython=New-StackVenv -Path (Join-Path $candidateDir ".candidate-worker-venv") -LogPath $log
                    Install-StackRequirements $Config $candidateWorkerPython (Get-WorkerRequirementsPath $candidateDir) $log "Worker candidate"
                    Push-Location $candidateDir
                    try{
                        $chk=& $candidateBackendPython -X faulthandler -c "import app.main; print('APP_OK')" 2>&1
                        if($LASTEXITCODE -ne 0 -or ($chk -join ' ') -notmatch 'APP_OK'){throw "Backend candidate import failed: $chk"}
                        $chk=& $candidateWorkerPython -X faulthandler -c "import app.workers.mo_report_export_worker; print('WORKER_OK')" 2>&1
                        if($LASTEXITCODE -ne 0 -or ($chk -join ' ') -notmatch 'WORKER_OK'){throw "Worker candidate import failed: $chk"}
                    }finally{Pop-Location}
                }finally{
                    & git -C $repoDir worktree remove --force $candidateDir 2>$null|Out-Null
                    Remove-Item $candidateDir -Recurse -Force -ErrorAction SilentlyContinue
                    & git -C $repoDir worktree prune 2>$null|Out-Null
                }
            }

            Stop-ServiceIfRunning $workerSvc
            Stop-ServiceIfRunning $backendSvc
            $liveChanged=$true;$script:liveComponentsChanged+=@("backend","report-worker")
            git -C $repoDir reset --hard "origin/$($Config.BackendBranch)" 2>&1|Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){throw "Backend stack git reset failed."}
            git -C $repoDir clean -fd 2>&1|Add-FileLog -Path $log
        }else{
            Stop-ServiceIfRunning $workerSvc
            Stop-ServiceIfRunning $backendSvc
            if(Test-Path $repoDir){Remove-Item $repoDir -Recurse -Force}
            git clone --branch $Config.BackendBranch $Config.BackendRepo $repoDir 2>&1|Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){throw "Backend stack clone failed."}
            $liveChanged=$true;$script:liveComponentsChanged+=@("backend","report-worker")
        }

        Initialize-BackendStackRuntime -Config $Config -Secrets $Secrets -LogPath $log
        $candidate=Get-GitHead $repoDir
        Register-SuccessfulComponentDeployment $Config "backend" $candidate
        Register-SuccessfulComponentDeployment $Config "report-worker" $candidate

        $legacyWorkerRepo=Join-Path $workerDir "repo"
        if(Test-Path $legacyWorkerRepo){
            try{Remove-Item $legacyWorkerRepo -Recurse -Force -ErrorAction Stop;Write-Success "Removed legacy duplicate worker repository"}
            catch{Write-Warn "Could not remove legacy worker repository: $_"}
        }
        return $true
    }catch{
        Write-Err "Backend stack setup failed: $_"
        if($liveChanged -and -not[string]::IsNullOrWhiteSpace($oldGood) -and (Ensure-GitCommitAvailable $repoDir $oldGood)){
            Write-Warn "Restoring backend and worker known-good commit: $oldGood"
            try{
                Stop-ServiceIfRunning $workerSvc
                Stop-ServiceIfRunning $backendSvc
                git -C $repoDir reset --hard $oldGood|Out-Null
                Initialize-BackendStackRuntime -Config $Config -Secrets $Secrets -LogPath $log
            }catch{Write-Err "Automatic backend stack restore failed: $_"}
        }
        return $false
    }
}

function Install-Backend { param($Config,$Secrets); return (Install-BackendStack -Config $Config -Secrets $Secrets) }
function Install-ReportWorker { param($Config,$Secrets); return (Install-BackendStack -Config $Config -Secrets $Secrets) }

# ===========================================================
# CADDY
# ===========================================================
function Initialize-CaddyLocalGit {
    param($Config)
    $dir=Join-Path $Config.InstallRoot "caddy";New-Item $dir -ItemType Directory -Force|Out-Null
    if(-not(Test-Path (Join-Path $dir ".git"))){git -C $dir init|Out-Null;git -C $dir config user.name "ESS Deployment Manager";git -C $dir config user.email "deployment@localhost"}
    Set-Content (Join-Path $dir ".gitignore") "caddy.exe`ncaddy-ports.json`n*.log`n" -Encoding UTF8
}

function Commit-CaddyLocalVersion {
    param($Config,[string]$Message="Known-good Caddy configuration")
    $dir=Join-Path $Config.InstallRoot "caddy";Initialize-CaddyLocalGit $Config
    git -C $dir add Caddyfile caddy-run.ps1 .gitignore 2>$null
    git -C $dir diff --cached --quiet 2>$null
    if($LASTEXITCODE -ne 0){git -C $dir commit -m $Message|Out-Null}
    return (Get-GitHead $dir)
}

function Install-Caddy {
    param($Config)
    Initialize-InstallRoot $Config
    $dir=Join-Path $Config.InstallRoot "caddy";$logs=Join-Path $Config.InstallRoot "logs\\caddy";New-Item $logs -ItemType Directory -Force|Out-Null
    $log=Join-Path $logs ("caddy_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"));$svcName=Get-DeployServiceName $Config "caddy"
    $oldGood=Get-DeploymentComponentCurrent $Config "caddy";$wasInstalled=Test-ComponentInstalled $Config "caddy"
    Write-Step ($(if($wasInstalled){"Updating Caddy"}else{"Installing Caddy"}))
    if($script:dryRun){return $true}
    try{
        New-Item $dir -ItemType Directory -Force|Out-Null
        $exe=Join-Path $dir "caddy.exe"
        if(-not(Test-Path $exe)){
            $zip=Join-Path $dir "caddy.zip"
            $extractDir=Join-Path $dir "_caddy_extract"
            $version="$($Config.CaddyVersion)".Trim().TrimStart('v')
            $expectedHash="$($Config.CaddyWindowsAmd64Sha256)".Trim().ToLowerInvariant()
            if($version -notmatch '^\d+\.\d+\.\d+$'){throw "Invalid CaddyVersion '$version'."}
            if($expectedHash -notmatch '^[a-f0-9]{64}$'){throw "Invalid Caddy Windows SHA256 checksum."}
            $downloadUrl="https://github.com/caddyserver/caddy/releases/download/v$version/caddy_${version}_windows_amd64.zip"
            $downloaded=$false

            for($attempt=1;$attempt -le 3;$attempt++){
                Remove-Item $zip -Force -ErrorAction SilentlyContinue
                Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
                try{
                    Write-Host "    Downloading Caddy v$version (attempt $attempt/3)..." -ForegroundColor Gray
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop
                    $zipInfo=Get-Item $zip -ErrorAction Stop
                    if($zipInfo.Length -lt 1MB){throw "Downloaded archive is unexpectedly small ($($zipInfo.Length) bytes)."}

                    $actualHash=(Get-FileHash -Path $zip -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                    if($actualHash -ne $expectedHash){throw "Caddy archive checksum mismatch."}

                    New-Item $extractDir -ItemType Directory -Force|Out-Null
                    Expand-Archive -Path $zip -DestinationPath $extractDir -Force -ErrorAction Stop
                    $downloadedExe=Get-ChildItem $extractDir -Filter "caddy.exe" -File -Recurse|Select-Object -First 1
                    if(-not $downloadedExe){throw "The Caddy archive does not contain caddy.exe."}
                    Move-Item $downloadedExe.FullName $exe -Force
                    & $exe version 2>&1|Add-FileLog -Path $log
                    if($LASTEXITCODE -ne 0){throw "Downloaded caddy.exe could not start."}
                    $downloaded=$true
                    break
                }catch{
                    Remove-Item $exe -Force -ErrorAction SilentlyContinue
                    if($attempt -eq 3){throw "Caddy download failed after 3 attempts: $($_.Exception.Message)"}
                    Write-Warn "Caddy download attempt $attempt failed: $($_.Exception.Message). Retrying..."
                    Start-Sleep -Seconds (2*$attempt)
                }finally{
                    Remove-Item $zip -Force -ErrorAction SilentlyContinue
                    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            if(-not $downloaded -or -not(Test-Path $exe)){throw "caddy.exe download failed."}
        }
        Stop-ServiceIfRunning $svcName
        foreach($p in @($Config.CaddyPort,$Config.CaddyAdminPort)){if(Test-PortInUse ([int]$p)){throw "Port $p is already in use."}}

        $caddyfile=Join-Path $dir "Caddyfile"
        $routes = @()
        if (($Config | Get-Member -Name "CaddyRoutes" -ErrorAction SilentlyContinue) -and $Config.CaddyRoutes -and @($Config.CaddyRoutes).Count -gt 0) {
            $routes = @($Config.CaddyRoutes)
        } else {
            $routes = @(
                [PSCustomObject]@{ Path = "$($Config.ApiPrefix)/*"; Target = "127.0.0.1:$($Config.BackendPort)"; Label = "Backend" },
                [PSCustomObject]@{ Path = "/*"; Target = "127.0.0.1:$($Config.FrontendPort)"; Label = "Frontend" }
            )
        }
        $routes = @($routes | Sort-Object @{ Expression = { if ("$($_.Path)".Trim() -eq "/*") { 1 } else { 0 } } })

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("{")
        $lines.Add("    admin 127.0.0.1:$($Config.CaddyAdminPort)")
        $lines.Add("    auto_https off")
        $lines.Add("}")
        $lines.Add("")
        $lines.Add(":$($Config.CaddyPort) {")
        foreach ($r in $routes) {
            $path = "$($r.Path)".Trim()
            $target = "$($r.Target)".Trim()
            if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($target)) { continue }
            if ($path -eq "/*") {
                $lines.Add("    handle {")
                $lines.Add("        reverse_proxy $target")
                $lines.Add("    }")
            } else {
                $lines.Add("    handle $path {")
                $lines.Add("        reverse_proxy $target")
                $lines.Add("    }")
            }
            $lines.Add("")
        }
        $lines.Add("}")
        Set-Content $caddyfile ($lines -join [Environment]::NewLine) -Encoding UTF8 -Force
        $runner=Join-Path $dir "caddy-run.ps1"
        $runnerContent=@'
$ErrorActionPreference="Stop"
$dir=Split-Path -Parent $MyInvocation.MyCommand.Path;$exe=Join-Path $dir "caddy.exe";$cfg=Join-Path $dir "Caddyfile";$ports=Join-Path $dir "caddy-ports.json"
@{proxy=__PROXY__;admin=__ADMIN__}|ConvertTo-Json|Set-Content $ports -Encoding UTF8 -Force
Set-Location $dir
& $exe run --config $cfg --adapter caddyfile
exit $LASTEXITCODE
'@
        $runnerContent=$runnerContent.Replace('__PROXY__',"$($Config.CaddyPort)").Replace('__ADMIN__',"$($Config.CaddyAdminPort)")
        Set-Content $runner $runnerContent -Encoding UTF8 -Force
        Initialize-CaddyLocalGit $Config
        $candidate=Commit-CaddyLocalVersion -Config $Config -Message "Caddy config $(Get-Date -Format s)"
        $script:liveComponentsChanged += "caddy"
        Install-OrKeepService $svcName $runner $log
        Stop-ServiceIfRunning $svcName;Start-Service $svcName -ErrorAction Stop
        if(-not(Test-Endpoint -Url "http://127.0.0.1:$($Config.CaddyPort)$($Config.ApiPrefix)/health" -Name "Caddy proxy")){throw "Caddy proxy health failed."}
        Register-SuccessfulComponentDeployment $Config "caddy" $candidate
        return $true
    }catch{
        Write-Err "Caddy setup failed: $_"
        if(-not[string]::IsNullOrWhiteSpace($oldGood) -and (Test-Path (Join-Path $dir ".git")) -and (Ensure-GitCommitAvailable $dir $oldGood)){
            Write-Warn "Restoring Caddy known-good commit: $oldGood";Stop-ServiceIfRunning $svcName;git -C $dir reset --hard $oldGood|Out-Null;Start-Service $svcName -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# ===========================================================
# ROLLBACK BY deployment-state.json + local Git
# ===========================================================
function Invoke-FrontendRollbackToCommit {
    param($Config,[string]$Commit)
    $dir=Join-Path $Config.InstallRoot "frontend\\repo";$svc=Get-DeployServiceName $Config "frontend"
    try{
        if(-not(Ensure-GitCommitAvailable $dir $Commit)){throw "Commit unavailable: $Commit"}
        Stop-ServiceIfRunning $svc;git -C $dir reset --hard $Commit|Out-Null
        Push-Location $dir;try{npm install --legacy-peer-deps|Out-Null;$env:VITE_API_URL=$Config.ApiPrefix;npm run build|Out-Null}finally{Pop-Location}
        Start-Service $svc -ErrorAction Stop
        return (Test-Endpoint -Url "http://127.0.0.1:$($Config.FrontendPort)" -Name "Frontend rollback")
    }catch{Write-Err "Frontend rollback failed: $_";return $false}
}

function Invoke-PythonRollbackToCommit {
    param($Config,$Secrets,[string]$Component,[string]$Commit)
    $dir=Join-Path $Config.InstallRoot "backend\repo"
    $backendSvc=Get-DeployServiceName $Config "backend"
    $workerSvc=Get-DeployServiceName $Config "report-worker"
    $logs=Join-Path $Config.InstallRoot "logs\backend-stack"
    New-Item $logs -ItemType Directory -Force|Out-Null
    $log=Join-Path $logs ("rollback_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    try{
        if(-not(Ensure-GitCommitAvailable $dir $Commit)){throw "Commit unavailable: $Commit"}
        Stop-ServiceIfRunning $workerSvc
        Stop-ServiceIfRunning $backendSvc
        git -C $dir reset --hard $Commit 2>&1|Add-FileLog -Path $log
        if($LASTEXITCODE -ne 0){throw "Backend stack git rollback failed."}
        Initialize-BackendStackRuntime -Config $Config -Secrets $Secrets -LogPath $log
        return $true
    }catch{Write-Err "Backend and report-worker rollback failed: $_";return $false}
}

function Invoke-CaddyRollbackToCommit {
    param($Config,[string]$Commit)
    $dir=Join-Path $Config.InstallRoot "caddy";$svc=Get-DeployServiceName $Config "caddy"
    try{if(-not(Ensure-GitCommitAvailable $dir $Commit)){throw "Commit unavailable: $Commit"};Stop-ServiceIfRunning $svc;git -C $dir reset --hard $Commit|Out-Null;Start-Service $svc -ErrorAction Stop;return (Test-Endpoint -Url "http://127.0.0.1:$($Config.CaddyPort)$($Config.ApiPrefix)/health" -Name "Caddy rollback")}catch{Write-Err "Caddy rollback failed: $_";return $false}
}

function Invoke-SelectedRollback {
    param($Config,$Secrets,[string]$Key,[string]$Commit)
    switch($Key){
        "frontend"{return (Invoke-FrontendRollbackToCommit $Config $Commit)}
        "backend"{return (Invoke-PythonRollbackToCommit $Config $Secrets "backend" $Commit)}
        "report-worker"{return (Invoke-PythonRollbackToCommit $Config $Secrets "report-worker" $Commit)}
        "caddy"{return (Invoke-CaddyRollbackToCommit $Config $Commit)}
    }
    return $false
}

function Show-RollbackMenu {
    param($Config)
    $state=Get-DeploymentState $Config
    if(-not $state -or -not $state.deploymentVersions -or @($state.deploymentVersions).Count -lt 2){Write-Warn "No previous complete deployment version available.";return}
    $versions=@($state.deploymentVersions);$current=$versions[0];$target=$versions[1]
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host " Rollback Complete Deployment" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Current : $($current.versionName)" -ForegroundColor Green
    Write-Host " Previous: $($target.versionName)" -ForegroundColor Gray
    foreach($k in (Get-ComponentKeys)){Write-Host (" {0,-14} {1}" -f $k,"$($target.components.$k.current)") -ForegroundColor Gray}
    if(-not(Confirm-Step "Rollback $($current.versionName) -> $($target.versionName)?" -DefaultYes:$false)){return}
    $secrets=Get-SecretsOrInitialize;if(-not $secrets){return}
    $restored=@();$ok=$true
    $caddyCommit="$($target.components.caddy.current)".Trim()
    if(-not[string]::IsNullOrWhiteSpace($caddyCommit)){$ok=Invoke-SelectedRollback $Config $secrets "caddy" $caddyCommit;if($ok){$restored+="caddy"}}
    $backendCommit="$($target.components.backend.current)".Trim()
    if([string]::IsNullOrWhiteSpace($backendCommit)){$backendCommit="$($target.components.'report-worker'.current)".Trim()}
    if($ok -and -not[string]::IsNullOrWhiteSpace($backendCommit)){$ok=Invoke-SelectedRollback $Config $secrets "backend" $backendCommit;if($ok){$restored+=@("backend","report-worker")}}
    $frontendCommit="$($target.components.frontend.current)".Trim()
    if($ok -and -not[string]::IsNullOrWhiteSpace($frontendCommit)){$ok=Invoke-SelectedRollback $Config $secrets "frontend" $frontendCommit;if($ok){$restored+="frontend"}}
    if(-not $ok){Write-Err "Rollback incomplete. deployment-state.json was not changed.";return}
    $state.deploymentVersions=@($target,$current);Save-DeploymentState $Config $state
    Write-Success "Rollback complete. Current: $($target.versionName)"
}

function Restore-DeploymentStateBeforeRun {
    param($Config,$Secrets)
    if(-not $script:deploymentStateBeforeRun){Write-Warn "No previous deployment state to restore.";return $false}
    $v=@($script:deploymentStateBeforeRun.deploymentVersions)[0];if(-not $v){return $false}
    Write-Step "RESTORING previous known-good deployment"
    $ok=$true
    $caddyCommit="$($v.components.caddy.current)".Trim()
    if(-not[string]::IsNullOrWhiteSpace($caddyCommit)){$ok=Invoke-SelectedRollback $Config $Secrets "caddy" $caddyCommit}
    $backendCommit="$($v.components.backend.current)".Trim()
    if([string]::IsNullOrWhiteSpace($backendCommit)){$backendCommit="$($v.components.'report-worker'.current)".Trim()}
    if($ok -and -not[string]::IsNullOrWhiteSpace($backendCommit)){$ok=Invoke-SelectedRollback $Config $Secrets "backend" $backendCommit}
    $frontendCommit="$($v.components.frontend.current)".Trim()
    if($ok -and -not[string]::IsNullOrWhiteSpace($frontendCommit)){$ok=Invoke-SelectedRollback $Config $Secrets "frontend" $frontendCommit}
    if($ok){Save-DeploymentState $Config $script:deploymentStateBeforeRun;Write-Success "Previous known-good deployment restored."}
    return $ok
}

# ===========================================================
# INSTALL / REMOVE / STATUS / SERVICE CONTROL
# ===========================================================
function Invoke-ComponentInstall {
    param($Key,$Config)
    $secrets=$null
    if($Key -in @("backend","report-worker")){$secrets=Get-SecretsOrInitialize;if(-not $secrets){return $false};if(-not(Confirm-DeploymentCredentials $secrets)){return $false}}
    switch($Key){
        "frontend"{return (Install-Frontend $Config)}
        "backend"{return (Install-Backend $Config $secrets)}
        "report-worker"{return (Install-ReportWorker $Config $secrets)}
        "caddy"{return (Install-Caddy $Config)}
    }
    return $false
}

function Remove-Component {
    param($Key,$Config,[switch]$DeleteFiles)
    $svcName=Get-DeployServiceName $Config $Key
    Write-Step "Removing $Key"
    if(-not $script:dryRun){
        try{Stop-ServiceIfRunning $svcName}catch{}
        if(Get-Service $svcName -ErrorAction SilentlyContinue){servy-cli uninstall --name="$svcName" --quiet|Out-Null;Start-Sleep -Milliseconds 500}
        if($DeleteFiles){$dir=Join-Path $Config.InstallRoot $Key;if(Test-Path $dir){Remove-Item $dir -Recurse -Force}}
    }
    Write-Success "$Key removed"
}

function Show-Status {
    param($Config)
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host " ESS MO Service Status" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    $rows=@()
    foreach($c in (Get-Components $Config)){$s=Get-Service $c.Service -ErrorAction SilentlyContinue;$rows+=[PSCustomObject]@{Component=$c.Display;Service=$c.Service;State=if($s){$s.Status}else{"Not installed"}}}
    $rows|Format-Table -AutoSize|Out-Host
    $v=Get-CurrentDeploymentVersion $Config;if($v){Write-Host " Deployment: $($v.versionName)" -ForegroundColor Green}
    Verify-Health $Config|Out-Null
}

function Set-AllServiceState {
    param($Config,[ValidateSet("start","stop")][string]$Action)
    $order=if($Action -eq "start"){@("backend","report-worker","frontend","caddy")}else{@("caddy","frontend","report-worker","backend")}
    foreach($k in $order){$name=Get-DeployServiceName $Config $k;$s=Get-Service $name -ErrorAction SilentlyContinue;if(-not $s){continue};try{if($Action -eq "start" -and $s.Status -ne 'Running'){Start-Service $name}elseif($Action -eq "stop" -and $s.Status -ne 'Stopped'){Stop-Service $name -Force}}catch{Write-Warn "$Action $name failed: $_"}}
}

# ===========================================================
# FULL DEPLOYMENT TRANSACTION
# ===========================================================
function Invoke-FullDeploy {
    param($Config)
    $script:deploymentTransaction=$true;$script:deploymentCandidates=@{};$script:liveComponentsChanged=@();$script:deploymentStateBeforeRun=Copy-ObjectDeep (Get-DeploymentState $Config)
    Initialize-Logger $Config

    Write-Step "Checking network access"
    try {
        Invoke-WebRequest -Uri "https://github.com" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Success "Internet: OK"
    } catch {
        Write-Warn "Internet: unreachable - Git/npm/pip update operations may fail."
        if(-not $script:headless -and -not(Confirm-Step "Continue without internet?" -DefaultYes:$false)){
            Write-Warn "Deployment cancelled."
            $script:deploymentTransaction=$false
            return
        }
    }

    if(-not(Test-Prerequisites -CheckOnly)){Write-Err "Resolve missing prerequisites first.";$script:deploymentTransaction=$false;return}
    $targets=if($script:headless -and $Components.Count -gt 0){@($Components)}else{@(Get-ComponentKeys)}
    if(($targets -contains "backend") -or ($targets -contains "report-worker")){
        $targets=@($targets+@("backend","report-worker")|Select-Object -Unique)
        Write-Host "    Backend and report-worker update together from one shared source." -ForegroundColor Gray
    }
    $secrets=$null
    if(($targets -contains "backend") -or ($targets -contains "report-worker")){
        $secrets=Get-SecretsOrInitialize;if(-not $secrets){$script:deploymentTransaction=$false;return}
        if(-not(Confirm-DeploymentCredentials $secrets)){$script:deploymentTransaction=$false;return}
    }
    $ok=$true
    foreach($k in @("frontend","backend","report-worker","caddy")){
        if($targets -notcontains $k){continue}
        if($k -eq "report-worker"){continue}
        switch($k){"frontend"{$r=Install-Frontend $Config};"backend"{$r=Install-Backend $Config $secrets};"caddy"{$r=Install-Caddy $Config}}
        if(-not $r){$ok=$false;break}
    }
    if($ok){$ok=Verify-Health $Config}
    if($ok){Complete-FullDeploymentState $Config;Write-Success "Complete deployment successful."}
    else{
        Write-Err "Deployment failed. Restoring previous known-good deployment."
        if($script:deploymentStateBeforeRun){Restore-DeploymentStateBeforeRun $Config $secrets|Out-Null}
    }
    $script:deploymentTransaction=$false
}

# ===========================================================
# FACE-STYLE MAIN MENU / CADDY CONFIG / ENTRY
# ===========================================================
function Show-MainMenu {
    param($Config)
    Clear-Host

    $anyInstalled = Test-AnyComponentInstalled -Config $Config
    $installUpdateLabel = if (-not $anyInstalled) { "Install complete deployment" } else { "Update complete deployment" }

    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " MO-ESS Full-Stack Deployment Manager" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Environment: $(Get-DeployEnvironment -Config $Config)" -ForegroundColor Gray
    if (-not [string]::IsNullOrWhiteSpace($Config.InstallRoot)) {
        Write-Host " Install path: $($Config.InstallRoot)" -ForegroundColor Gray
    }

    $currentVersion = Get-CurrentDeploymentVersion -Config $Config
    if ($currentVersion) { Write-Host " Deployment: $($currentVersion.versionName)" -ForegroundColor Green }

    Write-Host ""
    Write-Host "  1) Check prerequisites" -ForegroundColor White
    Write-Host "  2) $installUpdateLabel" -ForegroundColor White
    Write-Host "  3) Uninstall complete deployment" -ForegroundColor White
    Write-Host "  4) Service status / health check" -ForegroundColor White
    Write-Host "  5) Start services" -ForegroundColor White
    Write-Host "  6) Stop services" -ForegroundColor White
    Write-Host "  7) Caddy network config" -ForegroundColor White
    Write-Host "  8) Open logs folder" -ForegroundColor White
    if (Test-DeploymentRollbackAvailable -Config $Config) {
        Write-Host "  9) Rollback deployment" -ForegroundColor White
    }
    Write-Host "  Q) Quit" -ForegroundColor White
    Write-Host ""
}

function Show-CaddyConfig {
    param($Config)
    $caddySvcName = Get-DeployServiceName -Config $Config -Component "caddy"

    do {
        $changed = $false
        $targets = @(
            [PSCustomObject]@{ Name = "Frontend (Node / Vite)"; Target = "127.0.0.1:$($Config.FrontendPort)"; DefaultPath = "/*" },
            [PSCustomObject]@{ Name = "Backend (FastAPI)"; Target = "127.0.0.1:$($Config.BackendPort)"; DefaultPath = "$($Config.ApiPrefix)/*" }
        )

        $routes = @()
        if (($Config | Get-Member -Name "CaddyRoutes" -ErrorAction SilentlyContinue) -and $Config.CaddyRoutes -and @($Config.CaddyRoutes).Count -gt 0) {
            $routes = @($Config.CaddyRoutes)
        } else {
            $routes = @(
                [PSCustomObject]@{ Path = "$($Config.ApiPrefix)/*"; Target = "127.0.0.1:$($Config.BackendPort)"; Label = "Backend" },
                [PSCustomObject]@{ Path = "/*"; Target = "127.0.0.1:$($Config.FrontendPort)"; Label = "Frontend" }
            )
        }

        $routedTargets = @($routes | ForEach-Object { $_.Target })
        $availableTargets = @($targets | Where-Object { $_.Target -notin $routedTargets })

        Write-Host ""
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host " Caddy Reverse Proxy Configuration" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        $ports = Get-CaddyActualPorts -Config $Config
        Write-Host " Caddy proxy : $($ports.proxy)" -ForegroundColor Green
        if ($ports.admin) { Write-Host " Caddy admin : $($ports.admin)" -ForegroundColor Gray }
        Write-Host ""
        Write-Host " Available targets:" -ForegroundColor White
        if ($availableTargets.Count -gt 0) {
            $i=1
            foreach($t in $availableTargets){ Write-Host "   $i) $($t.Name) -> $($t.Target)" -ForegroundColor Gray; $i++ }
        } else { Write-Host "   (all targets already registered)" -ForegroundColor DarkGray }

        Write-Host ""
        Write-Host " Caddy routes:" -ForegroundColor White
        for($i=0;$i -lt $routes.Count;$i++){
            Write-Host "   $($i+1)) $($routes[$i].Path) -> $($routes[$i].Target) [$($routes[$i].Label)]" -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host " 1) Add route to Caddy" -ForegroundColor Gray
        Write-Host " 2) Remove route from Caddy" -ForegroundColor Gray
        Write-Host " 3) Change Caddy listening port [$($Config.CaddyPort)]" -ForegroundColor Gray
        Write-Host " B) Back to main menu" -ForegroundColor Gray
        $sub=Read-Host "Select option"

        switch -Regex ($sub) {
            '^1$' {
                if ($availableTargets.Count -eq 0) { Write-Warn "All standard targets are already registered."; continue }
                Write-Host ""
                for($i=0;$i -lt $availableTargets.Count;$i++){
                    Write-Host " $($i+1)) $($availableTargets[$i].Name) -> $($availableTargets[$i].Target)" -ForegroundColor Gray
                }
                $n=Read-Host "Select target"
                if($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $availableTargets.Count){
                    $t=$availableTargets[[int]$n-1]
                    $path=Read-Host "Route path [$($t.DefaultPath)]"
                    if([string]::IsNullOrWhiteSpace($path)){$path=$t.DefaultPath}
                    $routes += [PSCustomObject]@{Path=$path;Target=$t.Target;Label=$t.Name}
                    $Config | Add-Member -NotePropertyName 'CaddyRoutes' -NotePropertyValue $routes -Force
                    Save-DeployConfig -Config $Config
                    $changed = $true
                    Write-Success "Caddy route saved."
                }
            }
            '^2$' {
                if($routes.Count -eq 0){Write-Warn "No routes to remove.";continue}
                $n=Read-Host "Route number to remove"
                if($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $routes.Count){
                    $idx=[int]$n-1
                    $newRoutes=@()
                    for($i=0;$i -lt $routes.Count;$i++){if($i -ne $idx){$newRoutes += $routes[$i]}}
                    if($newRoutes.Count -gt 0){$Config | Add-Member -NotePropertyName 'CaddyRoutes' -NotePropertyValue $newRoutes -Force}
                    else{$Config.PSObject.Properties.Remove('CaddyRoutes')}
                    Save-DeployConfig -Config $Config
                    $changed = $true
                    Write-Success "Caddy route removed."
                }
            }
            '^3$' {
                $newPort=Read-Host "New Caddy listening port [$($Config.CaddyPort)]"
                if([string]::IsNullOrWhiteSpace($newPort)){continue}
                if($newPort -notmatch '^\d+$' -or [int]$newPort -lt 1 -or [int]$newPort -gt 65535){Write-Warn "Invalid port.";continue}
                $Config.CaddyPort=[int]$newPort
                Save-DeployConfig -Config $Config
                $changed = $true
                Write-Success "Caddy port saved: $newPort."
            }
            '^[Bb]$' { break }
            default { Write-Warn "Unknown option." }
        }

        if($changed -and (Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue)){
            if(Confirm-Step "Regenerate Caddyfile and restart Caddy?" -DefaultYes:$true){
                if(Install-Caddy -Config $Config){Write-Success "Caddy configuration applied."}
                else{Write-Err "Caddy configuration could not be applied."}
            }
        }
    } while ($sub -notmatch '^[Bb]$')
}

function Start-AllServices {
    param($Config)
    Write-Step "Starting services"
    if($script:dryRun){Write-Warn "[DRY-RUN] Would start all installed services";return}
    foreach($c in Get-ServiceComponents -Config $Config){
        $svc=Get-Service -Name $c.Service -ErrorAction SilentlyContinue
        if(-not $svc){Write-Host "    Skipping $($c.Display) (not installed)" -ForegroundColor Gray;continue}
        if($svc.Status -eq 'Running'){Write-Host "    $($c.Display): already running" -ForegroundColor Green;continue}
        try{Start-Service -Name $c.Service -ErrorAction Stop;Write-Success "Started $($c.Display)"}
        catch{Write-Err "Failed to start $($c.Display): $_"}
    }
}

function Stop-AllServices {
    param($Config)
    Write-Step "Stopping services"
    if($script:dryRun){Write-Warn "[DRY-RUN] Would stop all running services";return}
    foreach($key in @("caddy","report-worker","backend","frontend")){
        $c=Get-ServiceComponents -Config $Config | Where-Object { $_.Key -eq $key } | Select-Object -First 1
        if(-not $c){continue}
        $svc=Get-Service -Name $c.Service -ErrorAction SilentlyContinue
        if(-not $svc){continue}
        if($svc.Status -ne 'Running'){Write-Host "    $($c.Display): already stopped" -ForegroundColor Gray;continue}
        try{Stop-Service -Name $c.Service -ErrorAction Stop;Write-Success "Stopped $($c.Display)"}
        catch{Write-Err "Failed to stop $($c.Display): $_"}
    }
}

# ===========================================================
# ENTRY
# ===========================================================
try {
    $Config=Get-DeployConfig
    if(-not $Config.InstallRoot){Select-InstallDrive $Config|Out-Null}
    Initialize-InstallRoot $Config

    if($Force -or $Components.Count -gt 0){Invoke-FullDeploy $Config;exit $(if($script:hasErrors){1}else{0})}

    do {
        Show-MainMenu -Config $Config
        $choice=Read-Host "Select option"

        switch -Regex ($choice) {
            '^1$' {
                Initialize-Logger -Config $Config
                Test-Prerequisites | Out-Null
            }
            '^2$' {
                $current=Get-CurrentDeploymentVersion -Config $Config
                Write-Host ""
                if($current){Write-Host " Current deployment: $($current.versionName)" -ForegroundColor Cyan;Write-Host " Updating complete deployment..." -ForegroundColor Gray}
                else{Write-Host " First deployment: v1" -ForegroundColor Cyan;Write-Host " Installing complete deployment..." -ForegroundColor Gray}
                Invoke-FullDeploy -Config $Config
            }
            '^3$' {
                $compList=Get-Components -Config $Config
                Write-Host ""
                Write-Host "============================================" -ForegroundColor Cyan
                Write-Host " Uninstall Complete Deployment" -ForegroundColor Cyan
                Write-Host "============================================" -ForegroundColor Cyan
                Write-Host " This will remove:" -ForegroundColor Gray
                Write-Host "   - Frontend service and files" -ForegroundColor Gray
                Write-Host "   - Backend service and files" -ForegroundColor Gray
                Write-Host "   - MO Report Worker service and files" -ForegroundColor Gray
                Write-Host "   - Caddy service and files" -ForegroundColor Gray
                Write-Host "   - Logs" -ForegroundColor Gray
                Write-Host "   - deployment-state.json" -ForegroundColor Gray
                Write-Host "   - $($Config.InstallRoot)" -ForegroundColor Gray
                Write-Host ""
                $confirm=Read-Host "Type YES to uninstall the complete deployment"
                if($confirm -ne 'YES'){Write-Warn "Uninstall cancelled.";break}

                Initialize-Logger -Config $Config
                foreach($c in @($compList | Sort-Object Num -Descending)){Remove-Component -Key $c.Key -Config $Config -DeleteFiles}

                if(-not(Test-AppInstallRoot -Config $Config)){Write-Warn "InstallRoot does not look like an ESS app folder. Skipping root-folder deletion: $($Config.InstallRoot)";break}
                $statePath=Get-DeploymentStatePath -Config $Config
                if(Test-Path $statePath){Remove-Item $statePath -Force -ErrorAction SilentlyContinue;Write-Success "Deleted deployment-state.json"}
                $logsPath=Join-Path $Config.InstallRoot 'logs'
                if(Test-Path $logsPath){Remove-Item $logsPath -Recurse -Force -ErrorAction SilentlyContinue;Write-Success "Deleted logs/ folder"}
                if(Test-Path $Config.InstallRoot){
                    try{Remove-Item $Config.InstallRoot -Recurse -Force -ErrorAction Stop;Write-Success "Deleted app folder: $($Config.InstallRoot)"}
                    catch{Write-Err "Could not fully delete app folder: $($Config.InstallRoot)"}
                }
                Write-Success "Complete deployment uninstalled."
            }
            '^4$' {
                Initialize-Logger -Config $Config
                Show-Status -Config $Config
            }
            '^5$' {
                Initialize-Logger -Config $Config
                Write-Host ""
                Write-Host " A) Start all services" -ForegroundColor White
                foreach($c in Get-ServiceComponents -Config $Config){
                    $svc=Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                    if($svc -and $svc.Status -eq 'Running'){Write-Host " $($c.Num)) $($c.Display)  [ALREADY RUNNING]" -ForegroundColor Green}
                    elseif($svc){Write-Host " $($c.Num)) $($c.Display)  [STOPPED]" -ForegroundColor DarkYellow}
                    else{Write-Host " $($c.Num)) $($c.Display)  [NOT INSTALLED]" -ForegroundColor DarkGray}
                }
                Write-Host " B) Back" -ForegroundColor Gray
                $sub=Read-Host "`nSelect to start"
                if($sub -match '^[Aa]$'){Start-AllServices -Config $Config}
                elseif($sub -match '^\d+$'){
                    $c=Get-ServiceComponents -Config $Config|Where-Object{"$($_.Num)" -eq $sub}|Select-Object -First 1
                    if($c){
                        $svc=Get-Service $c.Service -ErrorAction SilentlyContinue
                        if(-not $svc){Write-Warn "$($c.Display) is not installed."}
                        elseif($svc.Status -eq 'Running'){Write-Warn "$($c.Display) is already running."}
                        else{Start-Service $c.Service -ErrorAction Stop;Write-Success "Started $($c.Display)"}
                    }
                }
            }
            '^6$' {
                Initialize-Logger -Config $Config
                Write-Host ""
                Write-Host " A) Stop all services" -ForegroundColor White
                foreach($c in Get-ServiceComponents -Config $Config){
                    $svc=Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                    if($svc -and $svc.Status -eq 'Running'){Write-Host " $($c.Num)) $($c.Display)  [RUNNING]" -ForegroundColor Green}
                    elseif($svc){Write-Host " $($c.Num)) $($c.Display)  [STOPPED]" -ForegroundColor DarkYellow}
                    else{Write-Host " $($c.Num)) $($c.Display)  [NOT INSTALLED]" -ForegroundColor DarkGray}
                }
                Write-Host " B) Back" -ForegroundColor Gray
                $sub=Read-Host "`nSelect to stop"
                if($sub -match '^[Aa]$'){Stop-AllServices -Config $Config}
                elseif($sub -match '^\d+$'){
                    $c=Get-ServiceComponents -Config $Config|Where-Object{"$($_.Num)" -eq $sub}|Select-Object -First 1
                    if($c){
                        $svc=Get-Service $c.Service -ErrorAction SilentlyContinue
                        if(-not $svc){Write-Warn "$($c.Display) is not installed."}
                        elseif($svc.Status -ne 'Running'){Write-Warn "$($c.Display) is already stopped."}
                        else{Stop-Service $c.Service -ErrorAction Stop;Write-Success "Stopped $($c.Display)"}
                    }
                }
            }
            '^7$' {
                Initialize-Logger -Config $Config
                Show-CaddyConfig -Config $Config
            }
            '^8$' {
                $logsPath=Join-Path $Config.InstallRoot 'logs'
                if(Test-Path $logsPath){Invoke-Item $logsPath}else{Write-Warn "No logs folder yet."}
            }
            '^9$' {
                if(Test-DeploymentRollbackAvailable -Config $Config){
                    Initialize-Logger -Config $Config
                    Show-RollbackMenu -Config $Config
                }else{Write-Warn "No previous successful deployment is available yet."}
            }
            '^[Qq]$' { Write-Host "`nBye." -ForegroundColor Cyan }
            default { Write-Warn "Unknown option." }
        }

        if($choice -notmatch '^[Qq]$'){Read-Host "`nPress Enter to continue"|Out-Null}
        $Config=Get-DeployConfig
    } while($choice -notmatch '^[Qq]$')
}
catch {
    Write-Host "`nFATAL: $($_.Exception.Message)" -ForegroundColor Red
    if($script:logFile){Write-Log "FATAL: $_" -Level "FATAL"}
    exit 1
}
