#!/usr/bin/env bash
# ================================================================
# restore.sh — Restore the Supabase database from a backup (v3)
# ================================================================
# Restores from a pg_dump file created by backup.sh.
#
# Run ON THE VM:
#   ./restore.sh /mnt/supabase-data/backups/supabase-db-YYYYMMDD-HHMMSS.sql.gz
#
# For disk-level recovery (whole data disk from a snapshot), see the
# README section "Disaster Recovery" — that's an Azure operation,
# not a script.
#
# ⚠ This OVERWRITES the current database. Take a fresh backup first.
# ================================================================
set -euo pipefail

BACKUP_FILE="${1:-}"
PG_USER="${PG_USER:-supabase_admin}"
PG_DB="${PG_DB:-postgres}"

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo "Usage: $0 <path-to-backup.sql.gz>"
  echo
  echo "Available backups:"
  ls -lh /mnt/supabase-data/backups/supabase-db-*.sql.gz 2>/dev/null | sed 's/^/  /' || echo "  (none found)"
  exit 1
fi

echo "═══════════════════════════════════════════════"
echo "  Supabase Database Restore"
echo "═══════════════════════════════════════════════"
echo "  Backup file: $BACKUP_FILE"
echo "═══════════════════════════════════════════════"
echo
echo "  ⚠ WARNING: this OVERWRITES the current database."
read -r -p "  Type 'RESTORE' to proceed: " CONFIRM
if [ "$CONFIRM" != "RESTORE" ]; then
  echo "  Aborted."
  exit 1
fi

# ─── Safety backup of current state ───
echo
echo "→ Taking a safety backup of the CURRENT database first..."
SAFETY="/mnt/supabase-data/backups/pre-restore-$(date -u +%Y%m%d-%H%M%S).sql.gz"
docker exec supabase-db pg_dump -U "$PG_USER" -d "$PG_DB" --clean --if-exists | gzip > "$SAFETY"
echo "  ✓ safety backup: $SAFETY"

# ─── Stop dependent services (keep db running) ───
echo
echo "→ Stopping services that use the database..."
docker compose stop rest auth realtime storage meta studio kong

# ─── Restore ───
echo
echo "→ Restoring database from backup..."
gunzip -c "$BACKUP_FILE" | docker exec -i supabase-db psql -U "$PG_USER" -d "$PG_DB"
echo "  ✓ database restored"

# ─── Restart services ───
echo
echo "→ Restarting services..."
docker compose up -d

echo
echo "→ Waiting for health..."
sleep 20
docker compose ps

echo
echo "═══════════════════════════════════════════════"
echo "  ✅ Restore complete"
echo "═══════════════════════════════════════════════"
echo "  Restored from: $BACKUP_FILE"
echo "  Safety backup: $SAFETY"
echo "═══════════════════════════════════════════════"
