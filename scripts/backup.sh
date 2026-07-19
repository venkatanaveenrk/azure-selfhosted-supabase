#!/usr/bin/env bash
# ================================================================
# backup.sh — Back up the Supabase database + storage files (v3)
# ================================================================
# Two layers of backup:
#   1. Logical:  pg_dump of the database -> compressed SQL file
#   2. Physical: Azure managed-disk snapshot (whole data disk)
#
# Run ON THE VM. Schedule via cron, e.g. daily at 02:00:
#   0 2 * * *  RESOURCE_GROUP=supabase-rg \
#              DATA_DISK_NAME=supabase-vm-data-disk \
#              /opt/supabase/scripts/backup.sh >> /var/log/supabase-backup.log 2>&1
#
# Logical backups are kept locally on the data disk (and you should
# copy them off-box — see README). Disk snapshots live in Azure and
# survive even total VM loss.
# ================================================================
set -euo pipefail

DATA_DIR="${DATA_DIR:-/mnt/supabase-data}"
BACKUP_DIR="$DATA_DIR/backups"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"

# For disk snapshots (filled in by Terraform output / env)
RESOURCE_GROUP="${RESOURCE_GROUP:-supabase-rg}"
DATA_DISK_NAME="${DATA_DISK_NAME:-supabase-vm-data-disk}"

# v3: the postgres role is NOLOGIN (placeholder for GoTrue migration).
# Use supabase_admin for actual login operations.
PG_USER="${PG_USER:-supabase_admin}"
PG_DB="${PG_DB:-postgres}"

echo "═══════════════════════════════════════════════"
echo "  Supabase Backup — $TIMESTAMP"
echo "═══════════════════════════════════════════════"

mkdir -p "$BACKUP_DIR"

# ─── 1. Logical backup — pg_dump ───
echo
echo "→ [1/2] Logical backup (pg_dump)..."
DUMP_FILE="$BACKUP_DIR/supabase-db-${TIMESTAMP}.sql.gz"

# Run pg_dump inside the db container; compress on the way out.
# --clean --if-exists makes the dump restorable onto a non-empty target.
docker exec supabase-db pg_dump -U "$PG_USER" -d "$PG_DB" --clean --if-exists \
  | gzip > "$DUMP_FILE"

DUMP_SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
echo "  ✓ database dumped: $DUMP_FILE ($DUMP_SIZE)"

# ─── 2. Physical backup — Azure disk snapshot ───
echo
echo "→ [2/2] Azure managed-disk snapshot..."
SNAPSHOT_NAME="supabase-data-snap-${TIMESTAMP}"

if command -v az >/dev/null; then
  DISK_ID="$(az disk show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$DATA_DISK_NAME" \
    --query id -o tsv 2>/dev/null || echo '')"

  if [ -n "$DISK_ID" ]; then
    az snapshot create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$SNAPSHOT_NAME" \
      --source "$DISK_ID" \
      --incremental true \
      --output none
    echo "  ✓ disk snapshot created: $SNAPSHOT_NAME (incremental)"
  else
    echo "  ⚠ could not find data disk '$DATA_DISK_NAME' — skipping snapshot"
  fi
else
  echo "  ⚠ az CLI not available — skipping disk snapshot"
fi

# ─── Prune old local dumps ───
echo
echo "→ Pruning local dumps older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name 'supabase-db-*.sql.gz' -mtime +"$RETENTION_DAYS" -delete -print \
  | sed 's/^/  removed: /' || true

# ─── Prune old snapshots ───
if command -v az >/dev/null; then
  echo "→ Pruning Azure snapshots older than ${RETENTION_DAYS} days..."
  CUTOFF="$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  if [ -n "$CUTOFF" ]; then
    az snapshot list --resource-group "$RESOURCE_GROUP" \
      --query "[?starts_with(name,'supabase-data-snap-') && timeCreated < '${CUTOFF}'].name" \
      -o tsv 2>/dev/null | while read -r old; do
        [ -n "$old" ] && az snapshot delete --resource-group "$RESOURCE_GROUP" --name "$old" --output none \
          && echo "  removed snapshot: $old"
      done || true
  fi
fi

echo
echo "═══════════════════════════════════════════════"
echo "  ✅ Backup complete — $TIMESTAMP"
echo "═══════════════════════════════════════════════"
echo "  Local dump : $DUMP_FILE"
echo "  Snapshot   : $SNAPSHOT_NAME"
echo
echo "  ⚠ Copy local dumps off the VM for true DR"
echo "    (the disk snapshot already survives VM loss)"
echo "═══════════════════════════════════════════════"
