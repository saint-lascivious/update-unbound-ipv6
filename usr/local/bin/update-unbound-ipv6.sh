#!/bin/sh
#
# update-unbound-ipv6
#
# ==============================================================================
# Purpose: Detects IPv6 prefix changes and rewrites local Unbound config.
# Author: saint-lascivious (Hayden Pearce)
# Version: 0.0.0
# Copyright: (C) 2026 Hayden Pearce. All rights reserved.
#
# Summary:
#   - Reads current global, ULA, and link-local IPv6 prefixes from an interface.
#   - Reads existing prefixes from Unbound config fragment.
#   - Rewrites matching IPv6 addresses when prefix changes.
#   - Maintains config header metadata.
#   - Validates config and reloads/restarts Unbound.
#   - Keeps rolling backups.
#   - Writes run status to plaintext + JSON state files.
#
# Environment variables:
#   CONFIG_FILE         Path to target Unbound config fragment.
#                       Default: /etc/unbound/unbound.conf.d/local-domains.conf
#   INTERFACE           Network interface to inspect.
#                       Default: eth0
#   BACKUP_DIR          Backup directory.
#                       Default: /var/backups/update-unbound-ipv6
#   NUM_BACKUPS         Number of backups to retain.
#                       Default: 10
#   VERBOSITY           Log level threshold (0-4).
#                       0=CRITICAL, 1=ERROR, 2=WARNING, 3=INFO, 4=DEBUG
#                       Default: 1 (ERROR)
#   LOG_TO_SYSLOG       1 = also send logs to syslog via logger.
#                       Default: 0 (disabled)
#   LOG_TAG             Log tag for external log integrations.
#                       Default: update-unbound-ipv6
#   STATUS_TXT_ENABLED  1 = write plaintext status file.
#                       Default: 0 (disabled)
#   STATUS_DIR          Status output directory (plaintext status file).
#                       Default: /var/lib/update-unbound-ipv6
#   STATUS_TXT          Plaintext status file path.
#                       Default: $STATUS_DIR/status.txt
#   STATUS_JSON_ENABLED 1 = write JSON status file.
#                       Default: 0 (disabled)
#   WEBROOT_DIR         Webroot directory for hosted JSON status.
#                       Default: /var/www/html
#   STATUS_JSON         JSON status file path (hosted by default).
#                       Default: $WEBROOT_DIR/update-unbound-ipv6-status.json
#   DRY_RUN             1 = no writes, no service actions; log only.
#                       Default: 0 (disabled)
#   LOCK_DIR            Lock directory for overlap prevention.
#                       Default: /var/lock/update-unbound-ipv6.lock
#
# Address type classification:
#   Global unicast : Everything IPv6 shaped that is not ULA or link-local.
#                      Note: this is a heuristic based on the first hextet,
#                      not a full IANA address registry lookup or anything
#                      like that.
#                      It should be sufficient for typical home network use
#                      cases where the global prefix is expected to be a
#                      single /64 from a provider-assigned block.
#                      Probably.
#                      The main goal is just to distinguish it from ULA and 
#                      link-local addresses that may also be present.
#   ULA            : fc00::/7  - First hextet 0xfc00-0xfdff (64512-65023).
#   Link-local     : fe80::/10 - First hextet 0xfe80-0xfebf (65152-65215).
#
# Requirements:
#   - Linux host with:
#     unbound
#     systemd
#     iproute2 (ip)
#     Standard POSIX tools (sh, awk, sed, grep, cut, mktemp, etc.)
#     Root privileges for install and service management
#
# License:
#   GNU General Public License v3.0 or any later version.
#
# Project files:
#   update-unbound-ipv6.sh → Main POSIX sh update script.
#   update-unbound-ipv6.service → One-shot systemd unit.
#   update-unbound-ipv6.timer → Periodic scheduler.
#   local-domains.conf → Example Unbound config fragment.
# ==============================================================================

CONFIG_FILE="${CONFIG_FILE:-/etc/unbound/unbound.conf.d/local-domains.conf}"
INTERFACE="${INTERFACE:-eth0}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/update-unbound-ipv6}"
NUM_BACKUPS="${NUM_BACKUPS:-10}"
DRY_RUN="${DRY_RUN:-0}"
LOCK_DIR="${LOCK_DIR:-/var/lock/update-unbound-ipv6.lock}"
export LOG_TAG="${LOG_TAG:-update-unbound-ipv6}"
LOG_TO_SYSLOG="${LOG_TO_SYSLOG:-0}"
VERBOSITY="${VERBOSITY:-1}"

WEBROOT_DIR="${WEBROOT_DIR:-/var/www/html}"
STATUS_DIR="${STATUS_DIR:-/var/lib/update-unbound-ipv6}"
STATUS_TXT="${STATUS_TXT:-$STATUS_DIR/status.txt}"
STATUS_JSON="${STATUS_JSON:-$WEBROOT_DIR/update-unbound-ipv6-status.json}"
STATUS_TXT_ENABLED="${STATUS_TXT_ENABLED:-0}"
STATUS_JSON_ENABLED="${STATUS_JSON_ENABLED:-0}"

STATUS_JSON_DIR="${STATUS_JSON%/*}"
[ "$STATUS_JSON_DIR" = "$STATUS_JSON" ] && STATUS_JSON_DIR="."

CONFIG_FILENAME=$(basename "$CONFIG_FILE")

TEMP_FILE=""
BACKUP_FILE=""
LOCK_HELD=0

CURRENT_GLOBAL=""
CURRENT_ULA=""
CURRENT_LL=""
CONFIG_GLOBAL=""
CONFIG_ULA=""
CONFIG_LL=""

trap '[ -n "${TEMP_FILE:-}" ] && [ -f "$TEMP_FILE" ] && rm -f -- "$TEMP_FILE"; \
if [ "${LOCK_HELD:-0}" -eq 1 ] && [ -d "$LOCK_DIR" ]; then rm -rf -- "$LOCK_DIR"; fi' EXIT INT TERM HUP

###############################################################################
# Function    : log_message
# Purpose     : Print timestamped log line and optionally send to syslog.
# Arguments   : $1 level (0-4), $2.. message
#               0=CRITICAL, 1=ERROR, 2=WARNING, 3=INFO, 4=DEBUG
#               Output only when level <= VERBOSITY.
#               Fallback: if $1 is not 0-4, logs as UNKNOWN at debug level
#               and treats $1 as part of the message text.
# Returns     : 0
###############################################################################
log_message() {
    level="$1"
    shift || true

    case "$level" in
        0) level_num=0; lvl="CRITICAL"; prio="user.crit" ;;
        1) level_num=1; lvl="ERROR";    prio="user.err" ;;
        2) level_num=2; lvl="WARNING";  prio="user.warning" ;;
        3) level_num=3; lvl="INFO";     prio="user.info" ;;
        4) level_num=4; lvl="DEBUG";    prio="user.debug" ;;
        *) level_num=4; lvl="UNKNOWN"; prio="user.debug";
           set -- "$level" "$@" ;;
    esac

    v="$VERBOSITY"
    case "$v" in
        ''|*[!0-9]*) v=2 ;;
    esac
    [ "$v" -lt 0 ] && v=0
    [ "$v" -gt 4 ] && v=4

    [ "$level_num" -le "$v" ] || return 0

    msg="$*"
    printf "%s [%s]: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$lvl" "$msg"

    if [ "$LOG_TO_SYSLOG" = "1" ] && command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" -p "$prio" -- "$msg" || true
    fi
}

###############################################################################
# Function    : json_escape
# Purpose     : Escape string for JSON value output.
# Arguments   : $1 text
# Returns     : escaped text on stdout
###############################################################################
json_escape() {
    printf '%s' "$1" | \
        LC_ALL=C tr -d '\000-\010\013\014\016-\037' | \
        sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g;s/\r/\\r/g;s/\n/\\n/g'
}

###############################################################################
# Function    : write_status
# Purpose     : Write plaintext + JSON state files atomically.
# Arguments   : $1 result (ok|warn|error), $2 message
# Returns     : 0 on success, 1 on failure
###############################################################################
write_status() {
    status_result="$1"
    status_message="$2"
    ts_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [ "$STATUS_TXT_ENABLED" = "1" ]; then
        mkdir -p "$STATUS_DIR" || return 1

        tmp_txt=$(mktemp "$STATUS_DIR/.status.txt.XXXXXX") || return 1

        {
            printf "timestamp=%s\n" "$ts_utc"
            printf "result=%s\n" "$status_result"
            printf "interface=%s\n" "$INTERFACE"
            printf "config_file=%s\n" "$CONFIG_FILE"
            printf "current_global=%s\n" "${CURRENT_GLOBAL:-}"
            printf "current_ula=%s\n" "${CURRENT_ULA:-}"
            printf "current_ll=%s\n" "${CURRENT_LL:-}"
            printf "config_global=%s\n" "${CONFIG_GLOBAL:-}"
            printf "config_ula=%s\n" "${CONFIG_ULA:-}"
            printf "config_ll=%s\n" "${CONFIG_LL:-}"
            printf "message=%s\n" "$status_message"
        } > "$tmp_txt" || {
            rm -f -- "$tmp_txt"
            return 1
        }

        mv -- "$tmp_txt" "$STATUS_TXT" || {
            rm -f -- "$tmp_txt"
            return 1
        }
    fi

    if [ "$STATUS_JSON_ENABLED" = "1" ]; then
        mkdir -p "$STATUS_JSON_DIR" || return 1

        tmp_json=$(mktemp "$STATUS_JSON_DIR/.status.json.XXXXXX") || return 1

        j_result=$(json_escape "$status_result")
        j_interface=$(json_escape "$INTERFACE")
        j_config_file=$(json_escape "$CONFIG_FILE")
        j_current_global=$(json_escape "${CURRENT_GLOBAL:-}")
        j_current_ula=$(json_escape "${CURRENT_ULA:-}")
        j_current_ll=$(json_escape "${CURRENT_LL:-}")
        j_config_global=$(json_escape "${CONFIG_GLOBAL:-}")
        j_config_ula=$(json_escape "${CONFIG_ULA:-}")
        j_config_ll=$(json_escape "${CONFIG_LL:-}")
        j_message=$(json_escape "$status_message")

        {
            printf '{'
            printf '"timestamp":"%s",' "$ts_utc"
            printf '"result":"%s",' "$j_result"
            printf '"interface":"%s",' "$j_interface"
            printf '"config_file":"%s",' "$j_config_file"
            printf '"current_global":"%s",' "$j_current_global"
            printf '"current_ula":"%s",' "$j_current_ula"
            printf '"current_ll":"%s",' "$j_current_ll"
            printf '"config_global":"%s",' "$j_config_global"
            printf '"config_ula":"%s",' "$j_config_ula"
            printf '"config_ll":"%s",' "$j_config_ll"
            printf '"message":"%s"' "$j_message"
            printf '}\n'
        } > "$tmp_json" || {
            rm -f -- "$tmp_json"
            return 1
        }

        mv -- "$tmp_json" "$STATUS_JSON" || {
            rm -f -- "$tmp_json"
            return 1
        }
    fi

    return 0
}

###############################################################################
# Function    : exit_with_status
# Purpose     : Write status then exit.
# Arguments   : $1 result, $2 message, $3 exit code
# Returns     : none
###############################################################################
exit_with_status() {
    status_result="$1"
    status_message="$2"
    status_code="$3"

    write_status "$status_result" "$status_message" || true
    exit "$status_code"
}

###############################################################################
# Function    : check_required_commands
# Purpose     : Verify required external commands exist.
# Arguments   : none
# Returns     : 0 on success, 1 on missing dependency
###############################################################################
check_required_commands() {
    missing=0
    for cmd in awk basename cat chmod chown cp cut date find grep head ip mktemp mv sed sort stat systemctl tail tr unbound unbound-checkconf xargs; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message 1 "Required command not found $cmd"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

###############################################################################
# Function    : acquire_lock
# Purpose     : Prevent overlapping runs.
# Arguments   : none
# Returns     : 0 on success, 1 if lock already exists
###############################################################################
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf "%s\n" "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi

    if [ -f "$LOCK_DIR/pid" ]; then
        lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        log_message 1 "Another run appears active (pid: ${lock_pid:-unknown})."
    else
        log_message 1 "Another run appears active (lock exists: $LOCK_DIR)."
    fi
    return 1
}

###############################################################################
# Function    : restore_metadata
# Purpose     : Restore mode/owner/group to captured original values.
# Arguments   : $1 target file
# Returns     : 0 on success, 1 on failure
###############################################################################
restore_metadata() {
    target_file="$1"

    current_perms=$(stat -c '%a' "$target_file") || return 1
    current_uid=$(stat -c '%u' "$target_file") || return 1
    current_gid=$(stat -c '%g' "$target_file") || return 1
    current_user=$(stat -c '%U' "$target_file") || return 1
    current_group=$(stat -c '%G' "$target_file") || return 1

    if [ "$current_perms" != "$ORIGINAL_PERMS" ]; then
        log_message 3 "Permissions changed $current_perms -> $ORIGINAL_PERMS. Restoring..."
        chmod "$ORIGINAL_PERMS" "$target_file" || return 1
    fi

    if [ "$current_uid" != "$ORIGINAL_UID" ] || [ "$current_gid" != "$ORIGINAL_GID" ]; then
        if [ "$current_uid" != "$ORIGINAL_UID" ]; then
            log_message 3 "Owner changed $current_user($current_uid) -> $ORIGINAL_USER($ORIGINAL_UID). Restoring..."
        fi
        if [ "$current_gid" != "$ORIGINAL_GID" ]; then
            log_message 3 "Group changed $current_group($current_gid) -> $ORIGINAL_GROUP($ORIGINAL_GID). Restoring..."
        fi
        chown "$ORIGINAL_UID:$ORIGINAL_GID" "$target_file" || return 1
    fi

    return 0
}

###############################################################################
# Function    : restore_backup
# Purpose     : Restore CONFIG_FILE from BACKUP_FILE and normalize metadata.
# Arguments   : none (uses BACKUP_FILE, CONFIG_FILE)
# Returns     : 0 on success, 1 on failure
###############################################################################
restore_backup() {
    if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
        log_message 1 "No backup file available to restore."
        return 1
    fi

    if cp -p "$BACKUP_FILE" "$CONFIG_FILE"; then
        if ! restore_metadata "$CONFIG_FILE"; then
            log_message 2 "Backup restored, but failed to restore metadata."
        fi
        return 0
    fi
    return 1
}

###############################################################################
# Function    : update_config_header
# Purpose     : Insert/update script-managed header, edit timestamp, and
#               optional last known good backup path.
# Arguments   : $1 config file path, $2 backup file path (optional)
# Returns     : 0 on success, 1 on failure
###############################################################################
update_config_header() {
    config_file="$1"
    backup_file="$2"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    header_tmp=$(mktemp "${config_file}.hdr.XXXXXX") || return 1

    awk -v ts="$timestamp" -v bkp="$backup_file" '
        BEGIN {
            print "# Last edited by: update-unbound-ipv6.sh"
            print "# Last edit time: " ts
            if (bkp != "") print "# Last known good backup: " bkp
            print "# This file is automatically maintained for IPv6 prefix updates"
            print "#"
        }

        NR == 1 && $0 == "# Last edited by: update-unbound-ipv6.sh" {
            managed_header=1
            next
        }

        managed_header {
            if ($0 ~ /^# Last edit time: /) next
            if ($0 ~ /^# Last known good backup: /) next
            if ($0 == "# This file is automatically maintained for IPv6 prefix updates") next
            if ($0 == "#") next
            managed_header=0
        }

        { print }
    ' "$config_file" > "$header_tmp" || {
        rm -f -- "$header_tmp"
        return 1
    }

    mv -- "$header_tmp" "$config_file" || {
        rm -f -- "$header_tmp"
        return 1
    }
}

###############################################################################
# Function    : ipv6_to_prefix4
# Purpose     : Convert IPv6 (compressed/expanded) to canonical /64 prefix
#               (first 4 hextets, zero-padded lowercase).
# Arguments   : $1 IPv6 address (no CIDR suffix)
# Returns     : prefix on stdout, empty on parse failure
###############################################################################
ipv6_to_prefix4() {
    printf "%s\n" "$1" | awk '
        function pad4(h) {
            h=tolower(h)
            while (length(h) < 4) h="0" h
            return h
        }
        function expand_ipv6(addr,   n, leftn, rightn, miss, i, j, k, out, left, right, parts) {
            if (addr !~ /:/) return ""
            if (addr ~ /:::/) return ""

            n=split(addr, parts, "::")
            if (n > 2) return ""

            leftn=0; rightn=0
            if (parts[1] != "") leftn=split(parts[1], left, ":")
            if (n == 2 && parts[2] != "") rightn=split(parts[2], right, ":")

            for (i=1; i<=leftn; i++) if (left[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?$/) return ""
            for (i=1; i<=rightn; i++) if (right[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?$/) return ""

            if (n == 1) {
                if (leftn != 8) return ""
                miss=0
            } else {
                miss=8-leftn-rightn
                if (miss < 1) return ""
            }

            k=0
            for (i=1; i<=leftn; i++) out[++k]=pad4(left[i])
            for (j=1; j<=miss; j++) out[++k]="0000"
            for (i=1; i<=rightn; i++) out[++k]=pad4(right[i])

            if (k != 8) return ""
            return out[1] ":" out[2] ":" out[3] ":" out[4] ":" out[5] ":" out[6] ":" out[7] ":" out[8]
        }
        {
            expanded=expand_ipv6($0)
            if (expanded != "") {
                split(expanded, a, ":")
                print a[1] ":" a[2] ":" a[3] ":" a[4]
            }
        }
    '
}

###############################################################################
# Function    : get_current_ipv6
# Purpose     : Get global, ULA (fc00::/7), and link-local (fe80::/10) /64
#               prefixes from INTERFACE.
#               GLOBAL : everything not ULA or link-local
#               ULA    : fc00::/7  — first hextet 0xfc00-0xfdff (64512-65023)
#               LL     : fe80::/10 — first hextet 0xfe80-0xfebf (65152-65215)
# Arguments   : none
# Returns     : "<global_prefix>|<ula_prefix>|<ll_prefix>"
###############################################################################
get_current_ipv6() {
    global_addr=$(ip -6 -o addr show dev "$INTERFACE" scope global 2>/dev/null | \
        awk '
            $3=="inet6" {
                addr=tolower($4); sub(/\/.*/, "", addr)
                n=split(addr, p, ":")
                if (n < 1) next
                h=p[1]; val=0
                for (i=1; i<=length(h); i++) {
                    c=substr(h,i,1)
                    if (c>="0"&&c<="9") d=c+0
                    else if (c>="a"&&c<="f") d=index("abcdef",c)+9
                    else { val=-1; break }
                    val=val*16+d
                }
                if (val>=64512&&val<=65023) next
                if (val>=65152&&val<=65215) next
                print $4; exit
            }
        ')

    ula_addr=$(ip -6 -o addr show dev "$INTERFACE" scope global 2>/dev/null | \
        awk '
            $3=="inet6" {
                addr=tolower($4); sub(/\/.*/, "", addr)
                n=split(addr, p, ":")
                if (n < 1) next
                h=p[1]; val=0
                for (i=1; i<=length(h); i++) {
                    c=substr(h,i,1)
                    if (c>="0"&&c<="9") d=c+0
                    else if (c>="a"&&c<="f") d=index("abcdef",c)+9
                    else { val=-1; break }
                    val=val*16+d
                }
                if (val>=64512&&val<=65023) { print $4; exit }
            }
        ')

    ll_addr=$(ip -6 -o addr show dev "$INTERFACE" scope link 2>/dev/null | \
        awk '
            $3=="inet6" {
                addr=tolower($4); sub(/\/.*/, "", addr)
                n=split(addr, p, ":")
                if (n < 1) next
                h=p[1]; val=0
                for (i=1; i<=length(h); i++) {
                    c=substr(h,i,1)
                    if (c>="0"&&c<="9") d=c+0
                    else if (c>="a"&&c<="f") d=index("abcdef",c)+9
                    else { val=-1; break }
                    val=val*16+d
                }
                if (val>=65152&&val<=65215) { print $4; exit }
            }
        ')

    global_addr=${global_addr%%/*}
    ula_addr=${ula_addr%%/*}
    ll_addr=${ll_addr%%/*}

    global_prefix=$(ipv6_to_prefix4 "$global_addr")
    ula_prefix=$(ipv6_to_prefix4 "$ula_addr")
    ll_prefix=$(ipv6_to_prefix4 "$ll_addr")

    printf "%s|%s|%s\n" "$global_prefix" "$ula_prefix" "$ll_prefix"
}

###############################################################################
# Function    : get_config_prefixes
# Purpose     : Get global, ULA (fc00::/7), and link-local (fe80::/10) /64
#               prefixes from CONFIG_FILE.
#               Supports compressed IPv6 tokens.
#               GLOBAL : everything not ULA or link-local
#               ULA    : fc00::/7  — first hextet 0xfc00-0xfdff (64512-65023)
#               LL     : fe80::/10 — first hextet 0xfe80-0xfebf (65152-65215)
# Arguments   : none
# Returns     : "<global_prefix>|<ula_prefix>|<ll_prefix>"
###############################################################################
get_config_prefixes() {
    awk '
        function pad4(h) {
            h=tolower(h)
            while (length(h) < 4) h="0" h
            return h
        }
        function expand_ipv6(addr,   n, leftn, rightn, miss, i, j, k, out, left, right, parts) {
            if (addr !~ /:/) return ""
            if (addr ~ /:::/) return ""
            n=split(addr, parts, "::")
            if (n > 2) return ""

            leftn=0; rightn=0
            if (parts[1] != "") leftn=split(parts[1], left, ":")
            if (n == 2 && parts[2] != "") rightn=split(parts[2], right, ":")

            for (i=1; i<=leftn; i++) if (left[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?$/) return ""
            for (i=1; i<=rightn; i++) if (right[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?$/) return ""

            if (n == 1) {
                if (leftn != 8) return ""
                miss=0
            } else {
                miss=8-leftn-rightn
                if (miss < 1) return ""
            }

            k=0
            for (i=1; i<=leftn; i++) out[++k]=pad4(left[i])
            for (j=1; j<=miss; j++) out[++k]="0000"
            for (i=1; i<=rightn; i++) out[++k]=pad4(right[i])

            if (k != 8) return ""
            return out[1] ":" out[2] ":" out[3] ":" out[4] ":" out[5] ":" out[6] ":" out[7] ":" out[8]
        }
        function prefix4(expanded,   a) {
            split(expanded, a, ":")
            return a[1] ":" a[2] ":" a[3] ":" a[4]
        }
        function classify(p,   first, val, i, c, d, n, parts) {
            n=split(tolower(p), parts, ":")
            if (n < 1) return "global"
            first=parts[1]; val=0
            for (i=1; i<=length(first); i++) {
                c=substr(first,i,1)
                if (c>="0"&&c<="9") d=c+0
                else if (c>="a"&&c<="f") d=index("abcdef",c)+9
                else return "global"
                val=val*16+d
            }
            if (val>=64512&&val<=65023) return "ula"
            if (val>=65152&&val<=65215) return "ll"
            return "global"
        }
        BEGIN { g=""; u=""; l="" }
        {
            line=$0
            while (match(line, /[0-9A-Fa-f:]{2,}/)) {
                tok=substr(line, RSTART, RLENGTH)
                expanded=expand_ipv6(tok)
                if (expanded != "") {
                    p=prefix4(expanded)
                    t=classify(p)
                    if      (t=="ula"    && u=="") u=p
                    else if (t=="ll"     && l=="") l=p
                    else if (t=="global" && g=="") g=p
                }
                line=substr(line, RSTART + RLENGTH)
            }
        }
        END { print g "|" u "|" l }
    ' "$CONFIG_FILE"
}

###############################################################################
# Function    : rewrite_config_prefixes
# Purpose     : Rewrite matching IPv6 addresses from old prefixes to new.
#               Supports compressed and expanded addresses in config.
#               Only rewrites a prefix type when both old and new are non-empty.
# Arguments   : $1 source file, $2 destination file,
#               $3 old global prefix, $4 new global prefix,
#               $5 old ula prefix,    $6 new ula prefix,
#               $7 old ll prefix,     $8 new ll prefix
# Returns     : 0 on success, 1 on failure
###############################################################################
rewrite_config_prefixes() {
    src="$1"
    dst="$2"
    oldg="$3"
    newg="$4"
    oldu="$5"
    newu="$6"
    oldl="$7"
    newl="$8"

    awk -v oldg="$oldg" -v newg="$newg" \
        -v oldu="$oldu" -v newu="$newu" \
        -v oldl="$oldl" -v newl="$newl" '
        function pad4(h) {
            h=tolower(h)
            while (length(h) < 4) h="0" h
            return h
        }
        function expand_ipv6(addr,   n, leftn, rightn, miss, i, j, k, out, left, right, parts) {
            if (addr !~ /:/) return ""
            if (addr ~ /:::/) return ""
            n=split(addr, parts, "::")
            if (n > 2) return ""

            leftn=0; rightn=0
            if (parts[1] != "") leftn=split(parts[1], left, ":")
            if (n == 2 && parts[2] != "") rightn=split(parts[2], right, ":")

            for (i=1; i<=leftn; i++) if (left[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?$/) return ""
            for (i=1; i<=rightn; i++) if (right[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]?[0-9A-Fa-f]?[0-9A-Fa-f]?$/) return ""

            if (n == 1) {
                if (leftn != 8) return ""
                miss=0
            } else {
                miss=8-leftn-rightn
                if (miss < 1) return ""
            }

            k=0
            for (i=1; i<=leftn; i++) out[++k]=pad4(left[i])
            for (j=1; j<=miss; j++) out[++k]="0000"
            for (i=1; i<=rightn; i++) out[++k]=pad4(right[i])

            if (k != 8) return ""
            return out[1] ":" out[2] ":" out[3] ":" out[4] ":" out[5] ":" out[6] ":" out[7] ":" out[8]
        }
        function prefix4(expanded,   a) {
            split(expanded, a, ":")
            return a[1] ":" a[2] ":" a[3] ":" a[4]
        }
        {
            line=$0
            out=""
            while (match(line, /[0-9A-Fa-f:]{2,}/)) {
                pre=substr(line, 1, RSTART - 1)
                tok=substr(line, RSTART, RLENGTH)
                expanded=expand_ipv6(tok)
                repl=tok

                if (expanded != "") {
                    p=prefix4(expanded)
                    split(expanded, a, ":")
                    if      (oldg != "" && p == oldg) repl=newg ":" a[5] ":" a[6] ":" a[7] ":" a[8]
                    else if (oldu != "" && p == oldu) repl=newu ":" a[5] ":" a[6] ":" a[7] ":" a[8]
                    else if (oldl != "" && p == oldl) repl=newl ":" a[5] ":" a[6] ":" a[7] ":" a[8]
                }

                out=out pre repl
                line=substr(line, RSTART + RLENGTH)
            }
            print out line
        }
    ' "$src" > "$dst"
}

###############################################################################
# Function    : prune_backups
# Purpose     : Keep most recent NUM_BACKUPS backups for this config file.
# Arguments   : none
# Returns     : 0
###############################################################################
prune_backups() {
    start=$((NUM_BACKUPS + 1))
    find "$BACKUP_DIR" -name "${CONFIG_FILENAME}.*" -type f -printf '%T@ %p\n' | \
        sort -rn | tail -n +"$start" | cut -d' ' -f2- | xargs -r rm --
}

###############################################################################
# Function    : reload_or_restart_unbound
# Purpose     : Reload first; fallback to restart if reload fails.
# Arguments   : none
# Returns     : 0 on success, 1 on failure
###############################################################################
reload_or_restart_unbound() {
    if systemctl reload unbound; then
        log_message 3 "Unbound reloaded successfully."
        return 0
    fi

    log_message 2 "Reload failed; attempting restart..."
    if systemctl restart unbound; then
        log_message 3 "Unbound restarted successfully."
        return 0
    fi

    return 1
}

# ---- Startup checks ----------------------------------------------------------

if ! check_required_commands; then
    exit_with_status "error" "required command check failed" 1
fi

if ! acquire_lock; then
    exit_with_status "error" "another run appears active" 1
fi

mkdir -p "$BACKUP_DIR" || {
    log_message 1 "Failed to create backup directory $BACKUP_DIR"
    exit_with_status "error" "failed to create backup directory" 1
}

case "$NUM_BACKUPS" in
    ''|*[!0-9]*|0)
        log_message 1 "NUM_BACKUPS must be a positive integer; got $NUM_BACKUPS"
        exit_with_status "error" "invalid NUM_BACKUPS value" 1
        ;;
esac

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    log_message 1 "Interface $INTERFACE not found"
    exit_with_status "error" "interface not found" 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    log_message 1 "Config file $CONFIG_FILE not found"
    exit_with_status "error" "config file not found" 1
fi

if ! ORIGINAL_PERMS=$(stat -c '%a' "$CONFIG_FILE"); then
    log_message 1 "Failed to read original config permissions."
    exit_with_status "error" "failed to read original config permissions" 1
fi

if ! ORIGINAL_UID=$(stat -c '%u' "$CONFIG_FILE"); then
    log_message 1 "Failed to read original config owner UID."
    exit_with_status "error" "failed to read original config owner uid" 1
fi

if ! ORIGINAL_GID=$(stat -c '%g' "$CONFIG_FILE"); then
    log_message 1 "Failed to read original config group GID."
    exit_with_status "error" "failed to read original config group gid" 1
fi

if ! ORIGINAL_USER=$(stat -c '%U' "$CONFIG_FILE"); then
    log_message 1 "Failed to read original config owner name."
    exit_with_status "error" "failed to read original config owner name" 1
fi

if ! ORIGINAL_GROUP=$(stat -c '%G' "$CONFIG_FILE"); then
    log_message 1 "Failed to read original config group name."
    exit_with_status "error" "failed to read original config group name" 1
fi

# ---- Prefix discovery --------------------------------------------------------

CURRENT_PREFIXES=$(get_current_ipv6)
CURRENT_GLOBAL=$(printf "%s" "$CURRENT_PREFIXES" | cut -d'|' -f1)
CURRENT_ULA=$(printf "%s" "$CURRENT_PREFIXES" | cut -d'|' -f2)
CURRENT_LL=$(printf "%s" "$CURRENT_PREFIXES" | cut -d'|' -f3)

if [ -z "$CURRENT_GLOBAL" ] && [ -z "$CURRENT_ULA" ] && [ -z "$CURRENT_LL" ]; then
    log_message 2 "Could not detect any IPv6 prefixes on $INTERFACE"
    exit_with_status "warn" "could not detect any IPv6 prefixes on interface" 0
fi

CONFIG_PREFIXES=$(get_config_prefixes)
CONFIG_GLOBAL=$(printf "%s" "$CONFIG_PREFIXES" | cut -d'|' -f1)
CONFIG_ULA=$(printf "%s" "$CONFIG_PREFIXES" | cut -d'|' -f2)
CONFIG_LL=$(printf "%s" "$CONFIG_PREFIXES" | cut -d'|' -f3)

if [ -z "$CONFIG_GLOBAL" ] && [ -z "$CONFIG_ULA" ] && [ -z "$CONFIG_LL" ]; then
    log_message 1 "Could not extract any IPv6 prefixes from $CONFIG_FILE"
    exit_with_status "error" "could not extract any IPv6 prefixes from config file" 1
fi

GLOBAL_CHANGED=0
ULA_CHANGED=0
LL_CHANGED=0

[ -n "$CURRENT_GLOBAL" ] && [ -n "$CONFIG_GLOBAL" ] && [ "$CURRENT_GLOBAL" != "$CONFIG_GLOBAL" ] && GLOBAL_CHANGED=1
[ -n "$CURRENT_ULA" ]    && [ -n "$CONFIG_ULA" ]    && [ "$CURRENT_ULA"    != "$CONFIG_ULA"    ] && ULA_CHANGED=1
[ -n "$CURRENT_LL" ]     && [ -n "$CONFIG_LL" ]     && [ "$CURRENT_LL"     != "$CONFIG_LL"     ] && LL_CHANGED=1

if [ "$GLOBAL_CHANGED" -eq 0 ] && [ "$ULA_CHANGED" -eq 0 ] && [ "$LL_CHANGED" -eq 0 ]; then
    log_message 4 "IPv6 prefixes unchanged."
    [ -n "$CURRENT_GLOBAL" ] && log_message 4 "Global prefix     $CURRENT_GLOBAL"
    [ -n "$CURRENT_ULA" ]    && log_message 4 "ULA prefix        $CURRENT_ULA"
    [ -n "$CURRENT_LL" ]     && log_message 4 "Link-local prefix $CURRENT_LL"
    exit_with_status "ok" "ipv6 prefixes unchanged" 0
fi

log_message 3 "IPv6 prefix change detected."
[ "$GLOBAL_CHANGED" -eq 1 ] && log_message 3 "Global prefix     $CONFIG_GLOBAL -> $CURRENT_GLOBAL"
[ "$ULA_CHANGED"    -eq 1 ] && log_message 3 "ULA prefix        $CONFIG_ULA -> $CURRENT_ULA"
[ "$LL_CHANGED"     -eq 1 ] && log_message 3 "Link-local prefix $CONFIG_LL -> $CURRENT_LL"

REWRITE_OLDG=""; REWRITE_NEWG=""
REWRITE_OLDU=""; REWRITE_NEWU=""
REWRITE_OLDL=""; REWRITE_NEWL=""

[ "$GLOBAL_CHANGED" -eq 1 ] && { REWRITE_OLDG="$CONFIG_GLOBAL"; REWRITE_NEWG="$CURRENT_GLOBAL"; }
[ "$ULA_CHANGED"    -eq 1 ] && { REWRITE_OLDU="$CONFIG_ULA";    REWRITE_NEWU="$CURRENT_ULA"; }
[ "$LL_CHANGED"     -eq 1 ] && { REWRITE_OLDL="$CONFIG_LL";     REWRITE_NEWL="$CURRENT_LL"; }

# ---- Build staged file -------------------------------------------------------

TEMP_FILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || {
    log_message 1 "Failed to create temp file."
    exit_with_status "error" "failed to create temp file" 1
}

if ! rewrite_config_prefixes "$CONFIG_FILE" "$TEMP_FILE" \
        "$REWRITE_OLDG" "$REWRITE_NEWG" \
        "$REWRITE_OLDU" "$REWRITE_NEWU" \
        "$REWRITE_OLDL" "$REWRITE_NEWL"; then
    log_message 1 "Failed to rewrite staged config."
    exit_with_status "error" "failed to rewrite staged config" 1
fi

if [ "$DRY_RUN" = "1" ]; then
    log_message 3 "No changes written."
    log_message 3 "Would update $CONFIG_FILE"
    [ "$GLOBAL_CHANGED" -eq 1 ] && log_message 4 "Would change global    : $CONFIG_GLOBAL -> $CURRENT_GLOBAL"
    [ "$ULA_CHANGED"    -eq 1 ] && log_message 4 "Would change ULA       : $CONFIG_ULA -> $CURRENT_ULA"
    [ "$LL_CHANGED"     -eq 1 ] && log_message 4 "Would change link-local: $CONFIG_LL -> $CURRENT_LL"
    log_message 3 "Would create backup, update header, validate config and reload/restart Unbound."
    exit_with_status "ok" "dry run complete; no changes written" 0
fi

# ---- Backup + deploy ---------------------------------------------------------

BACKUP_FILE="$BACKUP_DIR/${CONFIG_FILENAME}.$(date +%Y%m%d-%H%M%S)"
cp -p "$CONFIG_FILE" "$BACKUP_FILE" || {
    log_message 1 "Failed to create backup."
    exit_with_status "error" "failed to create backup" 1
}
log_message 3 "Backed up config to $BACKUP_FILE"

if ! update_config_header "$TEMP_FILE" "$BACKUP_FILE"; then
    log_message 1 "Failed to update config header in staged config."
    rm -f -- "$BACKUP_FILE" || true
    BACKUP_FILE=""
    exit_with_status "error" "failed to update config header in staged config" 1
fi

if ! mv "$TEMP_FILE" "$CONFIG_FILE"; then
    log_message 1 "Failed to write config file. Restoring backup..."
    if restore_backup; then
        log_message 3 "Backup restored successfully."
        exit_with_status "error" "failed to write config file; backup restored" 1
    else
        log_message 0 "Failed to write config file. Backup restore failed."
        exit_with_status "error" "failed to write config file; backup restore failed" 1
    fi
fi

if ! restore_metadata "$CONFIG_FILE"; then
    log_message 1 "Failed to restore config metadata. Restoring backup..."
    if restore_backup; then
        log_message 3 "Backup restored successfully."
        exit_with_status "error" "failed to restore metadata; backup restored" 1
    else
        log_message 0 "Failed to restore metadata. Backup restore failed."
        exit_with_status "error" "failed to restore metadata; backup restore failed" 1
    fi
fi

if checkconf_output=$(unbound-checkconf 2>&1); then
    log_message 3 "Config validated successfully."
    if reload_or_restart_unbound; then
        prune_backups
        log_message 3 "Config updated and Unbound reloaded/restarted successfully."
        exit_with_status "ok" "config updated and unbound reloaded/restarted successfully" 0
    fi

    log_message 1 "Failed to reload/restart Unbound. Restoring backup..."
    if restore_backup; then
        log_message 3 "Backup restored successfully."
        exit_with_status "error" "reload/restart failed; backup restored" 1
    else
        log_message 0 "Reload/restart failed. Backup restore failed."
        exit_with_status "error" "reload/restart failed; backup restore failed" 1
    fi
else
    log_message 1 "Config validation failed. Restoring backup..."
    printf "%s\n" "$checkconf_output" | while IFS= read -r line; do
        log_message 4 "  $line"
    done
    if restore_backup; then
        log_message 3 "Backup restored successfully."
        exit_with_status "error" "config validation failed; backup restored" 1
    else
        log_message 0 "Config validation failed. Backup restore failed."
        exit_with_status "error" "config validation failed; backup restore failed" 1
    fi
fi
