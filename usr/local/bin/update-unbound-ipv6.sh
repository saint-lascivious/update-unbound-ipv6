#!/bin/sh

# update-unbound-ipv6.sh
# Dynamic IPv6 config rewriting, validation, backups.

CONFIG_FILE="${CONFIG_FILE:-/etc/unbound/unbound.conf.d/local-domains.conf}"
INTERFACE="${INTERFACE:-eth0}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/update-unbound-ipv6}"
export LOG_TAG="${LOG_TAG:-update-unbound-ipv6}"

CONFIG_FILENAME=$(basename "$CONFIG_FILE")

mkdir -p "$BACKUP_DIR" || exit 1

temp_file=""
trap '[ -n "$temp_file" ] && [ -f "$temp_file" ] && rm -f -- "$temp_file"' EXIT INT TERM HUP

log_message() {
    printf "%s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

restore_metadata() {
    target_file="$1"

    current_perms=$(stat -c '%a' "$target_file") || return 1
    current_uid=$(stat -c '%u' "$target_file") || return 1
    current_gid=$(stat -c '%g' "$target_file") || return 1
    current_user=$(stat -c '%U' "$target_file") || return 1
    current_group=$(stat -c '%G' "$target_file") || return 1

    if [ "$current_perms" != "$ORIGINAL_PERMS" ]; then
        log_message "Permissions changed: $current_perms -> $ORIGINAL_PERMS. Restoring..."
        chmod "$ORIGINAL_PERMS" "$target_file" || return 1
    fi

    if [ "$current_uid" != "$ORIGINAL_UID" ] || [ "$current_gid" != "$ORIGINAL_GID" ]; then
        if [ "$current_uid" != "$ORIGINAL_UID" ]; then
            log_message "Owner changed: $current_user($current_uid) -> $ORIGINAL_USER($ORIGINAL_UID). Restoring..."
        fi
        if [ "$current_gid" != "$ORIGINAL_GID" ]; then
            log_message "Group changed: $current_group($current_gid) -> $ORIGINAL_GROUP($ORIGINAL_GID). Restoring..."
        fi
        chown "$ORIGINAL_UID:$ORIGINAL_GID" "$target_file" || return 1
    fi

    return 0
}

restore_backup() {
    if cp -p "$backup_file" "$CONFIG_FILE"; then
        if ! restore_metadata "$CONFIG_FILE"; then
            log_message "WARNING: Backup restored, but failed to restore metadata to original values."
        fi
        return 0
    fi
    return 1
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

if ! ORIGINAL_PERMS=$(stat -c '%a' "$CONFIG_FILE"); then
    log_message "ERROR: Failed to read original config permissions from $CONFIG_FILE"
    exit 1
fi

if ! ORIGINAL_UID=$(stat -c '%u' "$CONFIG_FILE"); then
    log_message "ERROR: Failed to read original config owner UID from $CONFIG_FILE"
    exit 1
fi

if ! ORIGINAL_GID=$(stat -c '%g' "$CONFIG_FILE"); then
    log_message "ERROR: Failed to read original config group GID from $CONFIG_FILE"
    exit 1
fi

if ! ORIGINAL_USER=$(stat -c '%U' "$CONFIG_FILE"); then
    log_message "ERROR: Failed to read original config owner name from $CONFIG_FILE"
    exit 1
fi

if ! ORIGINAL_GROUP=$(stat -c '%G' "$CONFIG_FILE"); then
    log_message "ERROR: Failed to read original config group name from $CONFIG_FILE"
    exit 1
fi

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
    log_message "IPv6 prefixes unchanged."
    log_message "Global prefix: $CURRENT_GLOBAL"
    log_message "ULA prefix: $CURRENT_ULA"
    exit 0
fi

log_message "IPv6 prefix change detected."
if [ "$CURRENT_GLOBAL" != "$CONFIG_GLOBAL" ]; then
    log_message "Global prefix: $CONFIG_GLOBAL -> $CURRENT_GLOBAL"
else
    log_message "Global prefix unchanged: $CURRENT_GLOBAL"
fi

if [ "$CURRENT_ULA" != "$CONFIG_ULA" ]; then
    log_message "ULA prefix: $CONFIG_ULA -> $CURRENT_ULA"
else
    log_message "ULA prefix unchanged: $CURRENT_ULA"
fi

backup_file="$BACKUP_DIR/${CONFIG_FILENAME}.$(date +%Y%m%d-%H%M%S)"
cp -p "$CONFIG_FILE" "$backup_file" || {
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

sed -i "s|$CONFIG_GLOBAL:\([0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*\)|$CURRENT_GLOBAL:\1|g" "$temp_file"
sed -i "s|$CONFIG_ULA:\([0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F]*\)|$CURRENT_ULA:\1|g" "$temp_file"

if ! update_config_header "$temp_file"; then
    log_message "ERROR: Failed to update config header. Restoring backup..."
    rm -f "$temp_file"
    restore_backup || log_message "ERROR: Failed to restore backup."
    exit 1
fi

if ! mv "$temp_file" "$CONFIG_FILE"; then
    log_message "ERROR: Failed to write config file. Restoring backup..."
    rm -f "$temp_file"
    restore_backup || log_message "ERROR: Failed to restore backup."
    exit 1
fi

if ! restore_metadata "$CONFIG_FILE"; then
    log_message "ERROR: Failed to restore config metadata. Restoring backup..."
    restore_backup || log_message "ERROR: Failed to restore backup."
    exit 1
fi

if checkconf_output=$(unbound-checkconf 2>&1); then
    log_message "Config validated successfully. Restarting Unbound..."
    if systemctl restart unbound; then
        log_message "Unbound restarted successfully."
        find "$BACKUP_DIR" -name "${CONFIG_FILENAME}.*" -type f -printf '%T@ %p\n' | \
            sort -rn | tail -n +11 | cut -d' ' -f2- | xargs -r rm --
        exit 0
    else
        log_message "ERROR: Failed to restart Unbound. Restoring backup..."
        restore_backup || log_message "ERROR: Failed to restore backup."
        exit 1
    fi
else
    log_message "ERROR: Config validation failed. Restoring backup..."
    printf "%s\n" "$checkconf_output" | while IFS= read -r line; do
        log_message "  $line"
    done
    restore_backup || log_message "ERROR: Failed to restore backup."
    exit 1
fi
