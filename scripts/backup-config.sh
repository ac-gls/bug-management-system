#!/bin/bash
# Backup configuration files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/../backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

# Backup configuration files
cp -r "$SCRIPT_DIR/../configs" "$BACKUP_DIR/configs_$DATE"

echo "Configuration backed up to $BACKUP_DIR/configs_$DATE"