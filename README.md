# Tailscale Silent Installer

A touch-free PowerShell script for silently installing and authenticating Tailscale on Windows using the MSI package. Supports standard Tailscale coordination servers and self-hosted [Headscale](https://github.com/juanfont/headscale) servers.

---

## Features

- Detects CPU architecture automatically (amd64, arm64, x86)
- Fetches the latest stable version from pkgs.tailscale.com
- Skips installation if already on the latest version
- Installs silently via MSI with sane defaults for managed endpoints
- Optionally authenticates with a pre-auth key
- Supports custom login servers (Headscale)
- Prompts interactively if variables are not pre-set
- Cleans up the MSI after install

---

## Requirements

- Windows 10 / Windows Server 2016 or later
- PowerShell 5.1 or later
- Must be run as Administrator

---

## Usage

### One-liner (default Tailscale coordination server)

```powershell
$tailscale_authkey = "tskey-auth-xxxx"; iwr https://raw.githubusercontent.com/MacsInSpace/tailscale-silent-installer/refs/heads/main/tailscale.ps1 -UseBasicParsing | iex
```

### One-liner (self-hosted Headscale server)

```powershell
$tailscale_authkey = "tskey-auth-xxxx"; $tailscale_loginserver = "https://your.headscale.server"; iwr https://raw.githubusercontent.com/MacsInSpace/tailscale-silent-installer/refs/heads/main/tailscale.ps1 -UseBasicParsing | iex
```

### Install only (no authentication)

```powershell
iwr https://raw.githubusercontent.com/MacsInSpace/tailscale-silent-installer/refs/heads/main/tailscale.ps1 -UseBasicParsing | iex
```
The script will prompt for an auth key and login server. Press Enter at both prompts to install without connecting.

### TLS note for older PowerShell (5.x)

If you receive TLS errors on older systems, prepend:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```

---

## Variables

| Variable | Description | Required |
|---|---|---|
| `$tailscale_authkey` | Pre-auth key from Tailscale or Headscale admin | No |
| `$tailscale_loginserver` | URL of a custom Headscale server | No |

If either variable is not set before running, the script will prompt interactively. Pressing Enter at the prompt skips that option.

---

## MSI Install Properties

The following properties are configured for managed/unattended deployment:

| Property | Value | Description |
|---|---|---|
| `TS_NOLAUNCH` | `1` | Suppresses GUI launch during install |
| `TS_INSTALLUPDATES` | `always` | Enables automatic updates |
| `TS_UNATTENDEDMODE` | `always` | Runs Tailscale unattended (no login prompt) |
| `TS_ONBOARDING_FLOW` | `hide` | Hides the first-run setup wizard |
| `TS_ADMINCONSOLE` | `hide` | Removes the admin console link from the tray |
| `TS_ADVERTISEEXITNODE` | `never` | Prevents the machine being used as an exit node |
| `TS_ALLOWINCOMINGCONNECTIONS` | `always` | Locks incoming connections on |

To customise these, edit the `$msiProperties` array in the script. Full property reference: [Tailscale MSI documentation](https://tailscale.com/docs/install/windows/msi)

---

## How It Works

1. Checks for an existing Tailscale installation — exits early if already on the latest version
2. Detects CPU architecture via WMI
3. Fetches the latest stable version number from [pkgs.tailscale.com](https://pkgs.tailscale.com/stable/#windows)
4. Downloads the appropriate MSI to `$env:TEMP`
5. Installs silently via `msiexec` with the configured properties
6. Waits for the Tailscale service to start
7. Runs `tailscale up --authkey --unattended` (with `--login-server` if provided)
8. Cleans up the MSI from TEMP

---

## Notes

- The auth key is passed to `tailscale up` post-install, not the MSI installer. `TS_AUTHKEY` is not a valid MSI property.
- Exit code `3010` from msiexec means a reboot is required — the script warns but does not force a reboot.
- The install log is written to `$env:TEMP\tailscale-install.log` for troubleshooting.
- ARM64 machines use the `arm64` MSI. The `tailscale-setup-full-*.exe` bundle is intentionally avoided due to known issues with the self-extracting engine on some systems.

---

## References

- [Tailscale MSI documentation](https://tailscale.com/docs/install/windows/msi)
- [Tailscale package server](https://pkgs.tailscale.com/stable/#windows)
- [Headscale](https://github.com/juanfont/headscale)

---

## License

MIT
