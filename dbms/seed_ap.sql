-- =====================================================================
-- BuildBond — AP workload seed
--
-- Purpose: give dbms/04_queries.sql something to run against. The app's
-- own server/db/seed.mjs seeds one demonstration project, which is right
-- for a demo and useless for timing a project list or a dispute count.
--
-- This file is deterministic: no random(), no now() in the data values,
-- so two runs on two machines produce byte-identical tables. Every row
-- is generated from generate_series and arithmetic on the row number.
--
-- Scale is a psql variable, so the same file serves CP3 (a few thousand
-- rows, instant) and CP4 (a larger run):
--     psql -v n_users=400 -v n_projects=1200 -f dbms/seed_ap.sql
--     psql -v n_projects=20000 -f dbms/seed_ap.sql        # CP4 size
-- Defaults: 400 users, 1200 projects.
--
-- Every seeded user's password is "password123" (one shared bcrypt
-- digest), matching the app's demo accounts, so a seeded row can log in
-- through the real API if you want to click through it.
--
-- The data tells a coherent story, because the queries assume one:
--   * 40% of projects are OPEN and unclaimed   -> GET /api/jobs
--   * 50% are ACTIVE, funded, part-paid        -> approve/reject paths
--   *  8% are COMPLETED, every milestone paid  -> status transition
--   *  2% are DISPUTED, one open dispute       -> withdraw path
-- =====================================================================

\if :{?n_users}
\else
  \set n_users 400
\endif

\if :{?n_projects}
\else
  \set n_projects 1200
\endif

BEGIN;

-- ---------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------
INSERT INTO users (name, email, password_hash, role, created_at)
SELECT
    (ARRAY['Aarav','Vivaan','Aditya','Diya','Ananya','Ishaan','Kavya','Reyansh',
           'Meera','Arjun','Saanvi','Kabir','Riya','Advik','Nithya','Rohan',
           'Tara','Dev','Ira','Karan','Neha','Yash','Pooja','Manav'])[1 + (i % 24)]
    || ' ' ||
    (ARRAY['Sharma','Verma','Iyer','Nair','Patel','Reddy','Gupta','Bose',
           'Menon','Joshi','Rao','Kulkarni','Das','Chawla','Shetty','Mishra',
           'Kapoor','Pillai','Ghosh','Bhat','Sethi','Jain','Chopra','Kaur'])[1 + ((i / 24) % 24)],
    'user' || i || '@buildbond.test',
    -- bcrypt('password123', 10) — the same digest for every seeded login.
    '$2y$10$u/IJMkVp38.KSG7B7mqhL.iuGRAvFORD7rIEahEvkW/oY/sBd5xM.',
    CASE WHEN i % 5 < 3 THEN 'CLIENT' ELSE 'CONTRACTOR' END,
    TIMESTAMPTZ '2026-01-01 09:00:00+05:30' + (i * INTERVAL '17 minutes')
FROM generate_series(1, :n_users) AS g(i);

-- ---------------------------------------------------------------------
-- projects
-- Client and contractor are drawn from the matching role, and the row
-- number is hashed so the same client does not own a contiguous block.
-- total_paise starts at 1 and is replaced by the milestone sum below,
-- in the same transaction, before anything reads it.
-- ---------------------------------------------------------------------
INSERT INTO projects (client_id, contractor_id, title, description, total_paise, status, created_at)
SELECT
    c.id,
    CASE WHEN i % 100 < 40 THEN NULL ELSE k.id END,
    (ARRAY['Kitchen renovation','Bathroom retile','Balcony waterproofing','Full flat repaint',
           'Wardrobe carpentry','Electrical rewire','False ceiling','Terrace shed',
           'Modular kitchen','Staircase railing','Window replacement','Borewell plumbing'])[1 + (i % 12)]
    || ' — ' ||
    (ARRAY['Whitefield','Indiranagar','Koramangala','Jayanagar','HSR Layout','Hebbal',
           'Rajajinagar','Marathahalli','BTM Layout','Yelahanka','Basavanagudi','Bellandur'])[1 + ((i / 12) % 12)],
    'Scope agreed over a site visit. Materials billed separately; labour and finishing are inside the milestone amounts.',
    1,
    CASE
        WHEN i % 100 < 40 THEN 'OPEN'
        WHEN i % 100 < 90 THEN 'ACTIVE'
        WHEN i % 100 < 98 THEN 'COMPLETED'
        ELSE 'DISPUTED'
    END,
    TIMESTAMPTZ '2026-02-01 10:00:00+05:30' + (i * INTERVAL '53 minutes')
FROM generate_series(1, :n_projects) AS g(i)
JOIN LATERAL (
    SELECT id FROM users WHERE role = 'CLIENT' ORDER BY id
    OFFSET (i * 37) % (SELECT count(*) FROM users WHERE role = 'CLIENT') LIMIT 1
) AS c ON TRUE
JOIN LATERAL (
    SELECT id FROM users WHERE role = 'CONTRACTOR' ORDER BY id
    OFFSET (i * 53) % (SELECT count(*) FROM users WHERE role = 'CONTRACTOR') LIMIT 1
) AS k ON TRUE;

-- ---------------------------------------------------------------------
-- milestones: 2 to 4 per project, summing to the project total.
-- Released milestones are at the front, because the API only ever pays
-- in position order.
-- ---------------------------------------------------------------------
INSERT INTO milestones (project_id, position, title, amount_paise, status, created_at)
SELECT
    m.project_id,
    m.pos,
    (ARRAY['Site prep and demolition','Plumbing rough-in','Electrical rough-in',
           'Tiling and flooring','Carpentry and fit-out','Painting and finishing'])[m.pos],
    100000 + ((m.project_id * 7919 + m.pos * 104729) % 900000),
    CASE m.pstatus
        WHEN 'OPEN'      THEN 'PENDING'
        WHEN 'COMPLETED' THEN 'RELEASED'
        WHEN 'DISPUTED'  THEN CASE WHEN m.pos = m.n THEN 'SUBMITTED' ELSE 'RELEASED' END
        ELSE CASE
            WHEN m.pos <= (m.project_id % 3) THEN 'RELEASED'
            WHEN m.pos = (m.project_id % 3) + 1 THEN 'SUBMITTED'
            ELSE 'PENDING'
        END
    END,
    m.created_at + (m.pos * INTERVAL '3 days')
FROM (
    SELECT p.id AS project_id, p.status AS pstatus, p.created_at,
           2 + (p.id % 3) AS n, gs AS pos
    FROM projects p
    CROSS JOIN LATERAL generate_series(1, 2 + (p.id % 3)) AS gs
) AS m;

-- A slice of ACTIVE projects gets one rejected milestone, so the proof
-- history has a rejection to read.
UPDATE milestones m
SET status = 'REJECTED'
WHERE m.status = 'PENDING'
  AND m.project_id % 11 = 0
  AND m.position = (SELECT max(position) FROM milestones WHERE project_id = m.project_id);

-- Make total_paise agree with the milestones it is supposed to summarise.
UPDATE projects p
SET total_paise = s.total
FROM (SELECT project_id, sum(amount_paise) AS total FROM milestones GROUP BY project_id) AS s
WHERE s.project_id = p.id;

-- ---------------------------------------------------------------------
-- proofs: one per milestone that has been submitted, approved or
-- rejected. submitted_by is the project's contractor, reviewed_by its
-- client, so reviewer <> submitter holds.
-- ---------------------------------------------------------------------
INSERT INTO proofs (milestone_id, submitted_by, url, note, status,
                    review_note, reviewed_by, reviewed_at, created_at)
SELECT
    m.id,
    p.contractor_id,
    'https://proofs.buildbond.test/' || m.project_id || '/' || m.position || '.jpg',
    CASE WHEN m.position % 2 = 0 THEN 'Photos taken after the site was cleared.' ELSE '' END,
    CASE m.status
        WHEN 'RELEASED'  THEN 'APPROVED'
        WHEN 'SUBMITTED' THEN 'SUBMITTED'
        ELSE 'REJECTED'
    END,
    CASE WHEN m.status = 'REJECTED'
         THEN 'The photos do not show the completed tiling in the second bedroom. Please resubmit.'
         ELSE NULL END,
    CASE WHEN m.status = 'SUBMITTED' THEN NULL ELSE p.client_id END,
    CASE WHEN m.status = 'SUBMITTED' THEN NULL ELSE m.created_at + INTERVAL '2 days' END,
    m.created_at + INTERVAL '1 day'
FROM milestones m
JOIN projects p ON p.id = m.project_id
WHERE m.status IN ('RELEASED', 'SUBMITTED', 'REJECTED')
  AND p.status <> 'OPEN';

-- ---------------------------------------------------------------------
-- ledger_entries: one deposit per funded project, one release per
-- released milestone. Both uniqueness rules are load bearing here — a
-- duplicate row would abort this insert, which is the point of the
-- partial unique indexes.
-- ---------------------------------------------------------------------
INSERT INTO ledger_entries (project_id, milestone_id, kind, amount_paise, note, created_at)
SELECT p.id, NULL, 'DEPOSIT', p.total_paise, 'Demo escrow deposit', p.created_at + INTERVAL '1 day'
FROM projects p
WHERE p.status <> 'OPEN';

INSERT INTO ledger_entries (project_id, milestone_id, kind, amount_paise, note, created_at)
SELECT m.project_id, m.id, 'RELEASE', m.amount_paise,
       'Released after proof approval', m.created_at + INTERVAL '3 days'
FROM milestones m
WHERE m.status = 'RELEASED';

-- ---------------------------------------------------------------------
-- disputes: every DISPUTED project has exactly one OPEN dispute on the
-- milestone it is stuck on; a handful of old withdrawn disputes sit on
-- otherwise healthy projects so the history is not all one shape.
-- ---------------------------------------------------------------------
INSERT INTO disputes (project_id, milestone_id, raised_by, reason, status, created_at, resolved_at)
SELECT m.project_id, m.id, p.contractor_id,
       'The client asked for extra work outside the agreed scope without changing the milestone amount.',
       'OPEN', m.created_at + INTERVAL '4 days', NULL
FROM milestones m
JOIN projects p ON p.id = m.project_id
WHERE m.status = 'SUBMITTED' AND p.status = 'DISPUTED';

INSERT INTO disputes (project_id, milestone_id, raised_by, reason, status, created_at, resolved_at)
SELECT m.project_id, m.id, p.client_id,
       'Finish quality was disputed on site and both sides agreed to redo the last coat.',
       'WITHDRAWN', m.created_at + INTERVAL '5 days', m.created_at + INTERVAL '8 days'
FROM milestones m
JOIN projects p ON p.id = m.project_id
WHERE m.status = 'RELEASED' AND p.status = 'ACTIVE' AND m.id % 13 = 0;

-- ---------------------------------------------------------------------
-- events: created for every project, then one row per later transition,
-- mirroring the strings the routes write.
-- ---------------------------------------------------------------------
INSERT INTO events (project_id, actor_id, kind, message, created_at)
SELECT p.id, p.client_id, 'PROJECT_CREATED',
       'Client created "' || p.title || '" with milestones.', p.created_at
FROM projects p;

INSERT INTO events (project_id, actor_id, kind, message, created_at)
SELECT p.id, p.contractor_id, 'CONTRACTOR_ACCEPTED',
       'Contractor accepted the project.', p.created_at + INTERVAL '6 hours'
FROM projects p
WHERE p.contractor_id IS NOT NULL;

INSERT INTO events (project_id, actor_id, kind, message, created_at)
SELECT p.id, p.client_id, 'PROJECT_FUNDED',
       'Client deposited the full amount into demo escrow.', p.created_at + INTERVAL '1 day'
FROM projects p
WHERE p.status <> 'OPEN';

INSERT INTO events (project_id, actor_id, kind, message, created_at)
SELECT m.project_id, p.client_id, 'MILESTONE_RELEASED',
       'Client approved "' || m.title || '" and released the milestone amount.',
       m.created_at + INTERVAL '3 days'
FROM milestones m
JOIN projects p ON p.id = m.project_id
WHERE m.status = 'RELEASED';

INSERT INTO events (project_id, actor_id, kind, message, created_at)
SELECT d.project_id, d.raised_by, 'DISPUTE_RAISED',
       'Dispute raised on the active milestone.', d.created_at
FROM disputes d;

INSERT INTO events (project_id, actor_id, kind, message, created_at)
SELECT d.project_id, d.raised_by, 'DISPUTE_WITHDRAWN',
       'Dispute withdrawn; the project is active again.', d.resolved_at
FROM disputes d
WHERE d.status = 'WITHDRAWN';

COMMIT;

ANALYZE;

-- Row counts, so the run log proves what was loaded.
SELECT 'users'          AS table_name, count(*) FROM users
UNION ALL SELECT 'projects',       count(*) FROM projects
UNION ALL SELECT 'milestones',     count(*) FROM milestones
UNION ALL SELECT 'proofs',         count(*) FROM proofs
UNION ALL SELECT 'ledger_entries', count(*) FROM ledger_entries
UNION ALL SELECT 'events',         count(*) FROM events
UNION ALL SELECT 'disputes',       count(*) FROM disputes
ORDER BY table_name;
