# RUNBOOK for update-unbound-ipv6.sh

## Quick Restore: Latest Backup + Restart Unbound

```sh
# Find newest backup file
LATEST_BACKUP="$(sudo ls -1t /var/backups/update-unbound-ipv6/local-domains.conf.* 2>/dev/null | head -n 1)"

# Stop if no backup exists
[ -n "$LATEST_BACKUP" ] || { echo "No backup found."; exit 1; }

# Restore newest backup into active Unbound config
sudo cp "$LATEST_BACKUP" local-domains.conf

# Validate config before restart
sudo unbound-checkconf || { echo "unbound-checkconf failed after restore."; exit 1; }

# Restart and verify service state
sudo systemctl restart unbound
sudo systemctl --no-pager --full status unbound
```
