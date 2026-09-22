# ===========================================================
# ESS MO Full-Stack Deployment Manager
# FACE-ESS style versioned deployment architecture
#
# Components are independent deployment units:
#   frontend       -> <InstallRoot>\frontend\repo
#   backend        -> <InstallRoot>\backend\repo
#   report-worker  -> <InstallRoot>\report-worker\repo
#   caddy          -> <InstallRoot>\caddy
#
# Backend and report-worker may use the same remote repository, but each
# keeps its own local Git checkout, Python virtual environment, runner,
# logs, Windows service and rollback state.
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
$script:spinnerPS = $null
$script:spinnerAsync = $null

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
    if($null -eq $script:spinnerPS){Write-Host "$_"}
    if ($null -ne $_ -and "$_" -ne '') { Write-FileLog -Path $Path -Text "$_" }
}

function Write-Step    ($msg) { Write-Host "`n[*] $msg" -ForegroundColor Yellow; Write-Log "STEP: $msg" }
function Write-Success ($msg) { Write-Host "    $msg" -ForegroundColor Green; Write-Log "OK: $msg" }
function Write-Err     ($msg) { Write-Host "    $msg" -ForegroundColor Red; Write-Log "ERROR: $msg" -Level "ERROR"; $script:hasErrors = $true }
function Write-Warn    ($msg) { Write-Host "    $msg" -ForegroundColor DarkYellow; Write-Log "WARN: $msg" -Level "WARN" }

function Start-Spinner {
    param([string]$Message)
    if($script:headless -or $script:dryRun -or [Console]::IsOutputRedirected){return}
    Stop-Spinner
    $script:spinnerPS=[PowerShell]::Create()
    $null=$script:spinnerPS.AddScript({
        param($Text)
        $frames=@('|','/','-','\')
        $index=0
        try{
            while($true){
                [Console]::Write("`r    $($frames[$index % $frames.Count]) $Text")
                Start-Sleep -Milliseconds 150
                $index++
            }
        }catch{}
    }).AddArgument($Message)
    $script:spinnerAsync=$script:spinnerPS.BeginInvoke()
}

function Stop-Spinner {
    if($null -eq $script:spinnerPS){return}
    try{$script:spinnerPS.Stop()}catch{}
    try{$script:spinnerPS.Dispose()}catch{}
    [Console]::Write("`r"+(" "*90)+"`r")
    $script:spinnerPS=$null
    $script:spinnerAsync=$null
}

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
            $workerRepo=Join-Path $base "repo\.git"
            $workerPython=Join-Path $base "repo\venv\Scripts\python.exe"
            return [bool]($svc -and (Test-Path $workerRepo) -and (Test-Path $workerPython))
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
# Independent local repositories and virtual environments.
# Both may point to the same BackendRepo remote, but updates/rollback are
# isolated per Windows service.
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

function Initialize-BackendRuntime {
    param($Config,$Secrets,[string]$LogPath)
    $appDir=Join-Path $Config.InstallRoot "backend"
    $repoDir=Join-Path $appDir "repo"
    $venv=Join-Path $repoDir "venv"
    $svcName=Get-DeployServiceName $Config "backend"

    $python=New-StackVenv -Path $venv -LogPath $LogPath
    Install-StackRequirements -Config $Config -Python $python -Requirements (Join-Path $repoDir "requirements.txt") -LogPath $LogPath -Label "Backend"
    Write-MoEnvFile -Config $Config -Secrets $Secrets -RepoDir $repoDir

    Push-Location $repoDir
    try{
        $check=& $python -X faulthandler -c "import app.main; print('APP_OK')" 2>&1
        if($LASTEXITCODE -ne 0 -or ($check -join ' ') -notmatch 'APP_OK'){throw "Backend import failed: $check"}
    }finally{Pop-Location}

    $runner=Join-Path $appDir "backend-run.ps1"
    $runnerContent=@'
$ErrorActionPreference="Continue"
$ProgressPreference="SilentlyContinue"
$env:PYTHONUNBUFFERED="1"
$env:PYTHONFAULTHANDLER="1"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$repo=Join-Path $root "repo"
$python=Join-Path $repo "venv\Scripts\python.exe"
$logs=Join-Path (Split-Path $root -Parent) "logs\backend"
New-Item $logs -ItemType Directory -Force|Out-Null
$ts=Get-Date -Format "yyyyMMdd-HHmmss"
$out=Join-Path $logs "backend_stdout_$ts.log"
$err=Join-Path $logs "backend_stderr_$ts.log"
Set-Location $repo
$p=Start-Process -FilePath $python -ArgumentList @("-X","faulthandler","-u","-m","uvicorn","app.main:app","--host","0.0.0.0","--port","__PORT__","--no-use-colors") -WorkingDirectory $repo -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait -PassThru
exit $p.ExitCode
'@
    $runnerContent=$runnerContent.Replace('__PORT__',"$($Config.BackendPort)")
    Set-Content $runner $runnerContent -Encoding UTF8 -Force
    Install-OrKeepService -ServiceName $svcName -RunnerScript $runner -LogPath $LogPath
    Stop-ServiceIfRunning $svcName
    Start-Service $svcName -ErrorAction Stop
    if(-not(Test-Endpoint -Url "http://127.0.0.1:$($Config.BackendPort)$($Config.ApiPrefix)/health" -Name "Backend API")){throw "Backend health failed."}
}

function Initialize-ReportWorkerRuntime {
    param($Config,$Secrets,[string]$LogPath)
    $appDir=Join-Path $Config.InstallRoot "report-worker"
    $repoDir=Join-Path $appDir "repo"
    $venv=Join-Path $repoDir "venv"
    $svcName=Get-DeployServiceName $Config "report-worker"

    $python=New-StackVenv -Path $venv -LogPath $LogPath
    Install-StackRequirements -Config $Config -Python $python -Requirements (Get-WorkerRequirementsPath $repoDir) -LogPath $LogPath -Label "Report worker"
    Write-MoEnvFile -Config $Config -Secrets $Secrets -RepoDir $repoDir

    Push-Location $repoDir
    try{
        $check=& $python -X faulthandler -c "import app.workers.mo_report_export_worker; print('WORKER_OK')" 2>&1
        if($LASTEXITCODE -ne 0 -or ($check -join ' ') -notmatch 'WORKER_OK'){throw "Worker import failed: $check"}
    }finally{Pop-Location}

    $runner=Join-Path $appDir "mo-report-worker-run.ps1"
    $runnerContent=@'
$ErrorActionPreference="Continue"
$ProgressPreference="SilentlyContinue"
$env:PYTHONUNBUFFERED="1"
$env:PYTHONFAULTHANDLER="1"
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$repo=Join-Path $root "repo"
$python=Join-Path $repo "venv\Scripts\python.exe"
$logs=Join-Path (Split-Path $root -Parent) "logs\report-worker"
New-Item $logs -ItemType Directory -Force|Out-Null
$ts=Get-Date -Format "yyyyMMdd-HHmmss"
$out=Join-Path $logs "worker_stdout_$ts.log"
$err=Join-Path $logs "worker_stderr_$ts.log"
Set-Location $repo
$p=Start-Process -FilePath $python -ArgumentList @("-X","faulthandler","-u","-m","app.workers.mo_report_export_worker") -WorkingDirectory $repo -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait -PassThru
exit $p.ExitCode
'@
    Set-Content $runner $runnerContent -Encoding UTF8 -Force
    Install-OrKeepService -ServiceName $svcName -RunnerScript $runner -LogPath $LogPath
    Stop-ServiceIfRunning $svcName
    Start-Service $svcName -ErrorAction Stop
    Start-Sleep -Seconds 2
    $status=Get-Service $svcName -ErrorAction SilentlyContinue
    if(-not $status -or $status.Status -ne 'Running'){throw "Report worker service did not remain running."}
    Write-Success "MO report worker: running from independent worker repository"
}

function Test-PythonCandidate {
    param($Config,[string]$RepoDir,[string]$Component,[string]$LogPath)
    $candidateVenv=Join-Path $RepoDir ".candidate-venv"
    $python=New-StackVenv -Path $candidateVenv -LogPath $LogPath
    try{
        if($Component -eq "backend"){
            Install-StackRequirements $Config $python (Join-Path $RepoDir "requirements.txt") $LogPath "Backend candidate"
            Push-Location $RepoDir
            try{$check=& $python -X faulthandler -c "import app.main; print('APP_OK')" 2>&1;if($LASTEXITCODE -ne 0 -or ($check -join ' ') -notmatch 'APP_OK'){throw "Backend candidate import failed: $check"}}finally{Pop-Location}
        }else{
            Install-StackRequirements $Config $python (Get-WorkerRequirementsPath $RepoDir) $LogPath "Worker candidate"
            Push-Location $RepoDir
            try{$check=& $python -X faulthandler -c "import app.workers.mo_report_export_worker; print('WORKER_OK')" 2>&1;if($LASTEXITCODE -ne 0 -or ($check -join ' ') -notmatch 'WORKER_OK'){throw "Worker candidate import failed: $check"}}finally{Pop-Location}
        }
    }finally{
        if(Test-Path $candidateVenv){Remove-Item $candidateVenv -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

function Install-PythonComponent {
    param($Config,$Secrets,[ValidateSet("backend","report-worker")][string]$Component)
    Initialize-InstallRoot -Config $Config
    $appDir=Join-Path $Config.InstallRoot $Component
    $repoDir=Join-Path $appDir "repo"
    $logsDir=Join-Path $Config.InstallRoot ("logs\"+$Component)
    New-Item $logsDir -ItemType Directory -Force|Out-Null
    $log=Join-Path $logsDir ("{0}_{1}.log" -f $Component,(Get-Date -Format "yyyyMMdd-HHmmss"))
    $svcName=Get-DeployServiceName $Config $Component
    $oldGood=Get-DeploymentComponentCurrent $Config $Component
    if([string]::IsNullOrWhiteSpace($oldGood)){$oldGood=Get-GitHead $repoDir}
    $wasInstalled=Test-ComponentInstalled $Config $Component
    $liveChanged=$false
    $label=if($Component -eq "backend"){"Backend API"}else{"MO Report Worker"}
    Write-Step ($(if($wasInstalled){"Updating $label"}else{"Installing $label"}))
    if($script:dryRun){return $true}

    try{
        New-Item $appDir -ItemType Directory -Force|Out-Null
        if(Test-Path (Join-Path $repoDir ".git")){
            $remote=Get-RemoteHead -RepoDir $repoDir -Branch $Config.BackendBranch -LogPath $log
            $local=Get-GitHead $repoDir
            if($wasInstalled -and $local -eq $remote){
                $svc=Get-Service $svcName -ErrorAction SilentlyContinue
                if($svc -and $svc.Status -ne 'Running'){Start-Service $svcName -ErrorAction Stop}
                Register-SuccessfulComponentDeployment $Config $Component $local
                Write-Success "$label already current: $local"
                return $true
            }

            if($wasInstalled){
                $candidateDir=Join-Path $appDir "_candidate"
                & git -C $repoDir worktree remove --force $candidateDir 2>$null|Out-Null
                Remove-Item $candidateDir -Recurse -Force -ErrorAction SilentlyContinue
                & git -C $repoDir worktree prune 2>$null|Out-Null
                try{
                    git -C $repoDir worktree add --detach $candidateDir $remote 2>&1|Add-FileLog -Path $log
                    if($LASTEXITCODE -ne 0){throw "Could not create $Component candidate worktree."}
                    Test-PythonCandidate -Config $Config -RepoDir $candidateDir -Component $Component -LogPath $log
                }finally{
                    & git -C $repoDir worktree remove --force $candidateDir 2>$null|Out-Null
                    Remove-Item $candidateDir -Recurse -Force -ErrorAction SilentlyContinue
                    & git -C $repoDir worktree prune 2>$null|Out-Null
                }
            }

            Stop-ServiceIfRunning $svcName
            $liveChanged=$true;$script:liveComponentsChanged += $Component
            git -C $repoDir reset --hard "origin/$($Config.BackendBranch)" 2>&1|Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){throw "$label git reset failed."}
            git -C $repoDir clean -fd 2>&1|Add-FileLog -Path $log
        }else{
            Stop-ServiceIfRunning $svcName
            if(Test-Path $repoDir){Remove-Item $repoDir -Recurse -Force}
            git clone --branch $Config.BackendBranch $Config.BackendRepo $repoDir 2>&1|Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){throw "$label clone failed."}
            $liveChanged=$true;$script:liveComponentsChanged += $Component
        }

        if($Component -eq "backend"){Initialize-BackendRuntime -Config $Config -Secrets $Secrets -LogPath $log}
        else{Initialize-ReportWorkerRuntime -Config $Config -Secrets $Secrets -LogPath $log}
        $candidate=Get-GitHead $repoDir
        Register-SuccessfulComponentDeployment $Config $Component $candidate
        return $true
    }catch{
        Write-Err "$label setup failed: $_"
        if($liveChanged -and -not[string]::IsNullOrWhiteSpace($oldGood) -and (Test-Path (Join-Path $repoDir ".git")) -and (Ensure-GitCommitAvailable $repoDir $oldGood)){
            Write-Warn "Restoring $label known-good commit: $oldGood"
            try{
                Stop-ServiceIfRunning $svcName
                git -C $repoDir reset --hard $oldGood|Out-Null
                if($Component -eq "backend"){Initialize-BackendRuntime -Config $Config -Secrets $Secrets -LogPath $log}
                else{Initialize-ReportWorkerRuntime -Config $Config -Secrets $Secrets -LogPath $log}
            }catch{Write-Err "Automatic $label restore failed: $_"}
        }elseif(-not $wasInstalled){
            $svc=Get-Service $svcName -ErrorAction SilentlyContinue
            if($svc){Stop-ServiceIfRunning $svcName;servy-cli uninstall --name="$svcName" --quiet|Out-Null}
        }
        return $false
    }
}

function Install-Backend { param($Config,$Secrets); return (Install-PythonComponent -Config $Config -Secrets $Secrets -Component "backend") }
function Install-ReportWorker { param($Config,$Secrets); return (Install-PythonComponent -Config $Config -Secrets $Secrets -Component "report-worker") }

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
    Write-Host "    Proxy port : $($Config.CaddyPort)" -ForegroundColor Green
    Write-Host "    Admin port : $($Config.CaddyAdminPort)" -ForegroundColor Gray
    Write-Host "    Install log: $log" -ForegroundColor Gray
    if($script:dryRun){return $true}
    try{
        New-Item $dir -ItemType Directory -Force|Out-Null
        $exe=Join-Path $dir "caddy.exe"
        if(Test-Path $exe){
            Write-Host "    Checking existing Caddy executable..." -ForegroundColor Gray
            & $exe version 2>&1|Add-FileLog -Path $log
            if($LASTEXITCODE -ne 0){
                Write-Warn "Existing caddy.exe is invalid and will be downloaded again."
                Remove-Item $exe -Force -ErrorAction Stop
            }
        }
        if(-not(Test-Path $exe)){
            $zip=Join-Path $dir "caddy.zip"
            $extractDir=Join-Path $dir "_caddy_extract"
            $version="$($Config.CaddyVersion)".Trim().TrimStart('v')
            $expectedHash="$($Config.CaddyWindowsAmd64Sha256)".Trim().ToLowerInvariant()
            if($version -notmatch '^\d+\.\d+\.\d+$'){throw "Invalid CaddyVersion '$version'."}
            if($expectedHash -notmatch '^[a-f0-9]{64}$'){throw "Invalid Caddy Windows SHA256 checksum."}
            $downloadUrl="https://github.com/caddyserver/caddy/releases/download/v$version/caddy_${version}_windows_amd64.zip"
            $downloaded=$false
            $releaseDownloadError=$null

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
                    $releaseDownloadError=$_.Exception.Message
                    Remove-Item $exe -Force -ErrorAction SilentlyContinue
                    if($attempt -lt 3){
                        Write-Warn "Caddy release download attempt $attempt failed: $releaseDownloadError. Retrying..."
                        Start-Sleep -Seconds (2*$attempt)
                    }
                }finally{
                    Remove-Item $zip -Force -ErrorAction SilentlyContinue
                    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            # The official Caddy download API returns a Windows executable,
            # not a ZIP archive. Use it directly if the verified release ZIP
            # is unavailable through the current network/proxy.
            if(-not $downloaded){
                Write-Warn "Verified Caddy release archive was unavailable: $releaseDownloadError"
                Write-Host "    Trying official Caddy direct download..." -ForegroundColor Gray
                [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
                $directUrl="https://caddyserver.com/api/download?os=windows&arch=amd64"
                $directExe=Join-Path $dir "caddy.download.exe"
                $directDownloadError=$null
                for($attempt=1;$attempt -le 3;$attempt++){
                    Remove-Item $directExe -Force -ErrorAction SilentlyContinue
                    try{
                        Invoke-WebRequest -Uri $directUrl -OutFile $directExe -UseBasicParsing -ErrorAction Stop
                        $exeInfo=Get-Item $directExe -ErrorAction Stop
                        if($exeInfo.Length -lt 1MB){throw "Downloaded executable is unexpectedly small ($($exeInfo.Length) bytes)."}
                        $stream=[System.IO.File]::OpenRead($directExe)
                        try{$byte1=$stream.ReadByte();$byte2=$stream.ReadByte()}finally{$stream.Dispose()}
                        if($byte1 -ne 0x4D -or $byte2 -ne 0x5A){throw "Downloaded file is not a Windows executable."}
                        $directHash=(Get-FileHash -Path $directExe -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                        Write-FileLog -Path $log -Text "Official Caddy direct-download SHA256: $directHash"
                        Move-Item $directExe $exe -Force
                        & $exe version 2>&1|Add-FileLog -Path $log
                        if($LASTEXITCODE -ne 0){throw "Directly downloaded caddy.exe could not start."}
                        $downloaded=$true
                        break
                    }catch{
                        $directDownloadError=$_.Exception.Message
                        Remove-Item $exe -Force -ErrorAction SilentlyContinue
                        if($attempt -lt 3){
                            Write-Warn "Caddy direct download attempt $attempt failed: $directDownloadError. Retrying..."
                            Start-Sleep -Seconds (2*$attempt)
                        }
                    }finally{Remove-Item $directExe -Force -ErrorAction SilentlyContinue}
                }
                if(-not $downloaded){throw "Caddy download failed. Release archive: $releaseDownloadError. Direct download: $directDownloadError"}
            }
            if(-not $downloaded -or -not(Test-Path $exe)){throw "caddy.exe download failed."}
        }

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
        $lines.Add("    header {")
        $lines.Add('        X-Frame-Options "SAMEORIGIN"')
        $lines.Add('        X-Content-Type-Options "nosniff"')
        $lines.Add('        Referrer-Policy "strict-origin-when-cross-origin"')
        $lines.Add("    }")
        $lines.Add("}")
        Set-Content $caddyfile ($lines -join [Environment]::NewLine) -Encoding UTF8 -Force
        $runner=Join-Path $dir "caddy-run.ps1"
        $runnerContent=@'
$ErrorActionPreference="Stop"
$dir=Split-Path -Parent $MyInvocation.MyCommand.Path
$exe=Join-Path $dir "caddy.exe"
$cfg=Join-Path $dir "Caddyfile"
$ports=Join-Path $dir "caddy-ports.json"
$logs=Join-Path (Join-Path (Split-Path $dir -Parent) "logs") "caddy"
if(-not(Test-Path $logs)){New-Item $logs -ItemType Directory -Force|Out-Null}
$runtimeLog=Join-Path $logs ("caddy_service_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Remove-Item $ports -Force -ErrorAction SilentlyContinue
try{
    Set-Location $dir
    "========== Caddy service started at $(Get-Date) =========="|Out-File $runtimeLog -Encoding UTF8
    "Executable: $exe"|Out-File $runtimeLog -Append -Encoding UTF8
    "Config: $cfg"|Out-File $runtimeLog -Append -Encoding UTF8
    "Proxy port: __PROXY__; Admin port: __ADMIN__"|Out-File $runtimeLog -Append -Encoding UTF8
    @{proxy=__PROXY__;admin=__ADMIN__}|ConvertTo-Json|Set-Content $ports -Encoding UTF8 -Force
    & $exe run --config $cfg --adapter caddyfile 2>&1|ForEach-Object{"$_"|Out-File $runtimeLog -Append -Encoding UTF8}
    exit $LASTEXITCODE
}catch{
    "FATAL: $($_.Exception.Message)"|Out-File $runtimeLog -Append -Encoding UTF8
    exit 1
}
'@
        $runnerContent=$runnerContent.Replace('__PROXY__',"$($Config.CaddyPort)").Replace('__ADMIN__',"$($Config.CaddyAdminPort)")
        Set-Content $runner $runnerContent -Encoding UTF8 -Force

        Write-Host "    Validating Caddyfile..." -ForegroundColor Gray
        Write-FileLog -Path $log -Text "--- Caddyfile validation ---"
        $validationOutput=@(& $exe validate --config $caddyfile --adapter caddyfile 2>&1)
        $validationExit=$LASTEXITCODE
        foreach($line in $validationOutput){Write-FileLog -Path $log -Text "$line"}
        if($validationExit -ne 0){throw "Caddyfile validation failed: $(($validationOutput|Select-Object -Last 10)-join ' | ')"}
        Write-Success "Caddyfile validation passed"

        Initialize-CaddyLocalGit $Config
        $candidate=Commit-CaddyLocalVersion -Config $Config -Message "Caddy config $(Get-Date -Format s)"
        if([string]::IsNullOrWhiteSpace($candidate)){throw "Could not save the Caddy configuration version."}

        # Validate the candidate before interrupting the active proxy. Port
        # availability is checked only after our existing service is stopped.
        Stop-ServiceIfRunning $svcName
        foreach($p in @($Config.CaddyPort,$Config.CaddyAdminPort)){
            if(Test-PortInUse ([int]$p)){throw "Caddy port $p is already in use by another process."}
        }
        $script:liveComponentsChanged += "caddy"
        Install-OrKeepService $svcName $runner $log
        Stop-ServiceIfRunning $svcName;Start-Service $svcName -ErrorAction Stop
        $portsFile=Join-Path $dir "caddy-ports.json"
        $pollAttempts=0
        while($pollAttempts -lt 5 -and -not(Test-Path $portsFile)){Start-Sleep -Seconds 2;$pollAttempts++}
        if(Test-Path $portsFile){
            try{
                $portsData=Get-Content $portsFile -Raw -ErrorAction Stop|ConvertFrom-Json
                if([int]$portsData.proxy -ne [int]$Config.CaddyPort -or [int]$portsData.admin -ne [int]$Config.CaddyAdminPort){throw "Caddy reported unexpected ports: proxy=$($portsData.proxy), admin=$($portsData.admin)"}
                Write-FileLog -Path $log -Text "caddy-ports.json verified: proxy=$($portsData.proxy), admin=$($portsData.admin)"
            }catch{throw "Could not verify fixed Caddy ports from ${portsFile}: $_"}
        }else{throw "Caddy did not create caddy-ports.json after startup."}
        if(-not(Test-Endpoint -Url "http://127.0.0.1:$($Config.CaddyPort)$($Config.ApiPrefix)/health" -Name "Caddy proxy")){throw "Caddy proxy health failed."}
        $runningService=Get-Service $svcName -ErrorAction SilentlyContinue
        if(-not $runningService -or $runningService.Status -ne 'Running'){throw "Caddy service is not running after the health check."}
        if(-not(Test-PortInUse ([int]$Config.CaddyPort))){throw "Caddy proxy port $($Config.CaddyPort) is not listening."}
        if(-not(Test-PortInUse ([int]$Config.CaddyAdminPort))){throw "Caddy admin port $($Config.CaddyAdminPort) is not listening."}
        Write-Success "Caddy is running: proxy=$($Config.CaddyPort), admin=$($Config.CaddyAdminPort)"
        Register-SuccessfulComponentDeployment $Config "caddy" $candidate
        return $true
    }catch{
        $caddyError=$_
        Write-Err "Caddy setup failed: $caddyError"
        $latestErrLog=Get-ChildItem -Path $logs -Filter "caddy_service_*.log" -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1
        if($latestErrLog){
            Write-FileLog -Path $log -Text "--- Last 20 lines of runtime log ($($latestErrLog.Name)) ---"
            Get-Content $latestErrLog.FullName -ErrorAction SilentlyContinue|Select-Object -Last 20|ForEach-Object{Write-FileLog -Path $log -Text "$_"}
            Write-FileLog -Path $log -Text "--- end runtime log ---"
        }
        if(-not[string]::IsNullOrWhiteSpace($oldGood) -and (Test-Path (Join-Path $dir ".git")) -and (Ensure-GitCommitAvailable $dir $oldGood)){
            Write-Warn "Restoring Caddy known-good commit: $oldGood"
            Stop-ServiceIfRunning $svcName
            git -C $dir reset --hard $oldGood|Out-Null
            Start-Service $svcName -ErrorAction SilentlyContinue
            if(Test-Endpoint -Url "http://127.0.0.1:$($Config.CaddyPort)$($Config.ApiPrefix)/health" -Name "Restored Caddy proxy" -Retries 5){
                Write-Success "Caddy restored to known-good commit: $oldGood"
            }else{
                Write-Err "Restored Caddy did not pass its health check."
            }
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
    param($Config,$Secrets,[ValidateSet("backend","report-worker")][string]$Component,[string]$Commit)
    $appDir=Join-Path $Config.InstallRoot $Component
    $repoDir=Join-Path $appDir "repo"
    $svc=Get-DeployServiceName $Config $Component
    $logs=Join-Path $Config.InstallRoot ("logs\"+$Component)
    New-Item $logs -ItemType Directory -Force|Out-Null
    $log=Join-Path $logs ("rollback_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $label=if($Component -eq "backend"){"Backend API"}else{"MO Report Worker"}
    try{
        if(-not(Ensure-GitCommitAvailable $repoDir $Commit)){throw "Commit unavailable: $Commit"}
        Stop-ServiceIfRunning $svc
        git -C $repoDir reset --hard $Commit 2>&1|Add-FileLog -Path $log
        if($LASTEXITCODE -ne 0){throw "$label Git rollback failed."}
        if($Component -eq "backend"){Initialize-BackendRuntime -Config $Config -Secrets $Secrets -LogPath $log}
        else{Initialize-ReportWorkerRuntime -Config $Config -Secrets $Secrets -LogPath $log}
        return $true
    }catch{Write-Err "$label rollback failed: $_";return $false}
}

function Invoke-CaddyRollbackToCommit {
    param($Config,[string]$Commit)
    $dir=Join-Path $Config.InstallRoot "caddy";$svc=Get-DeployServiceName $Config "caddy"
    $currentCommit=Get-GitHead $dir
    try{
        if(-not(Ensure-GitCommitAvailable $dir $Commit)){throw "Commit unavailable: $Commit"}
        Stop-ServiceIfRunning $svc
        git -C $dir reset --hard $Commit|Out-Null
        if($LASTEXITCODE -ne 0){throw "Caddy Git rollback failed."}

        $exe=Join-Path $dir "caddy.exe";$caddyfile=Join-Path $dir "Caddyfile"
        $validationOutput=@(& $exe validate --config $caddyfile --adapter caddyfile 2>&1)
        if($LASTEXITCODE -ne 0){throw "Rolled-back Caddyfile is invalid: $(($validationOutput|Select-Object -Last 10)-join ' | ')"}

        Start-Service $svc -ErrorAction Stop
        if(-not(Test-Endpoint -Url "http://127.0.0.1:$($Config.CaddyPort)$($Config.ApiPrefix)/health" -Name "Caddy rollback")){throw "Rolled-back Caddy proxy did not pass its health check."}
        if(-not(Test-PortInUse ([int]$Config.CaddyAdminPort))){throw "Rolled-back Caddy admin port is not listening."}
        return $true
    }catch{
        Write-Err "Caddy rollback failed: $_"
        if(-not[string]::IsNullOrWhiteSpace($currentCommit)){
            Write-Warn "Restoring Caddy version active before the rollback attempt: $currentCommit"
            Stop-ServiceIfRunning $svc
            git -C $dir reset --hard $currentCommit|Out-Null
            Start-Service $svc -ErrorAction SilentlyContinue
        }
        return $false
    }
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
    $versionCount=if($state -and $state.deploymentVersions){@($state.deploymentVersions).Count}else{0}
    if($versionCount -lt 2){
        Write-Host "`n============================================" -ForegroundColor Cyan
        Write-Host " Rollback Complete Deployment" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        if($versionCount -eq 1){
            $onlyVersion=@($state.deploymentVersions)[0]
            Write-Host " Saved deployment : $($onlyVersion.versionName)" -ForegroundColor Green
            Write-Warn "A previous deployment version has not been saved yet."
            Write-Host " Complete an update with at least one changed component to create the rollback version." -ForegroundColor Gray
        }else{Write-Warn "No successful deployment version has been saved yet."}
        Write-Host " State file: $(Get-DeploymentStatePath -Config $Config)" -ForegroundColor DarkGray
        return
    }

    $versions=@($state.deploymentVersions);$current=$versions[0];$target=$versions[1]
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host " Rollback Complete Deployment" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Saved versions: 2 (current + previous)" -ForegroundColor Gray
    Write-Host " Current deployment : $($current.versionName)" -ForegroundColor Green
    Write-Host " Rollback target    : $($target.versionName)" -ForegroundColor Yellow
    Write-Host ""
    foreach($k in (Get-ComponentKeys)){
        $currentCommit="$($current.components.$k.current)".Trim();$targetCommit="$($target.components.$k.current)".Trim()
        if([string]::IsNullOrWhiteSpace($currentCommit)){$currentCommit="<not recorded>"}
        if([string]::IsNullOrWhiteSpace($targetCommit)){$targetCommit="<not recorded>"}
        Write-Host " $k" -ForegroundColor White
        Write-Host "   $($current.versionName) current  : $currentCommit" -ForegroundColor Green
        Write-Host "   $($target.versionName) rollback : $targetCommit" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host " State file: $(Get-DeploymentStatePath -Config $Config)" -ForegroundColor DarkGray
    if(-not(Confirm-Step "Rollback $($current.versionName) -> $($target.versionName)?" -DefaultYes:$false)){return}

    $secrets=Get-SecretsOrInitialize;if(-not $secrets){return}
    $restored=@();$ok=$true
    foreach($k in @("caddy","report-worker","backend","frontend")){
        $commit="$($target.components.$k.current)".Trim()
        if([string]::IsNullOrWhiteSpace($commit)){continue}
        if(Invoke-SelectedRollback $Config $secrets $k $commit){$restored += $k}else{$ok=$false;break}
    }

    if(-not $ok){
        Write-Warn "Rollback did not complete. Restoring the original current deployment where possible..."
        foreach($k in @("caddy","report-worker","backend","frontend")){
            if($restored -notcontains $k){continue}
            $commit="$($current.components.$k.current)".Trim()
            if(-not[string]::IsNullOrWhiteSpace($commit)){Invoke-SelectedRollback $Config $secrets $k $commit|Out-Null}
        }
        Write-Err "Complete deployment rollback failed. deployment-state.json was not changed."
        return
    }

    $state.deploymentVersions=@($target,$current)
    Save-DeploymentState $Config $state
    Write-Success "Rollback complete. Current: $($target.versionName)"
}

function Restore-DeploymentStateBeforeRun {
    param($Config,$Secrets)
    if(-not $script:deploymentStateBeforeRun){Write-Warn "No previous deployment state to restore.";return $false}
    $v=@($script:deploymentStateBeforeRun.deploymentVersions)[0];if(-not $v){return $false}
    Write-Step "RESTORING previous known-good deployment"
    $ok=$true
    foreach($k in @("caddy","report-worker","backend","frontend")){
        $commit="$($v.components.$k.current)".Trim()
        if([string]::IsNullOrWhiteSpace($commit)){continue}
        if(-not(Invoke-SelectedRollback $Config $Secrets $k $commit)){$ok=$false;break}
    }
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
    $secrets=$null
    if(($targets -contains "backend") -or ($targets -contains "report-worker")){
        $secrets=Get-SecretsOrInitialize;if(-not $secrets){$script:deploymentTransaction=$false;return}
        if(-not(Confirm-DeploymentCredentials $secrets)){$script:deploymentTransaction=$false;return}
    }
    $ok=$true
    foreach($k in @("frontend","backend","report-worker","caddy")){
        if($targets -notcontains $k){continue}
        $spinnerLabel=switch($k){"frontend"{"Frontend deployment"};"backend"{"Backend deployment"};"report-worker"{"Report worker deployment"};"caddy"{"Caddy deployment"}}
        Start-Spinner "$spinnerLabel ..."
        try{
            switch($k){"frontend"{$r=Install-Frontend $Config};"backend"{$r=Install-Backend $Config $secrets};"report-worker"{$r=Install-ReportWorker $Config $secrets};"caddy"{$r=Install-Caddy $Config}}
        }finally{Stop-Spinner}
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
    $rollbackState = Get-DeploymentState -Config $Config
    $rollbackVersions = if ($rollbackState -and $rollbackState.deploymentVersions) { @($rollbackState.deploymentVersions) } else { @() }
    if ($rollbackVersions.Count -ge 2) {
        Write-Host "  9) Rollback deployment ($($rollbackVersions[0].versionName) -> $($rollbackVersions[1].versionName))" -ForegroundColor White
    } else {
        Write-Host "  9) Rollback deployment [requires two successful versions]" -ForegroundColor DarkGray
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
                Initialize-Logger -Config $Config
                Show-RollbackMenu -Config $Config
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
