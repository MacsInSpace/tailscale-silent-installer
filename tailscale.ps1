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

# ── Auth Key ──────────────────────────────────────────────────────────────────
if (-not $tailscale_authkey) {
    $tailscale_authkey = Read-Host "Enter Tailscale auth key (tskey-auth-...) or press Enter to skip"
}
if (-not $tailscale_authkey) {
    Write-Host "No auth key provided. Tailscale will be installed but not connected." -ForegroundColor Yellow
}

# ── Login Server ──────────────────────────────────────────────────────────────
if (-not $tailscale_loginserver) {
    $tailscale_loginserver = Read-Host "Enter login server URL (e.g. https://my.headscaleserver.com) or press Enter for default Tailscale"
}
if (-not $tailscale_loginserver) {
    Write-Host "No login server provided. Using default Tailscale coordination server." -ForegroundColor Yellow
}

# ── Tailscale Up Options ───────────────────────────────────────────────────────
# Can be overridden before running:
# $tailscale_acceptdns = "true"; $tailscale_acceptroutes = "true"
if (-not $tailscale_acceptdns)    { $tailscale_acceptdns    = "false" }
if (-not $tailscale_acceptroutes) { $tailscale_acceptroutes = "false" }

# ── MSI Properties ────────────────────────────────────────────────────────────
$msiProperties = @(
    "TS_NOLAUNCH=1"                      # Don't launch GUI during install
    "TS_INSTALLUPDATES=always"           # Auto-install updates
    "TS_UNATTENDEDMODE=always"           # Run unattended (no interactive login prompt)
    "TS_ONBOARDING_FLOW=hide"            # Suppress first-run welcome/setup wizard
    "TS_ADMINCONSOLE=hide"               # Remove admin console link from tray menu
    "TS_ADVERTISEEXITNODE=never"         # Prevent machine being used as exit node
    "TS_ALLOWINCOMINGCONNECTIONS=always" # Lock incoming connections on
)

$tailscaleExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
$logFile      = "$env:TEMP\tailscale-install.log"

# ── Functions ─────────────────────────────────────────────────────────────────
function Get-LatestTailscaleVersion {
    Write-Host "Fetching latest Tailscale version..." -ForegroundColor Cyan
    $html = (Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/#windows" -UseBasicParsing).Content
    $matches = [regex]::Matches($html, 'tailscale-setup-([\d.]+)-amd64\.msi')
    if ($matches.Count -eq 0) {
        throw "Could not parse latest version from pkgs.tailscale.com"
    }
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
        9       { return "amd64" }
        12      { return "arm64" }
        0       { return "x86"   }
        default {
            Write-Warning "Unknown CPU architecture ($cpu), defaulting to amd64."
            return "amd64"
        }
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────
$latestVersion    = Get-LatestTailscaleVersion
$installedVersion = Get-InstalledTailscaleVersion
$arch             = Get-Architecture

Write-Host "Latest version   : $latestVersion"
Write-Host "Installed version: $(if ($installedVersion) { $installedVersion } else { 'Not installed' })"
Write-Host "Architecture     : $arch"
Write-Host "Login server     : $(if ($tailscale_loginserver) { $tailscale_loginserver } else { 'Default (Tailscale)' })"

if ($installedVersion -and $installedVersion -eq $latestVersion) {
    Write-Host "Tailscale $latestVersion is already installed. Nothing to do." -ForegroundColor Green
    exit 0
}

$msiFileName = "tailscale-setup-$latestVersion-$arch.msi"
$downloadUrl = "https://pkgs.tailscale.com/stable/$msiFileName"
$msiPath     = Join-Path $env:TEMP $msiFileName

Write-Host "Downloading $downloadUrl ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $downloadUrl -OutFile $msiPath -UseBasicParsing

if (-not (Test-Path $msiPath)) {
    throw "Download failed — file not found at $msiPath"
}

$propString = $msiProperties -join " "
$msiArgs    = "/i `"$msiPath`" /qn /norestart /L*v `"$logFile`" $propString"

Write-Host "Installing Tailscale $latestVersion ($arch)..." -ForegroundColor Cyan
Write-Host "  msiexec $msiArgs"

$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru

if ($proc.ExitCode -notin 0, 3010) {
    throw "msiexec exited with code $($proc.ExitCode). Check log: $logFile"
}
if ($proc.ExitCode -eq 3010) {
    Write-Warning "A reboot is required to complete installation (exit code 3010)."
}

if (Test-Path $tailscaleExe) {
    Write-Host "Installation complete." -ForegroundColor Green
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    
    # ── Remove Start Menu & Desktop Shortcuts ─────────────────────────────────────
    Write-Host "Cleaning up shortcuts..." -ForegroundColor Cyan
    
    $shortcutPaths = @(
        # Start menu - all users
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Tailscale"
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Tailscale.lnk"
        # Start menu - current user
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tailscale"
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tailscale.lnk"
        # Desktop - all users
        "$env:PUBLIC\Desktop\Tailscale.lnk"
        # Desktop - current user
        "$env:USERPROFILE\Desktop\Tailscale.lnk"    
        )

    foreach ($path in $shortcutPaths) {
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed: $path" -ForegroundColor Gray
        }
    }

    Write-Host "Shortcuts cleaned up." -ForegroundColor Green
    # Prevent Tailscale GUI from launching at login
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -Path $regPath -Name "Tailscale" -ErrorAction SilentlyContinue

    } else {
    Write-Host "Installation failed." -ForegroundColor Green
    exit 1
}

# ── Authenticate ──────────────────────────────────────────────────────────────
Start-Sleep -Seconds 5

if ($tailscale_authkey) {
    if (Test-Path $tailscaleExe) {
        Write-Host "Authenticating with auth key..." -ForegroundColor Cyan

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
            Write-Host "Tailscale authenticated and connected." -ForegroundColor Green
        } else {
            Write-Warning "tailscale up exited with code $LASTEXITCODE — check manually."
        }
    } else {
        Write-Warning "tailscale.exe not found. Run 'tailscale up --authkey=...' manually after reboot."
    }
}

Remove-Item $msiPath -ErrorAction SilentlyContinue
Write-Host "Done. MSI cleaned up from TEMP." -ForegroundColor Green
