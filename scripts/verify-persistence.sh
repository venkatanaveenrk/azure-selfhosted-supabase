#!/usr/bin/env bash
# ================================================================
# verify-persistence.sh — Prove data survives restarts (v3)
# ================================================================
# Runs the test that answers the core requirement:
#   "data must survive restarts and re-deployments"
#
# Two modes:
#
#   ./verify-persistence.sh write
#     -> writes a known marker row into the database and a marker file
#        into the storage volume. Prints the marker value.
#
#   (now reboot the VM, or: docker compose down && docker compose up -d,
#    or re-run: scripts/deploy-stack.sh)
#
#   ./verify-persistence.sh check
#     -> confirms the marker row + file are STILL there. If yes → PASS.
#
# Run ON THE VM. The script talks to the db container via `docker exec`
# and writes the storage marker by exec-ing into the storage container
# (because storage files live in a Docker named volume in v3, not under
# /mnt/supabase-data — the volume's physical path is, of course, on the
# data disk via Docker's data-root).
# ================================================================
set -euo pipefail

MODE="${1:-}"
PG_USER="${PG_USER:-supabase_admin}"
PG_DB="${PG_DB:-postgres}"

# v3 marker locations:
#  - database row:  public._persistence_test (one row per write call)
#  - storage file:  /var/lib/storage/_persistence_marker.txt  (inside storage container)
STORAGE_MARKER_PATH="/var/lib/storage/_persistence_marker.txt"

run_sql() {
  docker exec -i supabase-db psql -U "$PG_USER" -d "$PG_DB" -tA -c "$1"
}

write_storage_marker() {
  # Write inside the storage container — the file lands on the named
  # 'storage_data' volume which is the same Docker volume Storage uses.
  docker exec -i supabase-storage sh -c "echo '$1' > $STORAGE_MARKER_PATH"
}

read_storage_marker() {
  docker exec -i supabase-storage sh -c "cat $STORAGE_MARKER_PATH 2>/dev/null || true"
}

storage_marker_exists() {
  docker exec -i supabase-storage sh -c "[ -f $STORAGE_MARKER_PATH ] && echo yes || echo no"
}

case "$MODE" in
  # ────────────────────────────────────────────
  write)
    STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    MARKER="persist-check-${STAMP}"

    echo "═══════════════════════════════════════════════"
    echo "  Persistence Test — WRITE phase"
    echo "═══════════════════════════════════════════════"

    # 1. Database marker
    run_sql "CREATE TABLE IF NOT EXISTS public._persistence_test (
               id         serial PRIMARY KEY,
               marker     text,
               written_at timestamptz DEFAULT now()
             );" >/dev/null
    run_sql "INSERT INTO public._persistence_test (marker) VALUES ('${MARKER}');" >/dev/null
    echo "  ✓ wrote DB row:    marker = ${MARKER}"

    # 2. Storage marker (inside container, on named volume)
    write_storage_marker "${MARKER}"
    echo "  ✓ wrote storage:   $STORAGE_MARKER_PATH"

    echo
    echo "  MARKER = ${MARKER}"
    echo
    echo "  Now do ONE of these, then run:  $0 check"
    echo "    • Reboot the VM:          sudo reboot"
    echo "    • Restart containers:     docker compose down && docker compose up -d"
    echo "    • Redeploy the stack:     ./scripts/deploy-stack.sh"
    echo "═══════════════════════════════════════════════"

    # Save expected marker locally for cross-check
    echo "${MARKER}" > /tmp/_expected_marker.txt
    ;;

  # ────────────────────────────────────────────
  check)
    echo "═══════════════════════════════════════════════"
    echo "  Persistence Test — CHECK phase"
    echo "═══════════════════════════════════════════════"

    FAIL=0

    # 1. Database marker — read the most recent
    DB_MARKER="$(run_sql "SELECT marker FROM public._persistence_test
                          ORDER BY written_at DESC LIMIT 1;" 2>/dev/null || echo '')"
    if [ -n "$DB_MARKER" ]; then
      echo "  ✓ DB row survived:   $DB_MARKER"
    else
      echo "  ✗ DB row MISSING — data did NOT persist"
      FAIL=1
    fi

    # 2. Storage marker
    EXISTS="$(storage_marker_exists)"
    if [ "$EXISTS" = "yes" ]; then
      FILE_MARKER="$(read_storage_marker)"
      echo "  ✓ storage marker:    $FILE_MARKER"
    else
      echo "  ✗ storage file MISSING — data did NOT persist"
      FILE_MARKER=""
      FAIL=1
    fi

    # 3. Cross-check against expected (if available)
    if [ -f /tmp/_expected_marker.txt ]; then
      EXPECTED="$(cat /tmp/_expected_marker.txt)"
      if [ "$DB_MARKER" = "$EXPECTED" ] && [ "$FILE_MARKER" = "$EXPECTED" ]; then
        echo "  ✓ markers match the pre-restart value exactly"
      fi
    fi

    echo
    if [ "$FAIL" -eq 0 ]; then
      echo "═══════════════════════════════════════════════"
      echo "  ✅ PASS — data persisted across the restart"
      echo "═══════════════════════════════════════════════"
      exit 0
    else
      echo "═══════════════════════════════════════════════"
      echo "  ❌ FAIL — data was lost. Investigate:"
      echo "       • Is the data disk mounted at /mnt/supabase-data?"
      echo "       • Does Docker's data-root point there?"
      echo "         (Check: docker info | grep 'Docker Root Dir')"
      echo "         Expected: /mnt/supabase-data/docker"
      echo "═══════════════════════════════════════════════"
      exit 1
    fi
    ;;

  # ────────────────────────────────────────────
  cleanup)
    run_sql "DROP TABLE IF EXISTS public._persistence_test;" >/dev/null
    docker exec -i supabase-storage sh -c "rm -f $STORAGE_MARKER_PATH" 2>/dev/null || true
    rm -f /tmp/_expected_marker.txt
    echo "✓ persistence test artifacts removed"
    ;;

  *)
    echo "Usage: $0 {write|check|cleanup}"
    echo
    echo "  write   — write markers, then reboot/redeploy"
    echo "  check   — verify markers survived"
    echo "  cleanup — remove test artifacts"
    exit 1
    ;;
esac
