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
#>

# ── Configuration ─────────────────────────────────────────────────────────────

<#
You may need to enable TLS for secure downloads on PS version 5ish
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;

$tailscale_authkey = "tskey-auth-12345qwert-1234567890qwertyuiop"

Auth key - can be passed as a variable before invoking this script:
$tailscale_authkey = "tskey-auth-xxxx"; iwr https://raw.githubusercontent.com/MacsInSpace/tailscale-silent-installer/refs/heads/main/tailscale.ps1 | iex
or
$tailscale_authkey = "tskey-auth-xxxx"; iwr https://raw.githubusercontent.com/MacsInSpace/tailscale-silent-installer/refs/heads/main/tailscale.ps1 -UseBasicParsing | iex
#>

if (-not $tailscale_authkey) {
    $tailscale_authkey = Read-Host "Enter Tailscale auth key (tskey-auth-...)"
    if (-not $tailscale_authkey) {
        throw "No auth key provided. Set one as a variable or hard code it. Aborting."
    }
}


# MSI install properties
$msiProperties = @(
    "TS_NOLAUNCH=1"              # Don't launch GUI during install
    "TS_INSTALLUPDATES=always"   # Auto-install updates
    "TS_UNATTENDEDMODE=always"   # Run unattended (no interactive login prompt)
    "TS_ONBOARDING_FLOW=hide"    # Suppresses the first-run welcome/setup wizard
    "TS_ADMINCONSOLE=hide"       # Removes the admin console link from the tray menu
    "TS_ADVERTISEEXITNODE=never" # Locks down exit node advertising so the machine can't be turned into one by a user
    "TS_ALLOWINCOMINGCONNECTIONS=always" # Locks it on so users can't disable it through the UI, useful if you need reliable inbound access to managed machines
)

# Tailscale CLI after install
$tailscaleExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
$logFile      = "$env:TEMP\tailscale-install.log"
# ──────────────────────────────────────────────────────────────────────────────

function Get-LatestTailscaleVersion {
    Write-Host "Fetching latest Tailscale version..." -ForegroundColor Cyan
    $html = (Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/#windows" -UseBasicParsing).Content

    # Grab versions from the Windows MSI filenames
    $matches = [regex]::Matches($html, 'tailscale-setup-([\d.]+)-amd64\.msi')
    if ($matches.Count -eq 0) {
        throw "Could not parse latest version from pkgs.tailscale.com"
    }
    # Return the first (latest) match
    return $matches[0].Groups[1].Value
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
        9  { return "amd64" }
        12 { return "arm64" }
        0  { return "x86"   }
        default {
            Write-Warning "Unknown CPU architecture ($cpu), defaulting to amd64."
            return "amd64"
        }
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

$latestVersion   = Get-LatestTailscaleVersion
$installedVersion = Get-InstalledTailscaleVersion
$arch            = Get-Architecture

Write-Host "Latest version  : $latestVersion"
Write-Host "Installed version: $(if ($installedVersion) { $installedVersion } else { 'Not installed' })"
Write-Host "Architecture    : $arch"

if ($installedVersion -and $installedVersion -eq $latestVersion) {
    Write-Host "Tailscale $latestVersion is already installed. Nothing to do." -ForegroundColor Green
    exit 0
}

# Build download URL and local path
$msiFileName = "tailscale-setup-$latestVersion-$arch.msi"
$downloadUrl = "https://pkgs.tailscale.com/stable/$msiFileName"
$msiPath     = Join-Path $env:TEMP $msiFileName

Write-Host "Downloading $downloadUrl ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $downloadUrl -OutFile $msiPath -UseBasicParsing

if (-not (Test-Path $msiPath)) {
    throw "Download failed — file not found at $msiPath"
}

# Build msiexec argument string
$propString  = $msiProperties -join " "
$msiArgs     = "/i `"$msiPath`" /qn /norestart /L*v `"$logFile`" $propString"

Write-Host "Installing Tailscale $latestVersion ($arch)..." -ForegroundColor Cyan
Write-Host "  msiexec $msiArgs"

$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru

if ($proc.ExitCode -notin 0, 3010) {
    throw "msiexec exited with code $($proc.ExitCode). Check log: $logFile"
}

if ($proc.ExitCode -eq 3010) {
    Write-Warning "A reboot is required to complete installation (exit code 3010)."
}

Write-Host "Installation complete." -ForegroundColor Green

# ── Authenticate ──────────────────────────────────────────────────────────────

# Give the service a moment to start after install
Start-Sleep -Seconds 5

if (Test-Path $tailscaleExe) {
    Write-Host "Authenticating with auth key..." -ForegroundColor Cyan
    & $tailscaleExe up --authkey=$tailscale_authkey --unattended
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Tailscale authenticated and connected." -ForegroundColor Green
    } else {
        Write-Warning "tailscale up exited with code $LASTEXITCODE — check manually."
    }
} else {
    Write-Warning "tailscale.exe not found at expected path. You may need to run 'tailscale up --authkey=...' manually after reboot."
}

# Clean up MSI
Remove-Item $msiPath -ErrorAction SilentlyContinue
Write-Host "Done. MSI cleaned up from TEMP." -ForegroundColor Green
