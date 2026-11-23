#!/usr/bin/env python3
"""Generate dbms/plans.sql from dbms/04_queries.sql.

Every application statement is re-emitted as EXPLAIN (ANALYZE, BUFFERS).
Statements that feed a psql \\gset (parameter derivation, id bookkeeping)
are kept verbatim, because they must return rows, not a plan.

Run from the repo root:  python3 dbms/make_plans_sql.py
"""
import re
import sys
from pathlib import Path

SRC = Path("dbms/04_queries.sql")
DST = Path("dbms/plans.sql")

MARKER = re.compile(r"^-- (Q\d\d)\s+(READ|WRITE)\b")

out = []
buf = []
pending = None
seen_any = False


def flush_explain(stmt: str) -> None:
    global pending
    if pending:
        out.append(f"\\echo '==={pending}==='\n")
        pending = None
    out.append("EXPLAIN (ANALYZE, BUFFERS) " + stmt)


def flush_verbatim(stmt: str) -> None:
    global pending
    if pending:
        out.append(f"\\echo '==={pending}==='\n")
        pending = None
    out.append(stmt)


lines = SRC.read_text().splitlines(keepends=True)

for line in lines:
    stripped = line.strip()

    if stripped.startswith("\\timing"):
        continue

    # our own transaction wrapper replaces the source's
    if stripped in ("BEGIN;", "COMMIT;", "ROLLBACK;"):
        continue

    if stripped.startswith("-- Q") or ("  READ" in stripped and stripped.startswith("-- Q")):
        m = MARKER.match(stripped)
        if m:
            pending = m.group(1)
            out.append(line)
            continue

    if stripped.startswith("--") or not stripped:
        out.append(line)
        continue

    if stripped.startswith("\\gset"):
        stmt = "".join(buf)
        buf.clear()
        if pending:
            # A tagged statement that also has to return a row (the two
            # INSERT ... RETURNING id statements). Measure a copy inside a
            # savepoint, undo it, then run the real one so the \gset still
            # gets its value and no row is inserted twice.
            out.append(f"\\echo '==={pending}==='\n")
            out.append(f"SAVEPOINT sp_{pending};\n")
            out.append("EXPLAIN (ANALYZE, BUFFERS) " + stmt.rstrip() + ";\n")
            out.append(f"ROLLBACK TO SAVEPOINT sp_{pending};\n")
            pending = None
        out.append(stmt)
        out.append(line)
        continue

    if stripped.startswith("\\"):
        out.append(line)
        continue

    buf.append(line)
    if stripped.endswith(";"):
        if not seen_any:
            seen_any = True
        flush_explain("".join(buf))
        buf.clear()

header = """-- =====================================================================
-- GENERATED FILE — do not edit by hand.
-- Produced from dbms/04_queries.sql by dbms/make_plans_sql.py.
--
-- Every application statement is wrapped in EXPLAIN (ANALYZE, BUFFERS), so
-- running this file measures the statement and prints its plan. The few
-- statements that end in a psql \\gset are kept verbatim: they set the
-- parameters and the new row ids that the later statements use.
--
-- The whole file runs inside one transaction that is rolled back, so it can
-- be run repeatedly against the seeded database.
-- =====================================================================
\\set ON_ERROR_STOP on
\\pset pager off

BEGIN;

"""

body = "".join(out)
# the source opens with its own BEGIN; ours is added above
body = body.replace("BEGIN;\n", "", 1)
idx = body.rfind("ROLLBACK;")
if idx != -1:
    body = body[:idx]

DST.write_text(header + body + "\nROLLBACK;\n")
print(f"wrote {DST} ({len(DST.read_text().splitlines())} lines)")
