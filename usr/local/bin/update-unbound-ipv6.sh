#!/bin/sh

# update-unbound-ipv6.sh
# Dynamic IPv6 config rewriting, validation, backups with periodic execution.

CONFIG_FILE="${CONFIG_FILE:-/etc/unbound/unbound.conf.d/sainternet-domains.conf}"
INTERFACE="${INTERFACE:-eth0}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/update-unbound-ipv6}"
export LOG_TAG="${LOG_TAG:-update-unbound-ipv6}"

CONFIG_FILENAME=$(basename "$CONFIG_FILE")

mkdir -p "$BACKUP_DIR" || exit 1

log_message() {
    printf "%s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

update_config_header() {
    config_file="$1"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    header_tmp=$(mktemp) || return 1

    if grep -q "^# Last edited by: update-unbound-ipv6.sh" "$config_file"; then
        awk -v ts="$timestamp" '
            /^# Last edited by: update-unbound-ipv6.sh/ {
                print "# Last edited by: update-unbound-ipv6.sh"
                print "# Last edit time: " ts
                getline
                next
            }
            { print }
        ' "$config_file" > "$header_tmp" || {
            rm -f "$header_tmp"
            return 1
        }
    else
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

get_current_ipv6() {
    global_prefix=$(ip -6 addr show "$INTERFACE" scope global | \
        grep 'inet6' | grep -vi '^.* fd' | head -n1 | \
        awk '{print $2}' | cut -d'/' -f1 | cut -d':' -f1-4 | tr 'A-F' 'a-f')

    ula_prefix=$(ip -6 addr show "$INTERFACE" scope global | \
        grep 'inet6' | grep -i ' fd' | head -n1 | \
        awk '{print $2}' | cut -d'/' -f1 | cut -d':' -f1-4 | tr 'A-F' 'a-f')

    printf "%s|%s\n" "$global_prefix" "$ula_prefix"
}

get_config_prefixes() {
    all_ipv6=$(grep -oE '([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}' "$CONFIG_FILE" | tr 'A-F' 'a-f')

    global_prefix=$(printf "%s\n" "$all_ipv6" | grep -vi '^fd' | head -n1 | cut -d':' -f1-4)
    ula_prefix=$(printf "%s\n" "$all_ipv6" | grep -i '^fd' | head -n1 | cut -d':' -f1-4)

    printf "%s|%s\n" "$global_prefix" "$ula_prefix"
}

if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    log_message "ERROR: Interface $INTERFACE not found"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    log_message "ERROR: Config file $CONFIG_FILE not found"
    exit 1
fi

ORIGINAL_PERMS=$(stat -c '%a' "$CONFIG_FILE")
log_message "DEBUG: Original permissions: $ORIGINAL_PERMS"

current_prefixes=$(get_current_ipv6)
CURRENT_GLOBAL=$(printf "%s" "$current_prefixes" | cut -d'|' -f1)
CURRENT_ULA=$(printf "%s" "$current_prefixes" | cut -d'|' -f2)

if [ -z "$CURRENT_GLOBAL" ] || [ -z "$CURRENT_ULA" ]; then
    log_message "WARNING: Could not detect IPv6 addresses on $INTERFACE"
    exit 0
fi

config_prefixes=$(get_config_prefixes)
CONFIG_GLOBAL=$(printf "%s" "$config_prefixes" | cut -d'|' -f1)
CONFIG_ULA=$(printf "%s" "$config_prefixes" | cut -d'|' -f2)

if [ -z "$CONFIG_GLOBAL" ] || [ -z "$CONFIG_ULA" ]; then
    log_message "ERROR: Could not extract existing IPv6 prefixes from $CONFIG_FILE"
    exit 1
fi

if [ "$CURRENT_GLOBAL" = "$CONFIG_GLOBAL" ] && [ "$CURRENT_ULA" = "$CONFIG_ULA" ]; then
    log_message "IPv6 prefixes unchanged. No update needed."
    log_message "Global: $CURRENT_GLOBAL, ULA: $CURRENT_ULA"
    exit 0
fi

log_message "IPv6 prefix change detected!"
log_message "Global: $CONFIG_GLOBAL -> $CURRENT_GLOBAL"
log_message "ULA: $CONFIG_ULA -> $CURRENT_ULA"

backup_file="$BACKUP_DIR/${CONFIG_FILENAME}.$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG_FILE" "$backup_file" || {
    log_message "ERROR: Failed to create backup."
    exit 1
}
log_message "Backed up config to $backup_file"

temp_file=$(mktemp) || {
    log_message "ERROR: Failed to create temp file."
    exit 1
}
cp "$CONFIG_FILE" "$temp_file" || {
    log_message "ERROR: Failed to stage config copy."
    rm -f "$temp_file"
    exit 1
}

# Update global IPv6 prefix: replace first 4 hextets only, preserve last 4
sed -i "s|$CONFIG_GLOBAL:\([0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*\)|$CURRENT_GLOBAL:\1|g" "$temp_file"

# Update ULA prefix: replace first 4 hextets only, preserve last 4
sed -i "s|$CONFIG_ULA:\([0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*\)|$CURRENT_ULA:\1|g" "$temp_file"

if ! update_config_header "$temp_file"; then
    log_message "ERROR: Failed to update config header. Restoring backup..."
    rm -f "$temp_file"
    cp "$backup_file" "$CONFIG_FILE"
    exit 1
fi

if ! mv "$temp_file" "$CONFIG_FILE"; then
    log_message "ERROR: Failed to write config file. Restoring backup..."
    rm -f "$temp_file"
    cp "$backup_file" "$CONFIG_FILE"
    exit 1
fi

chmod "$ORIGINAL_PERMS" "$CONFIG_FILE" || {
    log_message "ERROR: Failed to restore config permissions. Restoring backup..."
    cp "$backup_file" "$CONFIG_FILE"
    exit 1
}
log_message "DEBUG: Restored permissions to $ORIGINAL_PERMS"

if checkconf_output=$(unbound-checkconf 2>&1); then
    log_message "Config validated successfully. Restarting Unbound..."
    if systemctl restart unbound; then
        log_message "Unbound restarted successfully."
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
    printf "%s\n" "$checkconf_output" | while IFS= read -r line; do
        log_message "  $line"
    done
    cp "$backup_file" "$CONFIG_FILE"
    exit 1
fi
