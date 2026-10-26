#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Touch-free Tailscale MSI installer for Windows.

.DESCRIPTION
    - Checks if Tailscale is already installed (skips if already current)
    - Detects CPU architecture (amd64 / arm64 / x86)
    - Fetches the latest version from pkgs.tailscale.com
    - Downloads the appropriate MSI
    - Installs silently with desired MSI properties
    - Authenticates with the provided auth key

.USAGE
    Silent (pre-set key, default Tailscale coordination server):
    $tailscale_authkey = "tskey-auth-xxxx"; iwr https://raw.githubusercontent.com/MacsInSpace/tailscale-silent-installer/refs/heads/main/tailscale.ps1 -UseBasicParsing | iex

    Silent (pre-set key, custom headscale server):
    $tailscale_authkey = "tskey-auth-xxxx"; $tailscale_loginserver = "https://my.headscaleserver.com"; iwr https://raw.githubusercontent.com/MacsInSpace/tailscale-silent-installer/refs/heads/main/tailscale.ps1 -UseBasicParsing | iex

    Interactive (will prompt for both):
    iwr https://raw.githubusercontent.com/MacsInSpace/tailscale-silent-installer/refs/heads/main/tailscale.ps1 -UseBasicParsing | iex

You may need to enable TLS for secure downloads on PS version 5ish:
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#>

# -- Config -------------------------------------------------------------------
$logFile      = "$env:TEMP\tailscale-install.log"
$tailscaleExe = "$env:ProgramFiles\Tailscale\tailscale.exe"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -- Logging ------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "$timestamp [$Level] $Message"
    Add-Content -Path $logFile -Value $entry
    switch ($Level) {
        "INFO"  { Write-Host $Message -ForegroundColor Cyan }
        "WARN"  { Write-Warning $Message }
        "ERROR" { Write-Host $Message -ForegroundColor Red }
    }
}

# -- Auth Key -----------------------------------------------------------------
if (-not $tailscale_authkey) {
    $tailscale_authkey = Read-Host "Enter Tailscale auth key (tskey-auth-...) or press Enter to skip"
}
if (-not $tailscale_authkey) {
    Write-Log "No auth key provided. Tailscale will be installed but not connected." -Level WARN
}

# -- Login Server -------------------------------------------------------------
if (-not $tailscale_loginserver) {
    $tailscale_loginserver = Read-Host "Enter login server URL (e.g. https://my.headscaleserver.com) or press Enter for default Tailscale"
}
if (-not $tailscale_loginserver) {
    Write-Log "No login server provided. Using default Tailscale coordination server." -Level WARN
}

# -- Tailscale Up Options -----------------------------------------------------
# Can be overridden before running:
# $tailscale_acceptdns = "true"; $tailscale_acceptroutes = "true"
if (-not $tailscale_acceptdns)    { $tailscale_acceptdns    = "false" }
if (-not $tailscale_acceptroutes) { $tailscale_acceptroutes = "false" }

# -- MSI Properties -----------------------------------------------------------
$msiProperties = @(
    "TS_NOLAUNCH=1"                      # Don't launch GUI during install
    "TS_INSTALLUPDATES=always"           # Auto-install updates
    "TS_UNATTENDEDMODE=always"           # Run unattended (no interactive login prompt)
    "TS_ONBOARDING_FLOW=hide"            # Suppress first-run welcome/setup wizard
    "TS_ADMINCONSOLE=hide"               # Remove admin console link from tray menu
    "TS_ADVERTISEEXITNODE=never"         # Prevent machine being used as exit node
    "TS_ALLOWINCOMINGCONNECTIONS=always" # Lock incoming connections on
)

# -- Functions ----------------------------------------------------------------
function Get-LatestTailscaleVersion {
    Write-Log "Fetching latest Tailscale version..."
    $html = (Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/#windows" -UseBasicParsing).Content
    $versionMatches = [regex]::Matches($html, 'tailscale-setup-([\d.]+)-amd64\.msi')
    if ($versionMatches.Count -eq 0) {
        throw "Could not parse latest version from pkgs.tailscale.com"
    }
    return $versionMatches[0].Groups[1].Value
}

function Get-InstalledTailscaleVersion {
    $reg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" `
                            -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like "Tailscale*" } |
           Select-Object -First 1
    if ($reg) { return $reg.DisplayVersion } else { return $null }
}

function Get-Architecture {
    $cpu = (Get-CimInstance -ClassName Win32_Processor).Architecture
    # 0=x86, 5=ARM, 6=IA64, 9=x64, 12=ARM64
    switch ($cpu) {
        9       { return "amd64" }
        12      { return "arm64" }
        0       { return "x86"   }
        default {
            Write-Log "Unknown CPU architecture ($cpu), defaulting to amd64." -Level WARN
            return "amd64"
        }
    }
}

function Test-InternetConnectivity {
    $targets = @(
        "pkgs.tailscale.com"
        "tailscale.com"
    )
    foreach ($target in $targets) {
        try {
            Invoke-WebRequest -Uri "https://$target" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
            Write-Log "Connectivity OK: $target"
        } catch {
            Write-Log "Connectivity FAIL: $target - $($_.Exception.Message)" -Level ERROR
            return $false
        }
    }
    return $true
}

# -- Connectivity Check -------------------------------------------------------
Write-Log "Checking internet connectivity..."
if (-not (Test-InternetConnectivity)) {
    Write-Log "Connectivity check failed. See log: $logFile" -Level ERROR
    exit 1
}
Write-Log "Connectivity OK."

# -- Main ---------------------------------------------------------------------
$latestVersion    = Get-LatestTailscaleVersion
$installedVersion = Get-InstalledTailscaleVersion
$arch             = Get-Architecture
$displayVersion   = if ($installedVersion) { $installedVersion } else { "Not installed" }

Write-Log "Latest version   : $latestVersion"
Write-Log "Installed version: $displayVersion"
Write-Log "Architecture     : $arch"
Write-Log "Login server     : $(if ($tailscale_loginserver) { $tailscale_loginserver } else { 'Default (Tailscale)' })"

if ($installedVersion -and $installedVersion -eq $latestVersion) {
    Write-Log "Tailscale $latestVersion is already installed. Nothing to do."
    exit 0
}

$msiFileName = "tailscale-setup-$latestVersion-$arch.msi"
$downloadUrl = "https://pkgs.tailscale.com/stable/$msiFileName"
$msiPath     = Join-Path $env:TEMP $msiFileName

Write-Log "Downloading $downloadUrl ..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $msiPath -UseBasicParsing

if (-not (Test-Path $msiPath)) {
    Write-Log "Download failed - file not found at $msiPath" -Level ERROR
    exit 1
}

$propString = $msiProperties -join " "
$msiArgs    = "/i `"$msiPath`" /qn /norestart /L*v `"$logFile`" $propString"

Write-Log "Installing Tailscale $latestVersion ($arch)..."
Write-Log "msiexec $msiArgs"

$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru

if ($proc.ExitCode -notin 0, 3010) {
    Write-Log "msiexec exited with code $($proc.ExitCode). Check log: $logFile" -Level ERROR
    exit 1
}
if ($proc.ExitCode -eq 3010) {
    Write-Log "A reboot is required to complete installation (exit code 3010)." -Level WARN
}

if (Test-Path $tailscaleExe) {
    Write-Log "Installation complete."

    # -- Enable RDP -----------------------------------------------------------
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
                     -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    Write-Log "RDP enabled."

    # -- Remove Start Menu and Desktop Shortcuts ------------------------------
    Write-Log "Cleaning up shortcuts..."
    $shortcutPaths = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Tailscale"
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Tailscale.lnk"
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tailscale"
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tailscale.lnk"
        "$env:PUBLIC\Desktop\Tailscale.lnk"
        "$env:USERPROFILE\Desktop\Tailscale.lnk"
    )
    foreach ($path in $shortcutPaths) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed: $path"
        }
    }
    Write-Log "Shortcuts cleaned up."

    # -- Prevent Tailscale GUI launching at login -----------------------------
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -Path $regPath -Name "Tailscale" -ErrorAction SilentlyContinue
    Write-Log "Tailscale GUI startup entry removed."

} else {
    Write-Log "Installation failed - tailscale.exe not found after install." -Level ERROR
    exit 1
}

# -- Authenticate -------------------------------------------------------------
Start-Sleep -Seconds 5

if ($tailscale_authkey) {
    if (Test-Path $tailscaleExe) {
        Write-Log "Authenticating with auth key..."

        $upArgs = @(
            "up",
            "--authkey=$tailscale_authkey",
            "--unattended",
            "--accept-dns=$tailscale_acceptdns",
            "--accept-routes=$tailscale_acceptroutes"
        )

        if ($tailscale_loginserver) {
            $upArgs += "--login-server=$tailscale_loginserver"
        }

        & $tailscaleExe @upArgs

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Tailscale authenticated and connected."
        } else {
            Write-Log "tailscale up exited with code $LASTEXITCODE - check manually." -Level WARN
        }
    } else {
        Write-Log "tailscale.exe not found. Run 'tailscale up --authkey=...' manually after reboot." -Level WARN
    }
}

# -- Cleanup ------------------------------------------------------------------
Remove-Item $msiPath -ErrorAction SilentlyContinue
Write-Log "Done. MSI cleaned up from TEMP."
