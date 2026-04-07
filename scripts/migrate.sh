#!/usr/bin/env bash
set -euo pipefail

DIRECTION=${1:-up}
DB_URL=${DATABASE_URL:-"postgres://postgres:secret@localhost:5432/ecocomply?sslmode=disable"}

for svc in services/*/; do
  SVC_NAME=$(basename "$svc")
  for scope in public tenant; do
    MIGRATION_DIR="${svc}migrations/${scope}"
    if [ -d "$MIGRATION_DIR" ] && [ "$(ls -A $MIGRATION_DIR)" ]; then
      echo "→ Migrating ${SVC_NAME}/${scope} (${DIRECTION})..."
      migrate -path "$MIGRATION_DIR" -database "$DB_URL" "$DIRECTION"
    fi
  done
done
