# DBMS 05 — BuildBond query timings and plans

**What this is.** Every SQL statement the application executes, measured on a
real database at two data volumes, with the execution plan that produced each
number. The statements themselves are in `dbms/04_queries.sql`; this file is
the measurement, not a second copy of them.

**What this is not.** It is not a benchmark of PostgreSQL. It is one client, one
machine, one schema, warm cache, one session at a time. The numbers say how
these queries behave at these two sizes. They do not predict production.

## 1. Environment

| Item | Value |
|---|---|
| Engine | PostgreSQL 18.6 (Postgres.app) on aarch64-apple-darwin23.6.0, compiled by Apple clang version 15.0.0 (clang-1500.3.9.4), 64-bit |
| Machine | Apple M4, 16 GB RAM |
| Client | `psql` from the same installation as the server |
| Database | `buildbond_ap`, schema from `dbms/03_schema.sql` |
| Runs per statement | 3 measured runs, median, after one discarded warm-up run |
| Row counts | see the table below |

### Data volume

| Table | 1200 projects | 20000 projects |
|---|---:|---:|
| disputes | 70 | 1173 |
| events | 3692 | 61546 |
| ledger_entries | 1656 | 27600 |
| milestones | 3600 | 60001 |
| projects | 1200 | 20000 |
| proofs | 1615 | 26910 |
| users | 400 | 6666 |
| **total** | **12233** | **203896** |

Timestamps in the seed are IST and the session runs with
`TimeZone = 'Asia/Kolkata'`.

## 2. Method

`dbms/build_cp4.sh` reproduces everything here:

1. drops and recreates the database, applies `dbms/03_schema.sql`, and loads
   `dbms/seed_ap.sql` at 1200 projects;
2. runs the whole workload once to warm the cache, then 3 times, keeping the
   median execution time per statement;
3. repeats at 20000 projects;
4. writes one plan per statement into `dbms/plans/` (44 files) and the
   numbers behind the table into `dbms/results/timings_cp4.csv`.

`dbms/plans.sql` is generated from `04_queries.sql` by
`dbms/make_plans_sql.py`. It wraps every statement in
`EXPLAIN (ANALYZE, BUFFERS)` and leaves the two id-returning inserts verbatim,
measured inside a savepoint and then undone, so the statements after them still
receive their parameters. The workload runs inside a transaction that ends in
`ROLLBACK`, so nothing accumulates between runs and the seed stays intact.

A block's time is the sum of the statements in it, because several routes issue
two statements in one transaction (a ledger row and an event row, for example).
That sum is what the request pays.

Two numbers are worth keeping apart. The times here are the server's
`Execution Time` from `EXPLAIN (ANALYZE)`, which excludes the client round
trip. `dbms/results/timings_1200.csv`, written by `run_queries.sh`, comes from
psql's `\timing` and therefore includes that round trip, which is why the same
statement can read ~0.9 ms there and ~0.05 ms here. Both are correct; they
measure different things.

## 3. Every statement

| # | Kind | 1200 projects | 20000 projects | Growth | Plan (top node) | Seq Scan |
|---|---|---:|---:|---:|---|---|
| [Q01](plans/Q01.txt) | READ | 0.003 ms | 0.003 ms | 1.0× | Index Scan using users_pkey on users | — |
| [Q02](plans/Q02.txt) | WRITE | 0.109 ms | 0.107 ms | 1.0× | Insert on users | — |
| [Q03](plans/Q03.txt) | READ | 0.004 ms | 0.004 ms | 1.0× | Index Scan using users_email_key on users | — |
| [Q04](plans/Q04.txt) | READ | 0.913 ms | 15.562 ms | 17.0× | Sort | milestones+users |
| [Q05](plans/Q05.txt) | READ | 0.019 ms | 0.026 ms | 1.4× | Nested Loop Left Join | — |
| [Q06](plans/Q06.txt) | READ | 0.014 ms | 0.014 ms | 1.0× | Nested Loop Left Join | — |
| [Q07](plans/Q07.txt) | READ | 0.005 ms | 0.004 ms | 0.8× | Index Scan using milestones_id_project_key on milestones | — |
| [Q08](plans/Q08.txt) | READ | 0.060 ms | 0.034 ms | 0.6× | Sort | — |
| [Q09](plans/Q09.txt) | READ | 0.005 ms | 0.006 ms | 1.2× | Index Scan using milestones_project_position_key on milestones | — |
| [Q10](plans/Q10.txt) | READ | 0.007 ms | 0.005 ms | 0.7× | Index Scan using ledger_project_idx on ledger_entries | — |
| [Q11](plans/Q11.txt) | READ | 0.008 ms | 0.006 ms | 0.8× | Bitmap Heap Scan on disputes | — |
| [Q12](plans/Q12.txt) | WRITE | 0.104 ms | 0.116 ms | 1.1× | Insert on projects | — |
| [Q13](plans/Q13.txt) | WRITE | 0.098 ms | 0.113 ms | 1.2× | Insert on milestones | — |
| [Q14](plans/Q14.txt) | WRITE | 0.094 ms | 0.130 ms | 1.4× | Insert on events | — |
| [Q15](plans/Q15.txt) | READ | 0.003 ms | 0.003 ms | 1.0× | Index Scan using milestones_project_position_key on milestones | — |
| [Q16](plans/Q16.txt) | READ | 0.009 ms | 0.010 ms | 1.1× | Sort | — |
| [Q17](plans/Q17.txt) | READ | 0.007 ms | 0.006 ms | 0.9× | Sort | — |
| [Q18](plans/Q18.txt) | READ | 0.028 ms | 0.010 ms | 0.4× | Incremental Sort | — |
| [Q19](plans/Q19.txt) | READ | 0.008 ms | 0.006 ms | 0.8× | Sort | — |
| [Q20](plans/Q20.txt) | WRITE | 0.138 ms | 0.113 ms | 0.8× | Update on projects | — |
| [Q21](plans/Q21.txt) | READ | 0.004 ms | 0.004 ms | 1.0× | LockRows | — |
| [Q22](plans/Q22.txt) | READ | 0.005 ms | 0.004 ms | 0.8× | Index Only Scan using ledger_entries_one_deposit_per_project on ledger_entries | — |
| [Q23](plans/Q23.txt) | WRITE | 0.114 ms | 0.088 ms | 0.8× | Insert on ledger_entries | — |
| [Q24](plans/Q24.txt) | WRITE | 0.043 ms | 0.028 ms | 0.7× | Update on milestones | — |
| [Q25](plans/Q25.txt) | WRITE | 0.279 ms | 0.129 ms | 0.5× | Insert on proofs | — |
| [Q26](plans/Q26.txt) | READ | 0.005 ms | 0.004 ms | 0.8× | LockRows | — |
| [Q27](plans/Q27.txt) | READ | 0.010 ms | 0.008 ms | 0.8× | Aggregate | — |
| [Q28](plans/Q28.txt) | WRITE | 0.026 ms | 0.024 ms | 0.9× | Update on milestones | — |
| [Q29](plans/Q29.txt) | WRITE | 0.070 ms | 0.061 ms | 0.9× | Update on proofs | — |
| [Q30](plans/Q30.txt) | WRITE | 0.073 ms | 0.068 ms | 0.9× | Insert on ledger_entries | — |
| [Q31](plans/Q31.txt) | READ | 0.005 ms | 0.005 ms | 1.0× | Aggregate | — |
| [Q32](plans/Q32.txt) | WRITE | 0.057 ms | 0.052 ms | 0.9× | Update on projects | — |
| [Q33](plans/Q33.txt) | READ | 0.005 ms | 0.005 ms | 1.0× | LockRows | — |
| [Q34](plans/Q34.txt) | WRITE | 0.040 ms | 0.056 ms | 1.4× | Update on proofs | — |
| [Q35](plans/Q35.txt) | WRITE | 0.032 ms | 0.031 ms | 1.0× | Update on milestones | — |
| [Q36](plans/Q36.txt) | WRITE | 0.098 ms | 0.093 ms | 0.9× | Insert on disputes | — |
| [Q37](plans/Q37.txt) | WRITE | 0.034 ms | 0.032 ms | 0.9× | Update on projects | — |
| [Q38](plans/Q38.txt) | READ | 0.006 ms | 0.003 ms | 0.5× | Index Scan using disputes_project_idx on disputes | — |
| [Q39](plans/Q39.txt) | WRITE | 0.050 ms | 0.044 ms | 0.9× | Update on disputes | — |
| [Q40](plans/Q40.txt) | READ | 0.007 ms | 0.004 ms | 0.6× | Aggregate | — |
| [Q41](plans/Q41.txt) | WRITE | 0.060 ms | 0.046 ms | 0.8× | Update on projects | — |
| [Q42](plans/Q42.txt) | READ | 0.571 ms | 9.794 ms | 17.2× | Limit | ledger_entries+projects |
| [Q43](plans/Q43.txt) | READ | 0.867 ms | 15.656 ms | 18.1× | Aggregate | projects |
| [Q44](plans/Q44.txt) | READ | 0.414 ms | 5.944 ms | 14.4× | Result | ledger_entries+disputes |

Growth is large ÷ small. A dash means the small-scale time was under the
timer's 0.001 ms resolution, so a ratio would be noise.

Each file in `dbms/plans/` is the full `EXPLAIN (ANALYZE, BUFFERS)` output for
that statement at 20000 projects: the node tree, estimated versus actual rows,
loops, and the buffer counts that show whether the data came from cache or from
disk.

## 4. What the numbers say

At 20000 projects the slowest application statement is **Q04 at
15.562 ms** (Sort), and the fastest is **Q01 at
0.003 ms**. Only 1 statement takes more than 1 ms and 1 takes more
than 10 ms. That is the honest way to read the table: apart from those, the
statements are point lookups, and they would need a table far larger than this
one before they became interesting.

Between the two scales the project count grew 16.7× and the total
row count 16.7×. Average growth is 1.6× across the reads and
0.9× across the writes, so nothing is degrading super-linearly. The
statement that grows most is **Q04 at 17.0×**, roughly in step with the
number of rows it has to return, which is what a plan with no per-row shortcut
looks like.

Linear growth is not a problem by itself. It becomes one when the linear term is
big enough to be visible, because then the absolute time is large too. One
statement is in that position, and section 5 is about it.

## 5. The one that costs real time: the jobs board

Q04 (`GET /api/jobs`) takes 15.562 ms at 20000 projects, which is more than
every other application statement combined. Its plan is
`dbms/plans/Q04.txt`; read it from the bottom up:

* `projects_open_idx` is a partial index on `(created_at DESC)` restricted to
  `status = 'OPEN' AND contractor_id IS NULL`, so the scan touches only the
  unclaimed projects and already returns them in the order the query asks for;
* the plan then hashes `milestones` to compute `COUNT(m.id)` for those
  projects, which means visiting every milestone of every returned project;
* it aggregates one row per returned project and sorts the result.

The cost is therefore in the aggregate and the sort, not in the filter, and a
second index on `projects` would not change it. The route also has no `LIMIT`:
it returns every open project in the system. That is the reason this query grows
with the data while the others do not, and the reason it is the one to fix if
the app ever has enough projects for it to matter. Two honest options: paginate
the endpoint, or accept it — at this volume the whole page still renders in
tens of milliseconds.

## 6. Where sequential scans appear

Statements with a sequential scan somewhere in their plan: Q04 Q42 Q43 Q44.

A sequential scan is not a defect on its own. The audit queries Q42–Q44 read
whole tables by design, and Q04 scans `milestones` because it genuinely needs
every milestone of the projects it returns. What would be a defect is a scan on
a table the statement only needs a slice of, and none of these statements does
that.

The audit queries are the heaviest statements that read whole tables — Q43
takes 15.656 ms — but they are not application statements. They run once,
offline, to check that the invariants hold, and they are in the file for that
reason rather than to be fast.

## 7. What this measurement does not cover

* **Concurrency.** One client, one statement at a time. The app serves several,
  and the three statements that take `FOR UPDATE` locks (five call sites) will
  queue behind each other under contention. None of that waiting appears here.
* **Cold cache.** The first run of each scale is discarded, so these are
  steady-state numbers and they flatter the first request after a restart.
* **Write cost under load.** Writes are measured once each inside a rolled-back
  transaction. WAL volume, checkpointing and index maintenance under sustained
  writes are not part of the number.
* **Real data.** The seed is generated by `dbms/seed_ap.sql` and shaped like the
  app's workload (40% open, 50% active, 8% completed, 2% disputed). The shape of
  these results should hold; the absolute milliseconds will not.
