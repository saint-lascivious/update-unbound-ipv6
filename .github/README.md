# update-unbound-ipv6

Automatically keeps an Unbound local DNS config in sync with your host’s current IPv6 prefixes (global + ULA), validates changes, writes a metadata header, and restarts Unbound only when needed.

## What it does

- Detects current IPv6 prefixes on a selected network interface
- Compares them with prefixes currently used in `sainternet-domains.conf`
- Rewrites matching IPv6 entries when prefixes change
- Adds/updates a header in the config showing:
  - what edited the file
  - when it was last edited
- Validates config using `unbound-checkconf`
- Restarts Unbound on valid changes
- Restores from backup on failure
- Runs automatically at boot + periodically via `systemd` timer

## Requirements

- Linux host with:
  - `unbound`
  - `systemd`
  - `iproute2` (`ip`)
  - standard POSIX tools (`sh`, `grep`, `awk`, `sed`, `cut`, `mktemp`)
- Root privileges for install and service management

## Project files

- `update-unbound-ipv6.sh` → main POSIX `sh` update script
- `unbound-ipv6-update.service` → one-shot systemd unit
- `unbound-ipv6-update.timer` → periodic scheduler

---

## Manual installation

### 1) Install the script

Create:

`/usr/local/bin/update-unbound-ipv6.sh`

with

```sh
#!/bin/sh

# update-unbound-ipv6.sh

# Dynamic IPv6 config rewriting, validation, backups with periodic execution.

CONFIG_FILE="${CONFIG_FILE:-/etc/unbound/unbound.conf.d/sainternet-domains.conf}"
INTERFACE="${INTERFACE:-eth0}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/update-unbound-ipv6}"
export LOG_TAG="${LOG_TAG:-update-unbound-ipv6}"

# Extract just the filename from CONFIG_FILE path
CONFIG_FILENAME=$(basename "$CONFIG_FILE")

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR" || exit 1

# Function to log messages
log_message() {
    printf "%s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# Function to add or update comment header
update_config_header() {
    config_file="$1"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    header_tmp=$(mktemp) || return 1

    # Check if header already exists
    if grep -q "^# Last edited by: update-unbound-ipv6.sh" "$config_file"; then
        # Update existing header
        awk -v ts="$timestamp" '
            /^# Last edited by: update-unbound-ipv6.sh/ {
                print "# Last edited by: update-unbound-ipv6.sh"
                print "# Last edit time: " ts
                # Skip the next line (old timestamp)
                getline
                next
            }
            { print }
        ' "$config_file" > "$header_tmp" || {
            rm -f "$header_tmp"
            return 1
        }
    else
        # Add new header at the top
        {
            printf "# Last edited by: update-unbound-ipv6.sh\n"
            printf "# Last edit time: %s\n" "$timestamp"
            printf "# This file is automatically maintained for IPv6 prefix updates\n"
            printf "#\n"
            cat "$config_file"
        } > "$header_tmp" || {
            rm -f "$header_tmp"
            return 1
        }
    fi

    mv "$header_tmp" "$config_file" || {
        rm -f "$header_tmp"
        return 1
    }
}

# Function to get current IPv6 prefixes from network interface
get_current_ipv6() {
    # Get global IPv6 prefix (first 4 hextets)
    global_prefix=$(ip -6 addr show "$INTERFACE" scope global | \
        grep -v 'scope link' | \
        grep -v 'fd' | \
        grep 'inet6' | \
        head -n1 | \
        awk '{print $2}' | \
        cut -d'/' -f1 | \
        cut -d':' -f1-4)
    # Get ULA prefix (first 4 hextets of fd address)
    ula_prefix=$(ip -6 addr show "$INTERFACE" scope global | \
        grep 'fd' | \
        head -n1 | \
        awk '{print $2}' | \
        cut -d'/' -f1 | \
        cut -d':' -f1-4)
    printf "%s:%s\n" "$global_prefix" "$ula_prefix"
}

# Function to extract current prefixes from config file
get_config_prefixes() {
    # Get global prefix (starts with 2404:4404)
    global_prefix=$(grep 'AAAA 2404:4404' "$CONFIG_FILE" | \
        head -n1 | \
        grep -oE '2404:4404:[0-9a-f:]+' | \
        head -n1 | \
        cut -d':' -f1-4)
    # Get ULA prefix (starts with fd)
    ula_prefix=$(grep 'AAAA fd' "$CONFIG_FILE" | \
        head -n1 | \
        grep -oE 'fdbf:[0-9a-f:]+' | \
        head -n1 | \
        cut -d':' -f1-4)
    printf "%s:%s\n" "$global_prefix" "$ula_prefix"
}

# Check if interface exists
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    log_message "ERROR: Interface $INTERFACE not found"
    exit 1
fi

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_message "ERROR: Config file $CONFIG_FILE not found"
    exit 1
fi

# Capture original permissions before any changes
ORIGINAL_PERMS=$(stat -c '%a' "$CONFIG_FILE")
log_message "DEBUG: Original permissions: $ORIGINAL_PERMS"

# Get current network prefixes
current_prefixes=$(get_current_ipv6)
CURRENT_GLOBAL=$(printf "%s" "$current_prefixes" | cut -d':' -f1-4)
CURRENT_ULA=$(printf "%s" "$current_prefixes" | cut -d':' -f5-8)

# Validate we got IPv6 addresses
if [ -z "$CURRENT_GLOBAL" ] || [ -z "$CURRENT_ULA" ]; then
    log_message "WARNING: Could not detect IPv6 addresses on $INTERFACE"
    exit 0
fi

# Get config prefixes
config_prefixes=$(get_config_prefixes)
CONFIG_GLOBAL=$(printf "%s" "$config_prefixes" | cut -d':' -f1-4)
CONFIG_ULA=$(printf "%s" "$config_prefixes" | cut -d':' -f5-8)

# Check if update is needed
if [ "$CURRENT_GLOBAL" = "$CONFIG_GLOBAL" ] && [ "$CURRENT_ULA" = "$CONFIG_ULA" ]; then
    log_message "IPv6 prefixes unchanged. No update needed."
    log_message "Global: $CURRENT_GLOBAL, ULA: $CURRENT_ULA"
    exit 0
fi

log_message "IPv6 prefix change detected!"
log_message "Global: $CONFIG_GLOBAL -> $CURRENT_GLOBAL"
log_message "ULA: $CONFIG_ULA -> $CURRENT_ULA"

# Backup current config with timestamp (using dynamic filename)
backup_file="$BACKUP_DIR/${CONFIG_FILENAME}.$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG_FILE" "$backup_file" || {
    log_message "ERROR: Failed to create backup."
    exit 1
}
log_message "Backed up config to $backup_file"

# Create temporary file for sed operations
temp_file=$(mktemp) || {
    log_message "ERROR: Failed to create temp file."
    exit 1
}
cp "$CONFIG_FILE" "$temp_file" || {
    log_message "ERROR: Failed to stage config copy."
    rm -f "$temp_file"
    exit 1
}

# Update global IPv6 prefix (2404:4404:...)
sed -i "s|$CONFIG_GLOBAL:[0-9a-f:]*|$CURRENT_GLOBAL:|g" "$temp_file"

# Update ULA prefix (fd...)
sed -i "s|$CONFIG_ULA:[0-9a-f:]*|$CURRENT_ULA:|g" "$temp_file"

# Update or add comment header (in-place on staged file)
if ! update_config_header "$temp_file"; then
    log_message "ERROR: Failed to update config header. Restoring backup..."
    rm -f "$temp_file"
    cp "$backup_file" "$CONFIG_FILE"
    exit 1
fi

# Move temp file to actual config
if ! mv "$temp_file" "$CONFIG_FILE"; then
    log_message "ERROR: Failed to write config file. Restoring backup..."
    rm -f "$temp_file"
    cp "$backup_file" "$CONFIG_FILE"
    exit 1
fi

# Restore original permissions
chmod "$ORIGINAL_PERMS" "$CONFIG_FILE" || {
    log_message "ERROR: Failed to restore config permissions. Restoring backup..."
    cp "$backup_file" "$CONFIG_FILE"
    exit 1
}
log_message "DEBUG: Restored permissions to $ORIGINAL_PERMS"

# Validate config
if unbound-checkconf > /dev/null 2>&1; then
    log_message "Config validated successfully. Restarting Unbound..."
    if systemctl restart unbound; then
        log_message "Unbound restarted successfully."
        # Keep only last 10 backups (using dynamic filename pattern)
        find "$BACKUP_DIR" -name "${CONFIG_FILENAME}.*" -type f -printf '%T@ %p\n' | \
            sort -rn | tail -n +11 | cut -d' ' -f2- | xargs -r rm --
        exit 0
    else
        log_message "ERROR: Failed to restart Unbound. Restoring backup..."
        cp "$backup_file" "$CONFIG_FILE"
        exit 1
    fi
else
    log_message "ERROR: Config validation failed! Restoring backup..."
    cp "$backup_file" "$CONFIG_FILE"
    exit 1
fi
```

Make it executable:

```sh
sudo chmod +x /usr/local/bin/update-unbound-ipv6.sh
```

Edit the interface name in the script:

```sh
sudo nano /usr/local/bin/update-unbound-ipv6.sh
```

Set:

```sh
INTERFACE="eth0"
```

to your real interface (examples: `ens18`, `enp3s0`, `wlan0`).

---

### 2) Install the systemd service

Create:

`/etc/systemd/system/unbound-ipv6-update.service`

with:

```ini
[Unit]
Description=Dynamic IPv6 config rewriting, validation, backups with periodic execution.
Documentation=man:unbound.conf(5)
After=network-online.target unbound.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-unbound-ipv6.sh
StandardOutput=journal
StandardError=journal
User=root
Group=root

# Security hardening
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/etc/unbound /var/backups/unbound

[Install]
WantedBy=multi-user.target
```

---

### 3) Install the systemd timer

Create:

`/etc/systemd/system/unbound-ipv6-update.timer`

with:

```ini
[Unit]
Description=Dynamic IPv6 config rewriting, validation, backups with periodic execution.
Documentation=man:unbound.conf(5)
Requires=unbound-ipv6-update.service

[Timer]
# Run 2 minutes after boot
OnBootSec=2min

# Run every hour thereafter
OnUnitActiveSec=1h

# If system was off during scheduled time, run on next boot
Persistent=true

[Install]
WantedBy=timers.target
```

---

### 4) Reload systemd and enable timer

```sh
sudo systemctl daemon-reload
sudo systemctl enable unbound-ipv6-update.timer
sudo systemctl start unbound-ipv6-update.timer
```

---

### 5) Verify

Check timer:

```sh
sudo systemctl status unbound-ipv6-update.timer
sudo systemctl list-timers unbound-ipv6-update.timer
```

Run script manually once:

```sh
sudo /usr/local/bin/update-unbound-ipv6.sh
```

View logs:

```sh
sudo journalctl -u unbound-ipv6-update.service
sudo journalctl -f -u unbound-ipv6-update.service
```

## Config file header behavior

When edits occur, the script writes/updates a header at the top of the target Unbound config file:

```text
# Last edited by: update-unbound-ipv6.sh
# Last edit time: YYYY-MM-DD HH:MM:SS ZONE
# This file is automatically maintained for IPv6 prefix updates
#
```

## Notes

- Backups are stored under `/var/backups/unbound`.
- Only changed prefixes trigger rewrite + restart.
- If validation fails, the previous config is restored automatically.