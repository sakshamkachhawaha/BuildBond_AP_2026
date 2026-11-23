#!/usr/bin/env bash
# =====================================================================
# BuildBond — run dbms/04_queries.sql against a fresh, seeded database
#
#   ./dbms/run_queries.sh                 # 400 users, 1,200 projects
#   N_PROJECTS=20000 ./dbms/run_queries.sh
#
# It drops and recreates the database every time, so the run is
# repeatable and never measures a table that has been VACUUMed differently
# from the last run.
#
# Output:
#   dbms/results/run_<n_projects>.log   full psql transcript
#   dbms/results/timings_<n_projects>.csv   one row per executed statement
#
# Environment:
#   DB          database name             (default buildbond_ap)
#   PSQL        psql binary               (default: psql on PATH)
#   PGUSER      role                      (default: $USER)
#   PGHOST      socket dir or host        (default: local socket)
#   PGPORT      port                      (default: 5432)
#   N_USERS     seeded users              (default: 400)
#   N_PROJECTS  seeded projects           (default: 1200)
#   SKIP_SETUP  1 to reuse an existing database instead of recreating it
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${DB:-buildbond_ap}"
PSQL="${PSQL:-psql}"
if ! command -v "$PSQL" >/dev/null 2>&1; then
  # Postgres.app does not put psql on PATH; Homebrew does.
  for candidate in /Applications/Postgres.app/Contents/Versions/18/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/17/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/16/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/15/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/14/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/latest/bin/psql \
                   /opt/homebrew/bin/psql /usr/local/bin/psql; do
    if [ -x "$candidate" ]; then PSQL="$candidate"; break; fi
  done
else
  PSQL="$(command -v "$PSQL")"
fi
if ! command -v "$PSQL" >/dev/null 2>&1; then
  echo "psql not found. Set PSQL=/path/to/psql or open Postgres.app and run:" >&2
  echo '  export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"' >&2
  exit 1
fi
PGBIN="$(dirname "$PSQL")"
N_USERS="${N_USERS:-400}"
N_PROJECTS="${N_PROJECTS:-1200}"
SKIP_SETUP="${SKIP_SETUP:-0}"

mkdir -p "$ROOT/dbms/results"

if [[ "$SKIP_SETUP" != "1" ]]; then
  echo "== recreating database $DB"
  "$PGBIN/dropdb" --if-exists "$DB"
  "$PGBIN/createdb" "$DB"

  echo "== applying dbms/03_schema.sql"
  "$PSQL" -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ROOT/dbms/03_schema.sql"

  echo "== seeding $N_USERS users / $N_PROJECTS projects"
  "$PSQL" -d "$DB" -v ON_ERROR_STOP=1 -q \
      -v n_users="$N_USERS" -v n_projects="$N_PROJECTS" \
      -f "$ROOT/dbms/seed_ap.sql"
fi

LOG="$ROOT/dbms/results/run_${N_PROJECTS}.log"
CSV="$ROOT/dbms/results/timings_${N_PROJECTS}.csv"

echo "== running dbms/04_queries.sql"
# -a echoes every input line, so the transcript contains the "-- Qnn READ"
# markers from the file. The awk pass below pairs each marker with the
# psql timing line that follows it.
"$PSQL" -d "$DB" -a -f "$ROOT/dbms/04_queries.sql" > "$LOG" 2>&1 || {
  echo "!! psql exited non-zero, see $LOG" >&2
  exit 1
}

if grep -qE '^psql:.*(ERROR|FATAL)' "$LOG"; then
  echo "!! an error was reported in $LOG" >&2
  grep -nE '^psql:.*(ERROR|FATAL)' "$LOG" >&2
  exit 1
fi

awk '
  /^-- Q[0-9]+  (READ|WRITE)/ {
      kind = $3
      id = $2
      next
  }
  /^(BEGIN|COMMIT|ROLLBACK)$/ { skip = 1; next }
  /^Time: / {
      ms = $2
      if (skip == 1) { skip = 0; next }
      if (id != "") printf "%s,%s,%s\n", id, kind, ms
      next
  }
  END { }
' "$LOG" > "$CSV"

echo "== transcript: $LOG"
echo "== timings:    $CSV"
echo
echo "server: $("$PSQL" -d "$DB" -Atc 'select version()')"
echo "rows:   $("$PSQL" -d "$DB" -Atc "
  select string_agg(t || '=' || n, ' ' order by t) from (
    select 'users' t, count(*) n from users
    union all select 'projects', count(*) from projects
    union all select 'milestones', count(*) from milestones
    union all select 'proofs', count(*) from proofs
    union all select 'ledger', count(*) from ledger_entries
    union all select 'events', count(*) from events
    union all select 'disputes', count(*) from disputes) s")"
echo
echo "slowest statements:"
{ echo "query,kind,ms"; sort -t, -k3 -gr "$CSV" | head -8; } | column -t -s,
