-- =====================================================================
-- GENERATED FILE — do not edit by hand.
-- Produced from dbms/04_queries.sql by dbms/make_plans_sql.py.
--
-- Every application statement is wrapped in EXPLAIN (ANALYZE, BUFFERS), so
-- running this file measures the statement and prints its plan. The few
-- statements that end in a psql \gset are kept verbatim: they set the
-- parameters and the new row ids that the later statements use.
--
-- The whole file runs inside one transaction that is rolled back, so it can
-- be run repeatedly against the seeded database.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

BEGIN;

-- =====================================================================
-- BuildBond — DBMS CP3: every SQL statement the application executes
--
-- Source of truth: the Express routes on the application's main branch
-- (commit 00f0d4a). Each block below is copied from the file and line
-- named in its header, with the same column list, joins, predicates and
-- ORDER BY. Nothing was rewritten, simplified or "improved" for the
-- report: if a plan for Q19 looks bad, that is the plan the API gets.
--
-- How parameters are written
--   The application sends these as bound parameters ($1, $2, ...) through
--   node-postgres. For a report we need values a human can read, so the
--   file uses psql variables (:project_id, :user_id, ...) and derives
--   them from the seeded data in section 0. psql substitutes them before
--   the statement is sent, so the server parses and plans exactly the
--   same statement text the API sends, just with literals instead of
--   bind parameters.
--
-- How to run
--   dbms/run_queries.sh                      (creates, seeds, runs, times)
--   psql -d buildbond_ap -f dbms/04_queries.sql
--
-- The write rehearsal in sections 5-12 runs inside one transaction that
-- is rolled back at the end, so running this file never leaves the
-- database in a different state than the seed left it. The point of the
-- write half is to prove each statement is valid against the real
-- constraints, which is what the API depends on.
--
-- Statement count: 41 application statements (23 READ, 18 WRITE) and
-- 3 audit queries. Several statements serve more than one call site;
-- the header of each says where.
-- =====================================================================

\set ON_ERROR_STOP on


-- =====================================================================
-- 0. Parameters, derived from the seeded data
--    One project that is ACTIVE and has a milestone waiting for review,
--    one project that is still OPEN, and one user of each role.
-- =====================================================================
SELECT
    p.id                                       AS project_id,
    p.client_id                                 AS client_id,
    p.contractor_id                             AS contractor_id,
    (SELECT m.id FROM milestones m
      WHERE m.project_id = p.id AND m.status = 'SUBMITTED'
      ORDER BY m.position LIMIT 1)              AS milestone_id
FROM projects p
WHERE p.status = 'ACTIVE'
  AND EXISTS (SELECT 1 FROM milestones m
               WHERE m.project_id = p.id AND m.status = 'SUBMITTED')
ORDER BY p.id
LIMIT 1
\gset p_

SELECT
    u.id      AS user_id,
    u.email   AS email
FROM users u
WHERE u.id = :p_client_id
\gset p_

SELECT p.id AS open_project_id
FROM projects p
WHERE p.status = 'OPEN' AND p.contractor_id IS NULL
ORDER BY p.id
LIMIT 1
\gset p_

-- A project whose milestones are all released, for the completion guard.
SELECT p.id AS complete_project_id
FROM projects p
WHERE p.status = 'COMPLETED'
ORDER BY p.id
LIMIT 1
\gset p_

-- Three project ids as a Postgres array literal, for the ANY($1::int[])
-- statements. This is the one place the report does something the app
-- does in JavaScript: it builds the array in the driver.
SELECT ('{' || string_agg(id::text, ',' ORDER BY id) || '}') AS project_ids
FROM (SELECT id FROM projects ORDER BY id LIMIT 3) t
\gset p_

\echo ''
\echo 'Parameters: project_id=' :p_project_id 'client_id=' :p_client_id 'contractor_id=' :p_contractor_id 'milestone_id=' :p_milestone_id
\echo ''

-- =====================================================================
-- 1. Authentication
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q01  READ
-- Source: server/src/auth.js:72-75 (requireAuth)
-- Params: :p_user_id
-- Runs on every authenticated request, before any route handler.
-- ---------------------------------------------------------------------
\echo '===Q01==='
EXPLAIN (ANALYZE, BUFFERS) SELECT id, name, email, role FROM users WHERE id = :p_user_id;

-- ---------------------------------------------------------------------
-- Q02  WRITE
-- Source: server/src/routes/auth.js:28-33 (POST /api/auth/register)
-- Params: name, email, password_hash, role
-- A duplicate email raises SQLSTATE 23505, which the route turns into
-- "an account with that email already exists".
-- ---------------------------------------------------------------------
\echo '===Q02==='
EXPLAIN (ANALYZE, BUFFERS) INSERT INTO users (name, email, password_hash, role)
VALUES ('Nisha Rao', 'nisha.rao@buildbond.test', '$2y$10$u/IJMkVp38.KSG7B7mqhL.iuGRAvFORD7rIEahEvkW/oY/sBd5xM.', 'CLIENT')
RETURNING id, name, email, role;

-- ---------------------------------------------------------------------
-- Q03  READ
-- Source: server/src/routes/auth.js:53 (POST /api/auth/login)
-- Params: :p_email
-- ---------------------------------------------------------------------
\echo '===Q03==='
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM users WHERE email = :'p_email';

-- =====================================================================
-- 2. Jobs board
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q04  READ
-- Source: server/src/routes/jobs.js:10-25 (GET /api/jobs)
-- Params: none
-- Every unclaimed open project with its client and milestone count.
-- GROUP BY p.id is enough for the other p.* columns because id is the
-- primary key; u.name has to be listed because it is not.
-- ---------------------------------------------------------------------
\echo '===Q04==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    p.id,
    p.title,
    p.description,
    p.total_paise,
    p.created_at,
    u.name AS client_name,
    COUNT(m.id)::int AS milestone_count
FROM projects p
JOIN users u ON u.id = p.client_id
LEFT JOIN milestones m ON m.project_id = p.id
WHERE p.status = 'OPEN' AND p.contractor_id IS NULL
GROUP BY p.id, u.name
ORDER BY p.created_at DESC, p.id DESC;

-- =====================================================================
-- 3. Access helpers (server/src/access.js)
--    These three run inside most project routes, so they are the
--    statements the database actually sees most often.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q05  READ
-- Source: server/src/access.js:5-21 (getProjectForUser)
-- Params: :p_project_id, :p_client_id
-- One row with the project, both party names and a "funded" flag. The
-- predicate also does the authorisation: a user who is neither party
-- gets zero rows and the route returns 404.
-- ---------------------------------------------------------------------
\echo '===Q05==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    p.*,
    c.name AS client_name,
    k.name AS contractor_name,
    EXISTS (
        SELECT 1
        FROM ledger_entries l
        WHERE l.project_id = p.id AND l.kind = 'DEPOSIT'
    ) AS funded
FROM projects p
JOIN users c ON c.id = p.client_id
LEFT JOIN users k ON k.id = p.contractor_id
WHERE p.id = :p_project_id
  AND (p.client_id = :p_client_id OR p.contractor_id = :p_client_id);

-- ---------------------------------------------------------------------
-- Q06  READ
-- Source: server/src/access.js:35-50 (getProjectById)
-- Params: :p_project_id
-- The same projection without the membership check. Used by the accept
-- route before the caller has any relationship to the project.
-- ---------------------------------------------------------------------
\echo '===Q06==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    p.*,
    c.name AS client_name,
    k.name AS contractor_name,
    EXISTS (
        SELECT 1
        FROM ledger_entries l
        WHERE l.project_id = p.id AND l.kind = 'DEPOSIT'
    ) AS funded
FROM projects p
JOIN users c ON c.id = p.client_id
LEFT JOIN users k ON k.id = p.contractor_id
WHERE p.id = :p_project_id;

-- ---------------------------------------------------------------------
-- Q07  READ
-- Source: server/src/access.js:92-95 (loadMilestone)
-- Params: :p_milestone_id, :p_project_id
-- The project_id predicate is what stops a URL with a milestone from a
-- different project being accepted.
-- ---------------------------------------------------------------------
\echo '===Q07==='
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM milestones WHERE id = :p_milestone_id AND project_id = :p_project_id;

-- =====================================================================
-- 4. Dashboard (GET /api/projects)
--    Four statements. The first finds the user's projects; the next
--    three fetch their milestones, ledger rows and open disputes in
--    bulk with ANY($1::int[]) instead of one query per project.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q08  READ
-- Source: server/src/routes/projects.js:21-32
-- Params: :p_client_id
-- ---------------------------------------------------------------------
\echo '===Q08==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    p.*,
    c.name AS client_name,
    k.name AS contractor_name
FROM projects p
JOIN users c ON c.id = p.client_id
LEFT JOIN users k ON k.id = p.contractor_id
WHERE p.client_id = :p_client_id OR p.contractor_id = :p_client_id
ORDER BY p.created_at DESC, p.id DESC;

-- ---------------------------------------------------------------------
-- Q09  READ
-- Source: server/src/routes/projects.js:43-48
-- Params: :'p_project_ids'::int[]
-- ---------------------------------------------------------------------
\echo '===Q09==='
EXPLAIN (ANALYZE, BUFFERS) SELECT id, project_id, position, title, amount_paise, status
FROM milestones
WHERE project_id = ANY(:'p_project_ids'::int[])
ORDER BY project_id, position;

-- ---------------------------------------------------------------------
-- Q10  READ
-- Source: server/src/routes/projects.js:50-54
-- Params: :'p_project_ids'::int[]
-- ---------------------------------------------------------------------
\echo '===Q10==='
EXPLAIN (ANALYZE, BUFFERS) SELECT project_id, kind, amount_paise
FROM ledger_entries
WHERE project_id = ANY(:'p_project_ids'::int[]);

-- ---------------------------------------------------------------------
-- Q11  READ
-- Source: server/src/routes/projects.js:56-60
-- Params: :'p_project_ids'::int[]
-- ---------------------------------------------------------------------
\echo '===Q11==='
EXPLAIN (ANALYZE, BUFFERS) SELECT project_id, milestone_id
FROM disputes
WHERE status = 'OPEN' AND project_id = ANY(:'p_project_ids'::int[]);

-- =====================================================================
-- 5. Create a project (POST /api/projects)
--    One transaction: the project, its milestones and the first event.
--    The two writes are shown once each even though the route loops over
--    2-5 milestones.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q12  WRITE
-- Source: server/src/routes/projects.js:186-191
-- Params: :p_client_id, title, description, total_paise
-- total_paise is computed in JavaScript as the sum of the milestone
-- amounts before this insert; there is no database-side check that it
-- stays equal to that sum, which is why the seed and audit query Q45
-- both recompute it.
-- ---------------------------------------------------------------------
\echo '===Q12==='
SAVEPOINT sp_Q12;
EXPLAIN (ANALYZE, BUFFERS) INSERT INTO projects (client_id, title, description, total_paise, status)
VALUES (:p_client_id, 'Two-room repaint after handover', 'Walls and ceiling only; furniture moved by the client.', 300000, 'OPEN')
RETURNING id;
ROLLBACK TO SAVEPOINT sp_Q12;
INSERT INTO projects (client_id, title, description, total_paise, status)
VALUES (:p_client_id, 'Two-room repaint after handover', 'Walls and ceiling only; furniture moved by the client.', 300000, 'OPEN')
RETURNING id
\gset n_proj_

-- ---------------------------------------------------------------------
-- Q13  WRITE
-- Source: server/src/routes/projects.js:196-205 (called once per milestone)
-- Params: project_id, position, title, amount_paise
-- Shown twice because the route loops; it is one statement, not two.
-- ---------------------------------------------------------------------
\echo '===Q13==='
EXPLAIN (ANALYZE, BUFFERS) INSERT INTO milestones (project_id, position, title, amount_paise, status)
VALUES (:n_proj_id, 1, 'Site prep and primer', 100000, 'PENDING');

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO milestones (project_id, position, title, amount_paise, status)
VALUES (:n_proj_id, 2, 'Two coats and finishing', 200000, 'PENDING');

-- ---------------------------------------------------------------------
-- Q14  WRITE
-- Source: server/src/routes/projects.js:208-216, and the same statement
--         at projects.js:355, 422; milestones.js:78, 205, 228, 337;
--         disputes.js:77, 164  (nine call sites, different kind/message)
-- Params: project_id, actor_id, kind, message
-- ---------------------------------------------------------------------
\echo '===Q14==='
EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:n_proj_id, :p_client_id, 'PROJECT_CREATED', 'Client created "Two-room repaint after handover" with 2 milestones.');

-- ---------------------------------------------------------------------
-- Bookkeeping, not an application query. The route keeps the new
-- milestone ids in JavaScript; psql has to read them back.
-- ---------------------------------------------------------------------
SELECT (SELECT id FROM milestones WHERE project_id = :n_proj_id AND position = 1) AS m1
\gset n_

-- =====================================================================
-- 6. Project detail (GET /api/projects/:id)
--    Five independent reads issued together with Promise.all.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q15  READ
-- Source: server/src/routes/projects.js:232-238
-- ---------------------------------------------------------------------
\echo '===Q15==='
EXPLAIN (ANALYZE, BUFFERS) SELECT id, project_id, position, title, amount_paise, status, created_at
FROM milestones
WHERE project_id = :n_proj_id
ORDER BY position;

-- ---------------------------------------------------------------------
-- Q16  READ
-- Source: server/src/routes/projects.js:239-251
-- The LEFT JOIN on the reviewer is what allows an unreviewed proof to
-- appear with a null reviewed_by_name.
-- ---------------------------------------------------------------------
\echo '===Q16==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    pr.*,
    u.name AS submitted_by_name,
    r.name AS reviewed_by_name
FROM proofs pr
JOIN milestones m ON m.id = pr.milestone_id
JOIN users u ON u.id = pr.submitted_by
LEFT JOIN users r ON r.id = pr.reviewed_by
WHERE m.project_id = :n_proj_id
ORDER BY pr.created_at DESC, pr.id DESC;

-- ---------------------------------------------------------------------
-- Q17  READ
-- Source: server/src/routes/projects.js:252-261
-- ---------------------------------------------------------------------
\echo '===Q17==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    l.*,
    m.title AS milestone_title
FROM ledger_entries l
LEFT JOIN milestones m ON m.id = l.milestone_id
WHERE l.project_id = :n_proj_id
ORDER BY l.created_at ASC, l.id ASC;

-- ---------------------------------------------------------------------
-- Q18  READ
-- Source: server/src/routes/projects.js:262-271
-- ---------------------------------------------------------------------
\echo '===Q18==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    e.*,
    u.name AS actor_name
FROM events e
JOIN users u ON u.id = e.actor_id
WHERE e.project_id = :n_proj_id
ORDER BY e.created_at ASC, e.id ASC;

-- ---------------------------------------------------------------------
-- Q19  READ
-- Source: server/src/routes/projects.js:272-283
-- ---------------------------------------------------------------------
\echo '===Q19==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    d.*,
    u.name AS raised_by_name,
    m.title AS milestone_title
FROM disputes d
JOIN users u ON u.id = d.raised_by
JOIN milestones m ON m.id = d.milestone_id
WHERE d.project_id = :n_proj_id
ORDER BY d.created_at DESC, d.id DESC;

-- =====================================================================
-- 7. A contractor accepts a project (POST /api/projects/:id/accept)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q20  WRITE
-- Source: server/src/routes/projects.js:337-346
-- Params: :p_contractor_id, :n_proj_id
-- The four predicates are the concurrency control: if two contractors
-- press accept at the same moment, the second UPDATE matches no row and
-- the route returns 409 instead of overwriting the first.
-- ---------------------------------------------------------------------
\echo '===Q20==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE projects
SET contractor_id = :p_contractor_id, status = 'ACTIVE'
WHERE id = :n_proj_id
  AND status = 'OPEN'
  AND contractor_id IS NULL
  AND client_id <> :p_contractor_id
RETURNING id;

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:n_proj_id, :p_contractor_id, 'CONTRACTOR_ACCEPTED', 'Contractor accepted the project.');

-- =====================================================================
-- 8. The client funds the escrow (POST /api/projects/:id/fund)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q21  READ  (row lock)
-- Source: server/src/routes/projects.js:389-392 (fund), and the same
--         statement at milestones.js:45, 110, 268 and disputes.js:39,
--         126. Five call sites, one statement.
-- Params: :n_proj_id
-- FOR UPDATE is the only lock in the schema's read path: it serialises
-- "check the state, then write" against a second request.
-- ---------------------------------------------------------------------
\echo '===Q21==='
EXPLAIN (ANALYZE, BUFFERS) SELECT id, status FROM projects WHERE id = :n_proj_id FOR UPDATE;

-- ---------------------------------------------------------------------
-- Q22  READ
-- Source: server/src/routes/projects.js:401-405
-- ---------------------------------------------------------------------
\echo '===Q22==='
EXPLAIN (ANALYZE, BUFFERS) SELECT 1 FROM ledger_entries
WHERE project_id = :n_proj_id AND kind = 'DEPOSIT';

-- ---------------------------------------------------------------------
-- Q23  WRITE
-- Source: server/src/routes/projects.js:413-418
-- The partial unique index one_deposit_per_project is the backstop if
-- Q22 races.
-- ---------------------------------------------------------------------
\echo '===Q23==='
EXPLAIN (ANALYZE, BUFFERS) INSERT INTO ledger_entries
  (project_id, milestone_id, kind, amount_paise, note)
VALUES (:n_proj_id, NULL, 'DEPOSIT', 300000, 'Demo escrow deposit');

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:n_proj_id, :p_client_id, 'PROJECT_FUNDED', 'Client deposited the full amount into demo escrow.');

-- =====================================================================
-- 9. The contractor submits proof (POST .../milestones/:id/proofs)
-- =====================================================================

-- Q21 again: the route re-checks and locks the project.

-- ---------------------------------------------------------------------
-- Q24  WRITE
-- Source: server/src/routes/milestones.js:57-63
-- Params: milestone_id, previous status
-- The status predicate is the state machine's guard; a milestone that
-- moved since the read matches no row.
-- ---------------------------------------------------------------------
\echo '===Q24==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE milestones
SET status = 'SUBMITTED'
WHERE id = :n_m1 AND status = 'PENDING'
RETURNING id;

-- ---------------------------------------------------------------------
-- Q25  WRITE
-- Source: server/src/routes/milestones.js:72-76
-- ---------------------------------------------------------------------
\echo '===Q25==='
EXPLAIN (ANALYZE, BUFFERS) INSERT INTO proofs (milestone_id, submitted_by, url, note, status)
VALUES (:n_m1, :p_contractor_id, 'https://proofs.buildbond.test/two-room/primer.jpg', 'Primer coat complete.', 'SUBMITTED');

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:n_proj_id, :p_contractor_id, 'PROOF_SUBMITTED', 'Contractor submitted proof for "Site prep and primer".');

-- =====================================================================
-- 10. The client approves and releases money
--     (POST .../milestones/:id/approve)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q26  READ  (row lock)
-- Source: server/src/routes/milestones.js:123-129
-- ---------------------------------------------------------------------
\echo '===Q26==='
EXPLAIN (ANALYZE, BUFFERS) SELECT id, title, amount_paise, status
FROM milestones
WHERE id = :n_m1 AND project_id = :n_proj_id
FOR UPDATE;

-- ---------------------------------------------------------------------
-- Q27  READ
-- Source: server/src/routes/milestones.js:145-152
-- The balance the client is about to spend against, computed from the
-- ledger rather than stored.
-- ---------------------------------------------------------------------
\echo '===Q27==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    COALESCE(SUM(CASE WHEN kind = 'DEPOSIT' THEN amount_paise ELSE 0 END), 0)::int AS deposited,
    COALESCE(SUM(CASE WHEN kind = 'RELEASE' THEN amount_paise ELSE 0 END), 0)::int AS released
FROM ledger_entries
WHERE project_id = :n_proj_id;

-- ---------------------------------------------------------------------
-- Q28  WRITE
-- Source: server/src/routes/milestones.js:162-168
-- ---------------------------------------------------------------------
\echo '===Q28==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE milestones
SET status = 'RELEASED'
WHERE id = :n_m1 AND status = 'SUBMITTED'
RETURNING id;

-- ---------------------------------------------------------------------
-- Q29  WRITE
-- Source: server/src/routes/milestones.js:176-190
-- Approves the newest SUBMITTED proof for the milestone. ORDER BY +
-- LIMIT 1 is safe because one_submitted_per_milestone allows at most one
-- matching row.
-- ---------------------------------------------------------------------
\echo '===Q29==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE proofs
SET status = 'APPROVED',
    reviewed_by = :p_client_id,
    reviewed_at = now()
WHERE id = (
    SELECT id
    FROM proofs
    WHERE milestone_id = :n_m1 AND status = 'SUBMITTED'
    ORDER BY created_at DESC, id DESC
    LIMIT 1
)
RETURNING id;

-- ---------------------------------------------------------------------
-- Q30  WRITE
-- Source: server/src/routes/milestones.js:198-213
-- The milestone amount comes from the row Q26 locked, so the release
-- always matches the amount that was approved.
-- ---------------------------------------------------------------------
\echo '===Q30==='
EXPLAIN (ANALYZE, BUFFERS) INSERT INTO ledger_entries
  (project_id, milestone_id, kind, amount_paise, note)
VALUES (:n_proj_id, :n_m1, 'RELEASE', 100000, 'Released after proof approval');

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:n_proj_id, :p_client_id, 'MILESTONE_RELEASED', 'Client approved "Site prep and primer" and released the milestone amount.');

-- ---------------------------------------------------------------------
-- Q31  READ
-- Source: server/src/routes/milestones.js:215-220
-- Counted against a project the seed already paid off, so the guard is
-- exercised with a real zero rather than an empty table.
-- ---------------------------------------------------------------------
\echo '===Q31==='
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*)::int AS count
FROM milestones
WHERE project_id = :p_complete_project_id AND status <> 'RELEASED';

-- ---------------------------------------------------------------------
-- Q32  WRITE
-- Source: server/src/routes/milestones.js:223-236
-- Only reached when Q31 returns 0.
-- ---------------------------------------------------------------------
\echo '===Q32==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE projects SET status = 'COMPLETED' WHERE id = :p_complete_project_id;

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:p_complete_project_id, :p_client_id, 'PROJECT_COMPLETED', 'All milestones are released. The project is complete.');

-- =====================================================================
-- 11. The client rejects a proof, then the contractor disputes it
--     Uses the seeded project selected in section 0.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q33  READ  (row lock)
-- Source: server/src/routes/milestones.js:280-286
-- ---------------------------------------------------------------------
\echo '===Q33==='
EXPLAIN (ANALYZE, BUFFERS) SELECT id, title, status
FROM milestones
WHERE id = :p_milestone_id AND project_id = :p_project_id
FOR UPDATE;

-- ---------------------------------------------------------------------
-- Q34  WRITE
-- Source: server/src/routes/milestones.js:300-315
-- A rejection must carry a reason, which is why this UPDATE sets three
-- columns at once: the partial CHECK on proofs requires them to agree.
-- ---------------------------------------------------------------------
\echo '===Q34==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE proofs
SET status = 'REJECTED',
    review_note = 'The photographs do not show the second bedroom, which the milestone covers.',
    reviewed_by = :p_client_id,
    reviewed_at = now()
WHERE id = (
    SELECT id
    FROM proofs
    WHERE milestone_id = :p_milestone_id AND status = 'SUBMITTED'
    ORDER BY created_at DESC, id DESC
    LIMIT 1
)
RETURNING id;

-- ---------------------------------------------------------------------
-- Q35  WRITE
-- Source: server/src/routes/milestones.js:323-329
-- ---------------------------------------------------------------------
\echo '===Q35==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE milestones
SET status = 'REJECTED'
WHERE id = :p_milestone_id AND status = 'SUBMITTED'
RETURNING id;

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:p_project_id, :p_client_id, 'PROOF_REJECTED', 'Client rejected the proof and asked for a resubmission.');

-- =====================================================================
-- 12. Disputes (POST /api/projects/:id/disputes, .../:id/withdraw)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q36  WRITE
-- Source: server/src/routes/disputes.js:55-60
-- A second open dispute on the same milestone raises 23505 from
-- disputes_one_open_per_milestone and the route answers 409.
-- ---------------------------------------------------------------------
\echo '===Q36==='
SAVEPOINT sp_Q36;
EXPLAIN (ANALYZE, BUFFERS) INSERT INTO disputes (project_id, milestone_id, raised_by, reason)
VALUES (:p_project_id, :p_milestone_id, :p_contractor_id, 'The client rejected work that was completed and photographed on site.')
RETURNING id;
ROLLBACK TO SAVEPOINT sp_Q36;
INSERT INTO disputes (project_id, milestone_id, raised_by, reason)
VALUES (:p_project_id, :p_milestone_id, :p_contractor_id, 'The client rejected work that was completed and photographed on site.')
RETURNING id
\gset n_disp_

-- ---------------------------------------------------------------------
-- Q37  WRITE
-- Source: server/src/routes/disputes.js:72-75
-- ---------------------------------------------------------------------
\echo '===Q37==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE projects SET status = 'DISPUTED' WHERE id = :p_project_id;

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:p_project_id, :p_contractor_id, 'DISPUTE_RAISED', 'Contractor raised a dispute on the active milestone.');

-- ---------------------------------------------------------------------
-- Q38  READ
-- Source: server/src/routes/disputes.js:102-105
-- ---------------------------------------------------------------------
\echo '===Q38==='
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM disputes WHERE id = :n_disp_id AND project_id = :p_project_id;

-- Q21 again: the withdraw route also locks the project.

-- ---------------------------------------------------------------------
-- Q39  WRITE
-- Source: server/src/routes/disputes.js:133-139
-- Setting resolved_at in the same statement is what satisfies the
-- disputes_resolved_state_check.
-- ---------------------------------------------------------------------
\echo '===Q39==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE disputes
SET status = 'WITHDRAWN', resolved_at = now()
WHERE id = :n_disp_id AND status = 'OPEN'
RETURNING id;

-- ---------------------------------------------------------------------
-- Q40  READ
-- Source: server/src/routes/disputes.js:147-152
-- ---------------------------------------------------------------------
\echo '===Q40==='
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*)::int AS count
FROM disputes
WHERE project_id = :p_project_id AND status = 'OPEN';

-- ---------------------------------------------------------------------
-- Q41  WRITE
-- Source: server/src/routes/disputes.js:158-161
-- Runs only when Q40 returned 0 and the project was DISPUTED.
-- ---------------------------------------------------------------------
\echo '===Q41==='
EXPLAIN (ANALYZE, BUFFERS) UPDATE projects SET status = 'ACTIVE' WHERE id = :p_project_id;

EXPLAIN (ANALYZE, BUFFERS) INSERT INTO events (project_id, actor_id, kind, message)
VALUES (:p_project_id, :p_contractor_id, 'DISPUTE_WITHDRAWN', 'Contractor withdrew the dispute. The project is active again.');

-- =====================================================================
-- 13. Audit queries
--     Not application statements. These check that the invariants the
--     application assumes actually hold in the data; every one of them
--     must return 0 on a healthy database.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q42  READ  ledger balance per project (deposited, released, held)
-- ---------------------------------------------------------------------
\echo '===Q42==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    p.id,
    COALESCE(SUM(CASE WHEN l.kind = 'DEPOSIT' THEN l.amount_paise END), 0)::int AS deposited,
    COALESCE(SUM(CASE WHEN l.kind = 'RELEASE' THEN l.amount_paise END), 0)::int AS released,
    COALESCE(
        SUM(CASE WHEN l.kind = 'DEPOSIT' THEN l.amount_paise ELSE -l.amount_paise END), 0
    )::int AS held
FROM projects p
LEFT JOIN ledger_entries l ON l.project_id = p.id
GROUP BY p.id
HAVING count(l.id) > 0
ORDER BY 2 DESC, p.id
LIMIT 5;

-- ---------------------------------------------------------------------
-- Q43  READ  projects whose total disagrees with their milestones
-- ---------------------------------------------------------------------
\echo '===Q43==='
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) AS projects_with_wrong_total
FROM projects p
WHERE p.total_paise <> (SELECT sum(amount_paise) FROM milestones WHERE project_id = p.id);

-- ---------------------------------------------------------------------
-- Q44  READ  rows that would break a business rule
-- ---------------------------------------------------------------------
\echo '===Q44==='
EXPLAIN (ANALYZE, BUFFERS) SELECT
    (SELECT count(*) FROM (
        SELECT project_id FROM ledger_entries WHERE kind = 'DEPOSIT'
        GROUP BY project_id HAVING count(*) > 1) x)            AS double_deposits,
    (SELECT count(*) FROM (
        SELECT milestone_id FROM ledger_entries WHERE kind = 'RELEASE'
        GROUP BY milestone_id HAVING count(*) > 1) x)          AS double_releases,
    (SELECT count(*) FROM (
        SELECT milestone_id FROM proofs WHERE status = 'SUBMITTED'
        GROUP BY milestone_id HAVING count(*) > 1) x)          AS double_pending_proofs,
    (SELECT count(*) FROM (
        SELECT milestone_id FROM disputes WHERE status = 'OPEN'
        GROUP BY milestone_id HAVING count(*) > 1) x)          AS double_open_disputes;


ROLLBACK;
