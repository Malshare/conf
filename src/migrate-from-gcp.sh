#!/usr/bin/env bash
# Migrate the malshare_db database from the GCP CloudSQL instance
# to the local dockerised MySQL service in this compose project.
#
# Run this on the Hetzner host, from /root/conf-src, AFTER:
#   1. /storage/malshare exists and is owned by root
#   2. frontend.env is populated (incl. MYSQL_ROOT_PASSWORD)
#   3. The mysql service has been started for the first time:
#        docker compose up -d mysql
#      and is reporting healthy:
#        docker compose ps mysql
#
# The script will:
#   - mysqldump the malshare_db schema + data from the GCP source
#   - pipe it directly into the local mysql container
#   - report row counts from the destination for spot-checking
#
# To minimise write-skew, put the GCP DB into read-only mode (or pause the
# writers) for the duration of the dump. The url-task-handler and
# upload-handler are the only continuous writers.

set -euo pipefail

GCP_HOST="${GCP_HOST:-34.44.192.195}"
GCP_USER="${GCP_USER:-root}"
GCP_DB="${GCP_DB:-malshare_db}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-mysql}"

if [[ -z "${GCP_PASS:-}" ]]; then
  read -r -s -p "GCP MySQL password for ${GCP_USER}@${GCP_HOST}: " GCP_PASS
  echo
fi

# Pull the local root password from frontend.env so we don't need it twice.
if [[ -f frontend.env ]]; then
  # shellcheck disable=SC1091
  set -a; . ./frontend.env; set +a
fi
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD must be set in frontend.env}"
: "${MALSHARE_DB_DATABASE:=malshare_db}"

echo "==> Verifying local mysql container is healthy"
if ! docker compose ps --status running "${COMPOSE_SERVICE}" | grep -q "${COMPOSE_SERVICE}"; then
  echo "ERROR: '${COMPOSE_SERVICE}' service is not running. Start it first: docker compose up -d ${COMPOSE_SERVICE}" >&2
  exit 1
fi

echo "==> Verifying destination database '${MALSHARE_DB_DATABASE}' exists and is empty"
TABLE_COUNT=$(docker compose exec -T "${COMPOSE_SERVICE}" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MALSHARE_DB_DATABASE}';")
if [[ "${TABLE_COUNT}" -ne 0 ]]; then
  echo "ERROR: destination DB '${MALSHARE_DB_DATABASE}' already has ${TABLE_COUNT} tables. Refusing to overwrite." >&2
  echo "       Drop and recreate it first if this is intentional:" >&2
  echo "       docker compose exec ${COMPOSE_SERVICE} mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e 'DROP DATABASE ${MALSHARE_DB_DATABASE}; CREATE DATABASE ${MALSHARE_DB_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;'" >&2
  exit 1
fi

echo "==> Dumping ${GCP_DB} from ${GCP_HOST} and streaming into ${COMPOSE_SERVICE}"
# Flags chosen for CloudSQL compatibility + InnoDB consistency:
#   --single-transaction  consistent snapshot without table locks (InnoDB only)
#   --quick               stream row-by-row, don't buffer huge tables
#   --routines/--triggers/--events  preserve stored procedures + DB-side automation
#   --hex-blob            safe binary roundtrip
#   --set-gtid-purged=OFF  CloudSQL doesn't grant the privileges to import GTID state
#   --no-tablespaces      avoid PROCESS privilege requirement on CloudSQL
#   --column-statistics=0 disable mysqldump 8.x feature CloudSQL rejects
MYSQL_PWD="${GCP_PASS}" mysqldump \
    --host="${GCP_HOST}" \
    --user="${GCP_USER}" \
    --single-transaction \
    --quick \
    --routines \
    --triggers \
    --events \
    --hex-blob \
    --set-gtid-purged=OFF \
    --no-tablespaces \
    --column-statistics=0 \
    --databases "${GCP_DB}" \
  | docker compose exec -T "${COMPOSE_SERVICE}" \
      mysql -uroot -p"${MYSQL_ROOT_PASSWORD}"

echo "==> Import finished. Reporting destination row counts:"
docker compose exec -T "${COMPOSE_SERVICE}" \
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${MALSHARE_DB_DATABASE}" -e "
    SELECT table_name, table_rows
    FROM information_schema.tables
    WHERE table_schema='${MALSHARE_DB_DATABASE}'
    ORDER BY table_name;
  "

echo
echo "Done. Compare these counts to the source before flipping MALSHARE_DB_HOST."
echo "Source check:"
echo "  MYSQL_PWD=... mysql -h ${GCP_HOST} -u ${GCP_USER} ${GCP_DB} -e \\"
echo "    \"SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='${GCP_DB}' ORDER BY table_name;\""
