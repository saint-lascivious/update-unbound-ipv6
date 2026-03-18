# update-unbound-ipv6

Detects IPv6 prefix changes and rewrites local Unbound config.

- [Features](#features)
- [Requirements](#requirements)
- [Repository layout](#repository-layout)
- [Install](#install)
- [Configuration](#configuration)
- [Command-line options](#command-line-options)
- [Usage](#usage)
- [Exit codes](#exit-codes)
- [Verify](#verify)
- [Managed config header](#managed-config-header)
- [Notes](#notes)
- [License](#license)

---

## Features

- Detects current IPv6 prefixes on an interface
- Supports:
  - global unicast
  - ULA
  - link-local
- Rewrites matching IPv6 addresses in an Unbound config fragment
- Preserves file ownership and permissions
- Creates rolling backups
- Validates config before reload/restart
- Restores the last backup on failure
- Writes plaintext and/or JSON status files (each independently configurable)
- Maintains a managed header in the target config file
- Records last known good backup path in the managed header
- Opportunistically records backup SHA-256 in the managed header
- Verifies recorded backup hash on startup (warn by default, strict mode optional)

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Requirements

- Linux
- `unbound`
- `systemd`
- `iproute2`
- standard POSIX tools (`sh`, `awk`, `sed`, `grep`, `cut`, `mktemp`, etc.)
- root privileges for install and service management

Optional for backup hash metadata/verification (any one available):
- `sha256sum` (preferred)
- `shasum`
- `openssl`

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Repository layout

Expected files:

- `usr/local/bin/update-unbound-ipv6.sh`
- `etc/systemd/system/update-unbound-ipv6.service`
- `etc/systemd/system/update-unbound-ipv6.timer`
- `etc/unbound/unbound.conf.d/local-domains.conf` (example)

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Install

Clone the repository:

```sh
git clone https://github.com/saint-lascivious/update-unbound-ipv6.git
cd update-unbound-ipv6
```

Install the script and systemd units:

```sh
sudo install -D -m 0755 usr/local/bin/update-unbound-ipv6.sh /usr/local/bin/update-unbound-ipv6.sh
sudo install -D -m 0644 etc/systemd/system/update-unbound-ipv6.service /etc/systemd/system/update-unbound-ipv6.service
sudo install -D -m 0644 etc/systemd/system/update-unbound-ipv6.timer /etc/systemd/system/update-unbound-ipv6.timer
```

Install the example Unbound fragment if needed:

```sh
sudo install -D -m 0644 etc/unbound/unbound.conf.d/local-domains.conf /etc/unbound/unbound.conf.d/local-domains.conf
```

Reload systemd and enable the timer:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now update-unbound-ipv6.timer
```

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Configuration

The script uses environment variables.

Common settings:

- `CONFIG_FILE`  
  Default: `/etc/unbound/unbound.conf.d/local-domains.conf`
- `INTERFACE`  
  Default: `eth0`
- `BACKUP_DIR`  
  Default: `/var/backups/update-unbound-ipv6`
- `NUM_BACKUPS`  
  Default: `10`
- `BACKUP_HASH_STRICT`  
  Default: `0` (warn only)  
  Set to `1` to fail the run if recorded backup hash mismatches the backup file
- `VERBOSITY`  
  Default: `1` (ERROR)
- `LOG_TO_SYSLOG`  
  Default: `0` (disabled)
- `LOG_TAG`  
  Default: `update-unbound-ipv6`
- `STATUS_TXT_ENABLED`  
  Default: `0` (disabled)
- `STATUS_DIR`  
  Default: `/var/lib/update-unbound-ipv6`
- `STATUS_TXT`  
  Default: `$STATUS_DIR/status.txt`
- `STATUS_JSON_ENABLED`  
  Default: `0` (disabled)
- `WEBROOT_DIR`  
  Default: `/var/www/html`
- `STATUS_JSON`  
  Default: `$WEBROOT_DIR/update-unbound-ipv6-status.json`
- `LOCK_DIR`  
  Default: `/var/lock/update-unbound-ipv6.lock`
- `DRY_RUN`  
  Default: `0` (disabled)

Recommended: override settings with systemd instead of editing the script directly.

Create an override:

```sh
sudo systemctl edit update-unbound-ipv6.service
```

Example:

```ini
[Service]
Environment=CONFIG_FILE=/etc/unbound/unbound.conf.d/local-domains.conf
Environment=INTERFACE=eth0
Environment=BACKUP_DIR=/var/backups/update-unbound-ipv6
Environment=NUM_BACKUPS=10
Environment=BACKUP_HASH_STRICT=0
Environment=VERBOSITY=1
Environment=LOG_TO_SYSLOG=0
Environment=LOG_TAG=update-unbound-ipv6
Environment=STATUS_TXT_ENABLED=0
Environment=STATUS_DIR=/var/lib/update-unbound-ipv6
Environment=STATUS_TXT=/var/lib/update-unbound-ipv6/status.txt
Environment=STATUS_JSON_ENABLED=0
Environment=WEBROOT_DIR=/var/www/html
Environment=STATUS_JSON=/var/www/html/update-unbound-ipv6-status.json
Environment=DRY_RUN=0
Environment=LOCK_DIR=/var/lock/update-unbound-ipv6.lock
```

Then reload systemd:

```sh
sudo systemctl daemon-reload
sudo systemctl restart update-unbound-ipv6.timer
```

If `CONFIG_FILE` is changed to a path outside the service's allowed write locations, the service override may also need a matching `ReadWritePaths=` override, as `ReadWritePaths=` does not automatically follow `CONFIG_FILE`.

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Command-line options

Usage:

```sh
update-unbound-ipv6.sh [v|version|--version|h|help|--help|-h]
```

Supported arguments:

- `v`, `version`, `--version`  
  Print script name and version, then exit.
- `h`, `help`, `--help`, `-h`  
  Print help/usage text, then exit.

Behavior:

- No arguments: runs normal update flow.
- Unknown arguments: print error + help to stderr and exit with code `2`.

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Usage

Run once manually:

```sh
sudo systemctl start update-unbound-ipv6.service
```

Or run the script directly:

```sh
sudo /usr/local/bin/update-unbound-ipv6.sh
```

Dry run:

```sh
sudo env DRY_RUN=1 /usr/local/bin/update-unbound-ipv6.sh
```

Strict backup hash verification:

```sh
sudo env BACKUP_HASH_STRICT=1 /usr/local/bin/update-unbound-ipv6.sh
```

Print version/help:

```sh
sudo /usr/local/bin/update-unbound-ipv6.sh --version
sudo /usr/local/bin/update-unbound-ipv6.sh --help
```

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Exit codes

- `0`  
  Success.  
  Note: non-fatal warning outcomes (for example, no IPv6 prefixes detected) still exit `0`.
- `1`  
  Error (for example: dependency check failure, config parse/update failure, backup failure, validation failure, reload/restart failure, strict hash mismatch).
- `2`  
  Invalid CLI argument.

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Verify

Service status:

```sh
sudo systemctl status update-unbound-ipv6.service
```

Timer status:

```sh
sudo systemctl status update-unbound-ipv6.timer
sudo systemctl list-timers --all | grep update-unbound-ipv6
```

Logs:

```sh
sudo journalctl -u update-unbound-ipv6.service
sudo journalctl -f -u update-unbound-ipv6.service
```

Status files:

```sh
sudo cat /var/lib/update-unbound-ipv6/status.txt
sudo cat /var/www/html/update-unbound-ipv6-status.json
```

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Managed config header

When the target config is updated, the script writes a managed header like:

```text
# Last edited by: update-unbound-ipv6.sh
# Last edit time: YYYY-MM-DD HH:MM:SS ZONE
# Last known good backup: /var/backups/update-unbound-ipv6/local-domains.conf.YYYYMMDD-HHMMSS
# Last known good backup sha256: <64-hex-digest>
# This file is automatically maintained for IPv6 prefix updates
#
```

Notes:
- The SHA-256 line is written only if a supported hash utility is available.
- On startup, if both backup path and hash are present, the script verifies integrity.
- If verification fails:
  - `BACKUP_HASH_STRICT=0`: warning only (run continues)
  - `BACKUP_HASH_STRICT=1`: run fails

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## Notes

- Backups are stored under `/var/backups/update-unbound-ipv6`.
- Only changed prefixes are rewritten.
- If validation or reload fails, the previous config is restored.
- Plaintext and JSON status outputs can each be independently enabled by setting `STATUS_TXT_ENABLED=1` or `STATUS_JSON_ENABLED=1`.
- If service hardening is enabled, the unit must be allowed to write to:
  - `/etc/unbound/unbound.conf.d` (or wherever `CONFIG_FILE` points)
  - `/var/backups/update-unbound-ipv6`
  - `/var/lib/update-unbound-ipv6` (if `STATUS_TXT_ENABLED=1`)
  - `/var/www/html` (if `STATUS_JSON_ENABLED=1`)
  - `/var/lock`
- If `CONFIG_FILE` is moved elsewhere, update the service `ReadWritePaths=` setting to include that location.

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

## License

GNU General Public License v3.0 or later.

```text
    Copyright (C) 2026 saint-lascivious (Hayden Pearce)

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
```

<p align="right"><a href="#update-unbound-ipv6">↑ Back to top</a></p>

---

<p align="center">
  <sub><sup>
    <strong>update-unbound-ipv6</strong> ·
    <a href="https://github.com/saint-lascivious/update-unbound-ipv6">Repository</a> ·
    <a href="https://github.com/saint-lascivious/update-unbound-ipv6/issues">Issues</a>
  </sup></sub>
</p>
