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
| Engine | PostgreSQL 18.4 (Postgres.app) on aarch64-apple-darwin23.6.0, compiled by Apple clang version 15.0.0 (clang-1500.3.9.4), 64-bit |
| Machine | Apple M4, 16 GB RAM |
| Client | `psql` from the same installation as the server |
| Database | `buildbond_ap`, schema from `dbms/03_schema.sql` |
| Runs per statement | 3 measured runs, each shown, with their arithmetic mean; one warm-up run is discarded |
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
2. runs the whole workload once to warm the cache, then 3 times, recording
   every run and computing the arithmetic mean per statement;
3. repeats at 20000 projects;
4. writes one plan per statement into `dbms/plans/` (44 files) and the
   numbers behind the tables into `dbms/results/timings_cp4.csv`.

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
statement can read around a millisecond there and a few hundredths of a
millisecond here. Both are correct; they measure different things.

## 3. Every statement

Each statement was measured three times at each scale. The tables below show
the three runs and their arithmetic mean; nothing is averaged away.

### 3.1 20000 projects — three measured runs

| # | Kind | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Growth | Plan (top node) | Seq Scan |
|---|---|---:|---:|---:|---:|---:|---|---|
| [Q01](plans/Q01.txt) | READ | 0.006 | 0.006 | 0.006 | 0.006 | 1.0× | Index Scan using users_pkey on users | — |
| [Q02](plans/Q02.txt) | WRITE | 0.406 | 0.237 | 0.224 | 0.289 | 1.1× | Insert on users | — |
| [Q03](plans/Q03.txt) | READ | 0.011 | 0.009 | 0.009 | 0.010 | 1.1× | Index Scan using users_email_key on users | — |
| [Q04](plans/Q04.txt) | READ | 35.293 | 35.872 | 34.616 | 35.260 | 19.1× | Sort | milestones+users |
| [Q05](plans/Q05.txt) | READ | 0.083 | 0.080 | 0.061 | 0.075 | 1.7× | Nested Loop Left Join | — |
| [Q06](plans/Q06.txt) | READ | 0.036 | 0.036 | 0.036 | 0.036 | 1.2× | Nested Loop Left Join | — |
| [Q07](plans/Q07.txt) | READ | 0.015 | 0.016 | 0.013 | 0.015 | 1.9× | Index Scan using milestones_id_project_key on milestones | — |
| [Q08](plans/Q08.txt) | READ | 0.065 | 0.079 | 0.069 | 0.071 | 0.5× | Sort | — |
| [Q09](plans/Q09.txt) | READ | 0.013 | 0.017 | 0.013 | 0.014 | 1.2× | Index Scan using milestones_project_position_key on milestones | — |
| [Q10](plans/Q10.txt) | READ | 0.016 | 0.010 | 0.013 | 0.013 | 1.1× | Index Scan using ledger_project_idx on ledger_entries | — |
| [Q11](plans/Q11.txt) | READ | 0.012 | 0.027 | 0.017 | 0.019 | 1.1× | Bitmap Heap Scan on disputes | — |
| [Q12](plans/Q12.txt) | WRITE | 0.271 | 0.322 | 0.374 | 0.322 | 1.5× | Insert on projects | — |
| [Q13](plans/Q13.txt) | WRITE | 0.211 | 0.236 | 0.193 | 0.213 | 0.9× | Insert on milestones | — |
| [Q14](plans/Q14.txt) | WRITE | 0.230 | 0.293 | 0.208 | 0.244 | 1.1× | Insert on events | — |
| [Q15](plans/Q15.txt) | READ | 0.008 | 0.005 | 0.005 | 0.006 | 1.5× | Index Scan using milestones_project_position_key on milestones | — |
| [Q16](plans/Q16.txt) | READ | 0.025 | 0.030 | 0.024 | 0.026 | 1.0× | Sort | — |
| [Q17](plans/Q17.txt) | READ | 0.016 | 0.016 | 0.015 | 0.016 | 0.9× | Sort | — |
| [Q18](plans/Q18.txt) | READ | 0.027 | 0.027 | 0.020 | 0.025 | 0.3× | Incremental Sort | — |
| [Q19](plans/Q19.txt) | READ | 0.013 | 0.011 | 0.011 | 0.012 | 0.6× | Sort | — |
| [Q20](plans/Q20.txt) | WRITE | 0.270 | 0.271 | 0.363 | 0.301 | 1.1× | Update on projects | — |
| [Q21](plans/Q21.txt) | READ | 0.007 | 0.008 | 0.007 | 0.007 | 0.9× | LockRows | — |
| [Q22](plans/Q22.txt) | READ | 0.012 | 0.010 | 0.007 | 0.010 | 1.1× | Index Only Scan using ledger_entries_one_deposit_per_project on ledger_entries | — |
| [Q23](plans/Q23.txt) | WRITE | 0.256 | 0.216 | 0.185 | 0.219 | 1.1× | Insert on ledger_entries | — |
| [Q24](plans/Q24.txt) | WRITE | 0.070 | 0.062 | 0.058 | 0.063 | 1.0× | Update on milestones | — |
| [Q25](plans/Q25.txt) | WRITE | 0.296 | 0.296 | 0.281 | 0.291 | 1.1× | Insert on proofs | — |
| [Q26](plans/Q26.txt) | READ | 0.008 | 0.009 | 0.008 | 0.008 | 1.0× | LockRows | — |
| [Q27](plans/Q27.txt) | READ | 0.014 | 0.016 | 0.017 | 0.016 | 0.8× | Aggregate | — |
| [Q28](plans/Q28.txt) | WRITE | 0.049 | 0.048 | 0.045 | 0.047 | 0.9× | Update on milestones | — |
| [Q29](plans/Q29.txt) | WRITE | 0.216 | 0.139 | 0.130 | 0.162 | 1.0× | Update on proofs | — |
| [Q30](plans/Q30.txt) | WRITE | 0.177 | 0.144 | 0.135 | 0.152 | 1.0× | Insert on ledger_entries | — |
| [Q31](plans/Q31.txt) | READ | 0.013 | 0.012 | 0.009 | 0.011 | 1.0× | Aggregate | — |
| [Q32](plans/Q32.txt) | WRITE | 0.120 | 0.109 | 0.105 | 0.111 | 1.0× | Update on projects | — |
| [Q33](plans/Q33.txt) | READ | 0.012 | 0.008 | 0.007 | 0.009 | 1.0× | LockRows | — |
| [Q34](plans/Q34.txt) | WRITE | 0.158 | 0.090 | 0.138 | 0.129 | 0.9× | Update on proofs | — |
| [Q35](plans/Q35.txt) | WRITE | 0.078 | 0.056 | 0.077 | 0.070 | 1.0× | Update on milestones | — |
| [Q36](plans/Q36.txt) | WRITE | 0.281 | 0.294 | 0.325 | 0.300 | 1.1× | Insert on disputes | — |
| [Q37](plans/Q37.txt) | WRITE | 0.069 | 0.113 | 0.077 | 0.086 | 1.0× | Update on projects | — |
| [Q38](plans/Q38.txt) | READ | 0.006 | 0.007 | 0.007 | 0.007 | 0.7× | Index Scan using disputes_project_idx on disputes | — |
| [Q39](plans/Q39.txt) | WRITE | 0.105 | 0.137 | 0.156 | 0.133 | 1.1× | Update on disputes | — |
| [Q40](plans/Q40.txt) | READ | 0.009 | 0.011 | 0.010 | 0.010 | 0.5× | Aggregate | — |
| [Q41](plans/Q41.txt) | WRITE | 0.095 | 0.170 | 0.122 | 0.129 | 0.9× | Update on projects | — |
| [Q42](plans/Q42.txt) | READ | 22.078 | 22.146 | 21.859 | 22.028 | 16.9× | Limit | ledger_entries+projects |
| [Q43](plans/Q43.txt) | READ | 32.906 | 32.781 | 33.094 | 32.927 | 17.4× | Aggregate | projects |
| [Q44](plans/Q44.txt) | READ | 12.583 | 13.350 | 11.590 | 12.508 | 13.9× | Result | ledger_entries+disputes |

### 3.2 1200 projects — baseline, three measured runs

| # | Kind | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| Q01 | READ | 0.006 | 0.007 | 0.005 | 0.006 |
| Q02 | WRITE | 0.338 | 0.236 | 0.198 | 0.257 |
| Q03 | READ | 0.009 | 0.010 | 0.007 | 0.009 |
| Q04 | READ | 1.842 | 1.798 | 1.896 | 1.845 |
| Q05 | READ | 0.049 | 0.043 | 0.042 | 0.045 |
| Q06 | READ | 0.029 | 0.031 | 0.031 | 0.030 |
| Q07 | READ | 0.008 | 0.008 | 0.007 | 0.008 |
| Q08 | READ | 0.132 | 0.175 | 0.133 | 0.147 |
| Q09 | READ | 0.010 | 0.014 | 0.011 | 0.012 |
| Q10 | READ | 0.012 | 0.013 | 0.012 | 0.012 |
| Q11 | READ | 0.016 | 0.017 | 0.019 | 0.017 |
| Q12 | WRITE | 0.216 | 0.204 | 0.229 | 0.216 |
| Q13 | WRITE | 0.178 | 0.209 | 0.349 | 0.245 |
| Q14 | WRITE | 0.198 | 0.215 | 0.268 | 0.227 |
| Q15 | READ | 0.004 | 0.004 | 0.005 | 0.004 |
| Q16 | READ | 0.025 | 0.025 | 0.026 | 0.025 |
| Q17 | READ | 0.016 | 0.015 | 0.022 | 0.018 |
| Q18 | READ | 0.058 | 0.063 | 0.121 | 0.081 |
| Q19 | READ | 0.016 | 0.017 | 0.026 | 0.020 |
| Q20 | WRITE | 0.218 | 0.239 | 0.334 | 0.264 |
| Q21 | READ | 0.010 | 0.007 | 0.007 | 0.008 |
| Q22 | READ | 0.008 | 0.010 | 0.010 | 0.009 |
| Q23 | WRITE | 0.210 | 0.166 | 0.208 | 0.195 |
| Q24 | WRITE | 0.066 | 0.056 | 0.063 | 0.062 |
| Q25 | WRITE | 0.277 | 0.287 | 0.268 | 0.277 |
| Q26 | READ | 0.008 | 0.007 | 0.008 | 0.008 |
| Q27 | READ | 0.018 | 0.018 | 0.023 | 0.020 |
| Q28 | WRITE | 0.068 | 0.043 | 0.052 | 0.054 |
| Q29 | WRITE | 0.163 | 0.173 | 0.134 | 0.157 |
| Q30 | WRITE | 0.156 | 0.180 | 0.136 | 0.157 |
| Q31 | READ | 0.012 | 0.012 | 0.009 | 0.011 |
| Q32 | WRITE | 0.103 | 0.130 | 0.093 | 0.109 |
| Q33 | READ | 0.009 | 0.011 | 0.008 | 0.009 |
| Q34 | WRITE | 0.083 | 0.282 | 0.080 | 0.148 |
| Q35 | WRITE | 0.057 | 0.101 | 0.058 | 0.072 |
| Q36 | WRITE | 0.216 | 0.358 | 0.213 | 0.262 |
| Q37 | WRITE | 0.126 | 0.069 | 0.060 | 0.085 |
| Q38 | READ | 0.011 | 0.011 | 0.009 | 0.010 |
| Q39 | WRITE | 0.170 | 0.112 | 0.093 | 0.125 |
| Q40 | READ | 0.038 | 0.014 | 0.011 | 0.021 |
| Q41 | WRITE | 0.260 | 0.092 | 0.084 | 0.145 |
| Q42 | READ | 1.485 | 1.254 | 1.166 | 1.302 |
| Q43 | READ | 1.837 | 1.965 | 1.882 | 1.895 |
| Q44 | READ | 0.843 | 1.004 | 0.854 | 0.900 |

Growth in 3.1 is the large-scale average ÷ the small-scale average. A dash means
the small-scale average was under the timer's 0.001 ms resolution, so a ratio
would be noise.

Each file in `dbms/plans/` is the full `EXPLAIN (ANALYZE, BUFFERS)` output for
that statement at 20000 projects: the node tree, estimated versus actual rows,
loops, and the buffer counts that show whether the data came from cache or from
disk.

## 4. What the numbers say

Averaging the three runs at 20000 projects, the slowest application statement
is **Q04 at 35.260 ms** (Sort), and the fastest is
**Q01 at 0.006 ms**. Among the application statements, 1 statement takes more
than 1 ms and 1 takes more than 10 ms. That is the honest way to read the table: apart from those, the
statements are point lookups, and they would need a table far larger than this
one before they became interesting.

Between the two scales the project count grew 16.7× and the total
row count 16.7×. Average growth is 1.8× across the reads and
1.0× across the writes, so nothing is degrading super-linearly. The
statement that grows most is **Q04 at 19.1×**, roughly in step with the
number of rows it has to return, which is what a plan with no per-row shortcut
looks like.

Linear growth is not a problem by itself. It becomes one when the linear term is
big enough to be visible, because then the absolute time is large too. One
statement is in that position, and section 5 is about it.

## 5. The one that costs real time: the jobs board

Q04 (`GET /api/jobs`) takes 35.260 ms on average at 20000 projects, which is
more than every other application statement combined. Its plan is
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
takes 32.927 ms — but they are not application statements. They run once,
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
