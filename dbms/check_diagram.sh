#!/usr/bin/env bash
# =====================================================================
# Does the ER diagram still describe the schema?
#
#   ./dbms/check_diagram.sh
#
# Compares every column declared in dbms/03_schema.sql against the two
# diagram sources (dbms/02_er_diagram.dot and .mmd) and reports anything
# that is declared but not drawn.
#
# Exit status: 0 when they agree, 1 when they do not.
# No dependencies beyond awk, grep and psql-free parsing.
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ROOT/dbms/03_schema.sql"
DOT="$ROOT/dbms/02_er_diagram.dot"
MMD="$ROOT/dbms/02_er_diagram.mmd"

for f in "$SCHEMA" "$DOT" "$MMD"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# table.column for every real column (constraints are skipped)
cols="$(awk '
  /^CREATE TABLE / { t = $3; gsub(/[();]/, "", t); next }
  /^\);/           { t = ""; next }
  t != "" && $1 ~ /^[a-z_][a-z0-9_]*$/ &&
  $1 !~ /^(CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN|EXCLUDE)$/ { print t "." $1 }
' "$SCHEMA")"

# entity blocks in the mermaid file: lines inside "TABLE {" ... "}"
mmd_cols="$(awk '
  /^ *[A-Z_]+ \{$/ { t = tolower($1); next }
  /^ *\}$/          { t = ""; next }
  t != "" && NF >= 2 { col = $2; print t "." col }
' "$MMD")"

missing=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  table="${entry%%.*}"
  col="${entry#*.}"

  if ! grep -q ">${col}<" "$DOT"; then
    printf 'MISSING in .dot : %-28s\n' "$entry"
    missing=$((missing + 1))
  fi
  if ! printf '%s\n' "$mmd_cols" | grep -qx "${entry}"; then
    printf 'MISSING in .mmd : %-28s\n' "$entry"
    missing=$((missing + 1))
  fi
done <<< "$cols"

declared=$(printf '%s\n' "$cols" | grep -c . || true)
drawn=$(printf '%s\n' "$mmd_cols" | grep -c . || true)

echo
echo "columns in 03_schema.sql : $declared"
echo "columns in 02_er_diagram.mmd : $drawn"

if [ "$missing" -eq 0 ] && [ "$declared" -eq "$drawn" ]; then
  echo "OK: both diagrams describe every declared column."
  exit 0
fi

echo
echo "The diagram and the schema disagree ($missing problem(s))."
echo "Update dbms/02_er_diagram.mmd and .dot, then regenerate the PNG:"
echo "    dot -Tpng -Gdpi=142 dbms/02_er_diagram.dot -o dbms/02_er_diagram.png"
exit 1
