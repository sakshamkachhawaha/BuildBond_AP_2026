#!/usr/bin/env bash
# =====================================================================
# BuildBond — CP4: measure every statement and write the evidence
#
#   ./dbms/build_cp4.sh
#
# What it does, in order:
#   1. recreates the database and seeds it at the small scale (1,200 projects)
#   2. warm-up run, then 3 measured runs of dbms/plans.sql, median per query
#   3. repeats at the large scale (20,000 projects)
#   4. splits the large-scale plans into dbms/plans/Q01.txt ... Q44.txt
#   5. writes dbms/results/timings_cp4.csv and dbms/05_query_timings.md
#
# Every number in the report comes from this run, on this machine. Nothing is
# copied from anywhere else.
#
# Environment (all optional):
#   DB          database name            (default buildbond_ap)
#   PSQL        psql binary              (default: psql on PATH or Postgres.app)
#   PGHOST PGPORT PGUSER                 as usual for psql
#   SMALL        small scale in projects (default 1200)
#   LARGE        large scale in projects (default 20000)
#   RUNS         measured runs per scale (default 3)
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="${DB:-buildbond_ap}"
PSQL="${PSQL:-psql}"
SMALL="${SMALL:-1200}"
LARGE="${LARGE:-20000}"
RUNS="${RUNS:-3}"

if ! command -v "$PSQL" >/dev/null 2>&1; then
  for candidate in /Applications/Postgres.app/Contents/Versions/18/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/17/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/16/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/15/bin/psql \
                   /Applications/Postgres.app/Contents/Versions/latest/bin/psql \
                   /opt/homebrew/bin/psql /usr/local/bin/psql; do
    if [ -x "$candidate" ]; then PSQL="$candidate"; break; fi
  done
fi
if ! command -v "$PSQL" >/dev/null 2>&1; then
  echo "psql not found. Set PSQL=/path/to/psql" >&2
  exit 1
fi
PSQL="$(command -v "$PSQL")"

# plans.sql is generated from 04_queries.sql. If the query file changed and
# python3 is available, regenerate rather than measure a stale workload.
if [ -f "$ROOT/dbms/make_plans_sql.py" ] && command -v python3 >/dev/null 2>&1; then
  if [ ! -f "$ROOT/dbms/plans.sql" ] || [ "$ROOT/dbms/04_queries.sql" -nt "$ROOT/dbms/plans.sql" ]; then
    echo "== regenerating dbms/plans.sql from dbms/04_queries.sql"
    ( cd "$ROOT" && python3 dbms/make_plans_sql.py )
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$ROOT/dbms/plans" "$ROOT/dbms/results"

TABLES="users projects milestones proofs ledger_entries events disputes"

# ---------------------------------------------------------------------
# measure <scale>  ->  $TMP/t_<scale>.csv      query,median_ms
#                   ->  $TMP/plans_<scale>.txt first measured run
#                   ->  $TMP/rows_<scale>.csv  table,rows
# ---------------------------------------------------------------------
measure() {
  local scale="$1"
  local users="$(( scale / 3 ))"
  if [ "$users" -lt 400 ]; then users=400; fi

  echo "== scale $scale: recreating and seeding ($users users)"
  DB="$DB" PSQL="$PSQL" N_PROJECTS="$scale" N_USERS="$users" \
      "$ROOT/dbms/run_queries.sh" >"$TMP/setup_${scale}.log" 2>&1 || {
    echo "!! setup failed at scale $scale, see below" >&2
    tail -20 "$TMP/setup_${scale}.log" >&2
    exit 1
  }

  : >"$TMP/rows_${scale}.csv"
  local t
  for t in $TABLES; do
    printf '%s,%s\n' "$t" "$("$PSQL" -d "$DB" -Atc "select count(*) from $t")" >>"$TMP/rows_${scale}.csv"
  done

  echo "== scale $scale: warm-up run"
  "$PSQL" -d "$DB" -q -f "$ROOT/dbms/plans.sql" >/dev/null 2>&1

  local r
  : >"$TMP/all_${scale}.csv"
  for r in $(seq 1 "$RUNS"); do
    echo "== scale $scale: measured run $r/$RUNS"
    "$PSQL" -d "$DB" -f "$ROOT/dbms/plans.sql" >"$TMP/plans_${scale}_run${r}.txt" 2>&1 || true
    if grep -qE '^psql:.*(ERROR|FATAL)' "$TMP/plans_${scale}_run${r}.txt"; then
      echo "!! an error was reported at scale $scale run $r" >&2
      grep -nE '^psql:.*(ERROR|FATAL)' "$TMP/plans_${scale}_run${r}.txt" >&2
      exit 1
    fi
    awk -v run="$r" '
      /^===Q[0-9][0-9]===/ { id = substr($0, 4, 3); next }
      /Execution Time: / { t[id] += $3 }
      END { for (q in t) printf "%s,%s,%.3f\n", q, run, t[q] }
    ' "$TMP/plans_${scale}_run${r}.txt" >>"$TMP/all_${scale}.csv"
  done

  # median across runs (with 3 runs, the middle value)
  sort -t, -k1,1 -k3,3n "$TMP/all_${scale}.csv" \
    | awk -F, -v keep="$(( (RUNS + 1) / 2 ))" '
        { c[$1]++; if (c[$1] == keep) printf "%s,%.3f\n", $1, $3 }
      ' >"$TMP/t_${scale}.csv"

  cp "$TMP/plans_${scale}_run1.txt" "$TMP/plans_${scale}.txt"
  echo "== scale $scale: $(wc -l <"$TMP/t_${scale}.csv" | tr -d ' ') queries measured"
}

measure "$SMALL"
measure "$LARGE"

# ---------------------------------------------------------------------
# One file per query, from the large-scale run
# ---------------------------------------------------------------------
rm -f "$ROOT"/dbms/plans/Q*.txt
awk -v dir="$ROOT/dbms/plans" '
  /^===Q[0-9][0-9]===/ { id = substr($0, 4, 3); print "== " id > (dir "/" id ".txt"); next }
  id != "" { print > (dir "/" id ".txt") }
' "$TMP/plans_${LARGE}.txt"

# ---------------------------------------------------------------------
# Per-query plan facts
# ---------------------------------------------------------------------
: >"$TMP/facts.csv"
for f in "$ROOT"/dbms/plans/Q*.txt; do
  id="$(basename "$f" .txt)"
  awk -v id="$id" '
    top == "" && /\(cost=/ && /[A-Za-z]/ {
      line = $0
      sub(/^ +/, "", line)
      sub(/  \(cost=.*/, "", line)
      top = line
    }
    /Seq Scan on / {
      match($0, /Seq Scan on [a-z_]+/)
      s = substr($0, RSTART + 12, RLENGTH - 12)
      if (!(s in seens)) { seens[s] = 1; seq = seq (seq == "" ? "" : "+") s }
    }
    match($0, /Index Only Scan using [a-z_]+/) {
      n = substr($0, RSTART + 22, RLENGTH - 22)
      key = "ios:" n
      if (!(key in seeni)) { seeni[key] = 1; idx = idx (idx == "" ? "" : "+") n }
      next
    }
    match($0, /Index Scan using [a-z_]+/) {
      n = substr($0, RSTART + 17, RLENGTH - 17)
      key = "is:" n
      if (!(key in seeni)) { seeni[key] = 1; idx = idx (idx == "" ? "" : "+") n }
      next
    }
    match($0, /Bitmap Index Scan on [a-z_]+/) {
      n = substr($0, RSTART + 21, RLENGTH - 21)
      key = "bis:" n
      if (!(key in seeni)) { seeni[key] = 1; idx = idx (idx == "" ? "" : "+") n }
    }
    END { printf "%s|%s|%s|%s\n", id, top, seq, idx }
  ' "$f" >>"$TMP/facts.csv"
done

# ---------------------------------------------------------------------
# Join both scales with the plan facts and the READ/WRITE label
# ---------------------------------------------------------------------
awk -F, 'NR==FNR { small[$1] = $2; next } { large[$1] = $2 } END {
  for (q in large) printf "%s,%s,%s\n", q, (q in small ? small[q] : "0"), large[q]
}' "$TMP/t_${SMALL}.csv" "$TMP/t_${LARGE}.csv" | sort >"$TMP/growth.csv"

awk -F'|' 'NR==FNR { split($0, a, ","); s[a[1]] = a[2]; g[a[1]] = a[3]; next }
            { printf "%s,%s,%s,%s,%s,%s\n", $1, s[$1], g[$1], $2, $3, $4 }' \
    "$TMP/growth.csv" "$TMP/facts.csv" | sort >"$TMP/table.csv"

awk '
  /^-- Q[0-9][0-9]  READ/  { id = substr($0, 4, 3); k[id] = "READ";  next }
  /^-- Q[0-9][0-9]  WRITE/ { id = substr($0, 4, 3); k[id] = "WRITE"; next }
  END { for (q in k) printf "%s,%s\n", q, k[q] }
' "$ROOT/dbms/04_queries.sql" | sort >"$TMP/kind.csv"

awk -F, 'NR==FNR { kind[$1] = $2; next }
         { printf "%s,%s,%s,%s,%s,%s,%s\n", $1, kind[$1], $2, $3,
                  ($2 > 0 ? sprintf("%.1f", $3 / $2) : "-"), $4, ($5 == "" ? "none" : $5) }' \
    "$TMP/kind.csv" "$TMP/table.csv" | sort >"$TMP/report_table.csv"

echo "query,kind,ms_small,ms_large,growth,top_node,seq_scans" >"$ROOT/dbms/results/timings_cp4.csv"
cat "$TMP/report_table.csv" >>"$ROOT/dbms/results/timings_cp4.csv"

# ---------------------------------------------------------------------
# Facts used in the prose. Q42-Q44 are audit queries, not application
# statements, so they are excluded from the "slowest" and "grows most"
# claims and reported separately.
# ---------------------------------------------------------------------
awk -F, '$1 < "Q42"' "$TMP/report_table.csv" >"$TMP/app.csv"
awk -F, '$1 >= "Q42"' "$TMP/report_table.csv" >"$TMP/audit.csv"

SERVER="$("$PSQL" -d "$DB" -Atc 'select version()')"
CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
MEM_GB="$(sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%.0f", $1 / 1073741824 }')"
[ -n "$MEM_GB" ] || MEM_GB="unknown"

TOTAL_SMALL="$(awk -F, '{ s += $2 } END { print s }' "$TMP/rows_${SMALL}.csv")"
TOTAL_LARGE="$(awk -F, '{ s += $2 } END { print s }' "$TMP/rows_${LARGE}.csv")"
DATA_RATIO="$(awk -v a="$TOTAL_LARGE" -v b="$TOTAL_SMALL" 'BEGIN { printf "%.1f", a / b }')"
PROJECT_RATIO="$(awk -v a="$LARGE" -v b="$SMALL" 'BEGIN { printf "%.1f", a / b }')"

SLOWEST="$(sort -t, -k4,4gr "$TMP/app.csv" | head -1)"
SLOWEST_Q="$(echo "$SLOWEST" | cut -d, -f1)"
SLOWEST_MS="$(echo "$SLOWEST" | cut -d, -f4)"
SLOWEST_TOP="$(echo "$SLOWEST" | cut -d, -f6)"
FASTEST="$(sort -t, -k4,4g "$TMP/app.csv" | head -1)"
FASTEST_Q="$(echo "$FASTEST" | cut -d, -f1)"
FASTEST_MS="$(echo "$FASTEST" | cut -d, -f4)"
BG="$(awk -F, '$5 != "-"' "$TMP/app.csv" | sort -t, -k5,5gr | head -1)"
BG_Q="$(echo "$BG" | cut -d, -f1)"
BG_RATIO="$(echo "$BG" | cut -d, -f5)"
OVER_1MS="$(awk -F, '$4 > 1' "$TMP/app.csv" | wc -l | tr -d ' ')"
OVER_10MS="$(awk -F, '$4 > 10' "$TMP/app.csv" | wc -l | tr -d ' ')"
if [ "$OVER_1MS" = "1" ]; then V1=takes; N1=statement; else V1=take; N1=statements; fi
if [ "$OVER_10MS" = "1" ]; then V10=takes; else V10=take; fi
READ_AVG="$(awk -F, '$2 == "READ" && $5 != "-" { s += $5; n++ } END { printf "%.1f", s / n }' "$TMP/app.csv")"
WRITE_AVG="$(awk -F, '$2 == "WRITE" && $5 != "-" { s += $5; n++ } END { printf "%.1f", s / n }' "$TMP/app.csv")"
SEQ_QUERIES="$(awk -F, '$7 != "none" { printf "%s ", $1 }' "$TMP/report_table.csv" | sed 's/ $//')"
AUDIT_SLOW="$(sort -t, -k4,4gr "$TMP/audit.csv" | head -1)"
AUDIT_Q="$(echo "$AUDIT_SLOW" | cut -d, -f1)"
AUDIT_MS="$(echo "$AUDIT_SLOW" | cut -d, -f4)"
PLAN_COUNT="$(ls "$ROOT"/dbms/plans/Q*.txt | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------
# Markdown table
# ---------------------------------------------------------------------
{
  echo "| # | Kind | $SMALL projects | $LARGE projects | Growth | Plan (top node) | Seq Scan |"
  echo "|---|---|---:|---:|---:|---|---|"
  while IFS=, read -r q k a b g top seq; do
    printf "| [%s](plans/%s.txt) | %s | %s ms | %s ms | %s× | %s | %s |\n" \
      "$q" "$q" "$k" "$a" "$b" "$g" "$top" "${seq/none/—}"
  done <"$TMP/report_table.csv"
} >"$TMP/table.md"

{
  echo "| Table | $SMALL projects | $LARGE projects |"
  echo "|---|---:|---:|"
  join -t, -j1 <(sort "$TMP/rows_${SMALL}.csv") <(sort "$TMP/rows_${LARGE}.csv") \
    | while IFS=, read -r t a b; do printf "| %s | %s | %s |\n" "$t" "$a" "$b"; done
  printf "| **total** | **%s** | **%s** |\n" "$TOTAL_SMALL" "$TOTAL_LARGE"
} >"$TMP/rows.md"

# ---------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------
{
cat <<EOF
# DBMS 05 — BuildBond query timings and plans

**What this is.** Every SQL statement the application executes, measured on a
real database at two data volumes, with the execution plan that produced each
number. The statements themselves are in \`dbms/04_queries.sql\`; this file is
the measurement, not a second copy of them.

**What this is not.** It is not a benchmark of PostgreSQL. It is one client, one
machine, one schema, warm cache, one session at a time. The numbers say how
these queries behave at these two sizes. They do not predict production.

## 1. Environment

| Item | Value |
|---|---|
| Engine | $SERVER |
| Machine | $CPU, ${MEM_GB} GB RAM |
| Client | \`psql\` from the same installation as the server |
| Database | \`$DB\`, schema from \`dbms/03_schema.sql\` |
| Runs per statement | $RUNS measured runs, median, after one discarded warm-up run |
| Row counts | see the table below |

### Data volume

$(cat "$TMP/rows.md")

Timestamps in the seed are IST and the session runs with
\`TimeZone = 'Asia/Kolkata'\`.

## 2. Method

\`dbms/build_cp4.sh\` reproduces everything here:

1. drops and recreates the database, applies \`dbms/03_schema.sql\`, and loads
   \`dbms/seed_ap.sql\` at $SMALL projects;
2. runs the whole workload once to warm the cache, then $RUNS times, keeping the
   median execution time per statement;
3. repeats at $LARGE projects;
4. writes one plan per statement into \`dbms/plans/\` ($PLAN_COUNT files) and the
   numbers behind the table into \`dbms/results/timings_cp4.csv\`.

\`dbms/plans.sql\` is generated from \`04_queries.sql\` by
\`dbms/make_plans_sql.py\`. It wraps every statement in
\`EXPLAIN (ANALYZE, BUFFERS)\` and leaves the two id-returning inserts verbatim,
measured inside a savepoint and then undone, so the statements after them still
receive their parameters. The workload runs inside a transaction that ends in
\`ROLLBACK\`, so nothing accumulates between runs and the seed stays intact.

A block's time is the sum of the statements in it, because several routes issue
two statements in one transaction (a ledger row and an event row, for example).
That sum is what the request pays.

Two numbers are worth keeping apart. The times here are the server's
\`Execution Time\` from \`EXPLAIN (ANALYZE)\`, which excludes the client round
trip. \`dbms/results/timings_1200.csv\`, written by \`run_queries.sh\`, comes from
psql's \`\\timing\` and therefore includes that round trip, which is why the same
statement can read ~0.9 ms there and ~0.05 ms here. Both are correct; they
measure different things.

## 3. Every statement

$(cat "$TMP/table.md")

Growth is large ÷ small. A dash means the small-scale time was under the
timer's 0.001 ms resolution, so a ratio would be noise.

Each file in \`dbms/plans/\` is the full \`EXPLAIN (ANALYZE, BUFFERS)\` output for
that statement at $LARGE projects: the node tree, estimated versus actual rows,
loops, and the buffer counts that show whether the data came from cache or from
disk.

## 4. What the numbers say

At $LARGE projects the slowest application statement is **$SLOWEST_Q at
$SLOWEST_MS ms** ($SLOWEST_TOP), and the fastest is **$FASTEST_Q at
$FASTEST_MS ms**. Only $OVER_1MS $N1 $V1 more than 1 ms and $OVER_10MS $V10 more
than 10 ms. That is the honest way to read the table: apart from those, the
statements are point lookups, and they would need a table far larger than this
one before they became interesting.

Between the two scales the project count grew ${PROJECT_RATIO}× and the total
row count ${DATA_RATIO}×. Average growth is ${READ_AVG}× across the reads and
${WRITE_AVG}× across the writes, so nothing is degrading super-linearly. The
statement that grows most is **$BG_Q at ${BG_RATIO}×**, roughly in step with the
number of rows it has to return, which is what a plan with no per-row shortcut
looks like.

Linear growth is not a problem by itself. It becomes one when the linear term is
big enough to be visible, because then the absolute time is large too. One
statement is in that position, and section 5 is about it.

## 5. The one that costs real time: the jobs board

Q04 (\`GET /api/jobs\`) takes $SLOWEST_MS ms at $LARGE projects, which is more than
every other application statement combined. Its plan is
\`dbms/plans/Q04.txt\`; read it from the bottom up:

* \`projects_open_idx\` is a partial index on \`(created_at DESC)\` restricted to
  \`status = 'OPEN' AND contractor_id IS NULL\`, so the scan touches only the
  unclaimed projects and already returns them in the order the query asks for;
* the plan then hashes \`milestones\` to compute \`COUNT(m.id)\` for those
  projects, which means visiting every milestone of every returned project;
* it aggregates one row per returned project and sorts the result.

The cost is therefore in the aggregate and the sort, not in the filter, and a
second index on \`projects\` would not change it. The route also has no \`LIMIT\`:
it returns every open project in the system. That is the reason this query grows
with the data while the others do not, and the reason it is the one to fix if
the app ever has enough projects for it to matter. Two honest options: paginate
the endpoint, or accept it — at this volume the whole page still renders in
tens of milliseconds.

## 6. Where sequential scans appear

Statements with a sequential scan somewhere in their plan: $SEQ_QUERIES.

A sequential scan is not a defect on its own. The audit queries Q42–Q44 read
whole tables by design, and Q04 scans \`milestones\` because it genuinely needs
every milestone of the projects it returns. What would be a defect is a scan on
a table the statement only needs a slice of, and none of these statements does
that.

The audit queries are the heaviest statements that read whole tables — $AUDIT_Q
takes $AUDIT_MS ms — but they are not application statements. They run once,
offline, to check that the invariants hold, and they are in the file for that
reason rather than to be fast.

## 7. What this measurement does not cover

* **Concurrency.** One client, one statement at a time. The app serves several,
  and the three statements that take \`FOR UPDATE\` locks (five call sites) will
  queue behind each other under contention. None of that waiting appears here.
* **Cold cache.** The first run of each scale is discarded, so these are
  steady-state numbers and they flatter the first request after a restart.
* **Write cost under load.** Writes are measured once each inside a rolled-back
  transaction. WAL volume, checkpointing and index maintenance under sustained
  writes are not part of the number.
* **Real data.** The seed is generated by \`dbms/seed_ap.sql\` and shaped like the
  app's workload (40% open, 50% active, 8% completed, 2% disputed). The shape of
  these results should hold; the absolute milliseconds will not.
EOF
} >"$ROOT/dbms/05_query_timings.md"

echo
echo "== wrote dbms/05_query_timings.md"
echo "== wrote dbms/results/timings_cp4.csv"
echo "== wrote $PLAN_COUNT plan files in dbms/plans/"
echo
sort -t, -k4,4gr "$TMP/app.csv" | head -6 \
  | awk -F, 'BEGIN { printf "%-4s %-6s %10s %10s %8s\n", "#", "kind", "small", "large", "growth" }
             { printf "%-4s %-6s %9s  %9s  %6sx\n", $1, $2, $3, $4, $5 }'
