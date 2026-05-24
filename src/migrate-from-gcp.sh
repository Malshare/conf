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

# Pull the local root password from frontend.env. We parse as literal
# KEY=VALUE (not via `. ./frontend.env`) so passwords with $, `, #, quotes,
# etc. don't get reinterpreted by bash.
env_value() {
  local key="$1"
  local file="${2:-frontend.env}"
  [[ -f "$file" ]] || return 1
  # Strip the matching `KEY=` prefix; preserve everything after (incl. = signs).
  # Ignores commented-out lines and trims a single layer of surrounding quotes
  # to match docker compose's env_file parser.
  local line
  line=$(grep -E "^${key}=" "$file" | tail -n 1) || return 1
  [[ -n "$line" ]] || return 1
  local val="${line#${key}=}"
  # Strip matching surrounding single or double quotes, if any.
  if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:-1}"; fi
  if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:-1}"; fi
  printf '%s' "$val"
}

MYSQL_ROOT_PASSWORD="$(env_value MYSQL_ROOT_PASSWORD || true)"
MALSHARE_DB_DATABASE="$(env_value MALSHARE_DB_DATABASE || true)"
: "${MALSHARE_DB_DATABASE:=malshare_db}"

if [[ -z "${MYSQL_ROOT_PASSWORD}" ]]; then
  echo "ERROR: MYSQL_ROOT_PASSWORD is not set in frontend.env." >&2
  echo "       Add a line like:  MYSQL_ROOT_PASSWORD=<your-password>" >&2
  echo "       (no surrounding quotes needed; same string the mysql container was initialised with)" >&2
  exit 1
fi

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

echo "==> Source database overview (${GCP_HOST}/${GCP_DB})"
MYSQL_PWD="${GCP_PASS}" mysql \
    --host="${GCP_HOST}" --user="${GCP_USER}" -B -e "
      SELECT
        table_name AS 'table',
        table_rows AS 'rows',
        ROUND((data_length + index_length)/1024/1024, 1) AS 'size_mb'
      FROM information_schema.tables
      WHERE table_schema='${GCP_DB}'
      ORDER BY (data_length + index_length) DESC;
    "

# Estimated total bytes for the `pv -s` progress bar. mysqldump output is
# typically 1.5-2x the raw data_length (dumps include SQL syntax + hex-encoded
# blobs), so we scale up. Worst case pv shows >100% near the end.
EST_BYTES=$(MYSQL_PWD="${GCP_PASS}" mysql \
    --host="${GCP_HOST}" --user="${GCP_USER}" -N -B -e \
    "SELECT CAST(SUM(data_length + index_length) * 1.8 AS UNSIGNED)
     FROM information_schema.tables WHERE table_schema='${GCP_DB}';")

if command -v pv >/dev/null 2>&1; then
  PROGRESS=(pv --progress --timer --rate --average-rate --bytes --size "${EST_BYTES:-0}")
  echo "==> Progress bar enabled (pv detected)"
else
  PROGRESS=(cat)
  echo "==> 'pv' not installed; will only show per-table progress. Install with: apt-get install -y pv"
fi

echo "==> Dumping ${GCP_DB} from ${GCP_HOST} and streaming into ${COMPOSE_SERVICE}"
echo "    Estimated dump size: ~$((${EST_BYTES:-0} / 1024 / 1024)) MB"
echo "    Per-table progress will print to stderr below."
echo

# Flags chosen for CloudSQL compatibility + InnoDB consistency:
#   --verbose             emit "-- Retrieving table structure for X" to stderr
#   --single-transaction  consistent snapshot without table locks (InnoDB only)
#   --quick               stream row-by-row, don't buffer huge tables
#   --routines/--triggers/--events  preserve stored procedures + DB-side automation
#   --hex-blob            safe binary roundtrip
#   --set-gtid-purged=OFF  CloudSQL doesn't grant the privileges to import GTID state
#   --no-tablespaces      avoid PROCESS privilege requirement on CloudSQL
#   --column-statistics=0 disable mysqldump 8.x feature CloudSQL rejects
START=$(date +%s)
MYSQL_PWD="${GCP_PASS}" mysqldump \
    --host="${GCP_HOST}" \
    --user="${GCP_USER}" \
    --verbose \
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
  | "${PROGRESS[@]}" \
  | docker compose exec -T "${COMPOSE_SERVICE}" \
      mysql -uroot -p"${MYSQL_ROOT_PASSWORD}"
ELAPSED=$(( $(date +%s) - START ))
echo
echo "==> Dump+import finished in ${ELAPSED}s"

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
