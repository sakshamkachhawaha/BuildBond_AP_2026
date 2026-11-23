-- =====================================================================
-- BuildBond — DBMS CP2 schema, revision 2
--
-- Supersedes the first CP2 submission. Two things changed; the design
-- itself did not.
--
--   1. Nine columns the running application actually writes were added.
--      They were missing because the first CP2 was written from the
--      README's table sketch, before server/db/schema.sql existed:
--        projects.description, projects.created_at
--        milestones.created_at
--        proofs.created_at, proofs.reviewed_at
--        ledger_entries.note, ledger_entries.created_at
--        disputes.created_at, disputes.resolved_at
--      Every query in 04_queries.sql that selects p.* or orders by
--      created_at needs them.
--
--   2. The index set now matches the statements the API really runs, and
--      two redundant single-column foreign keys were dropped because the
--      composite foreign keys already enforce the same condition.
--
-- Seven tables, unchanged. Money is integer paise, never a float. The
-- ledger is append-only and there is no mutable balance column, so
-- deposited / released / held are always derived from the rows.
--
-- Target: PostgreSQL 15+. Verified on 15.18.
-- Apply to an empty database:
--   createdb buildbond_ap
--   psql -d buildbond_ap -v ON_ERROR_STOP=1 -f dbms/03_schema.sql
--
-- Column set and constraint behaviour match server/db/schema.sql on the
-- application's main branch (commit 00f0d4a). Every place where this
-- file is deliberately stricter is listed at the bottom.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- users — clients and contractors.
-- The API lower-cases email before insert; the CHECK keeps the stored
-- form normalised even when a row arrives from psql. password_hash holds
-- a bcrypt digest, never a plain password.
-- ---------------------------------------------------------------------
CREATE TABLE users (
    id            SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    email         TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT users_email_key UNIQUE (email),
    CONSTRAINT users_name_not_blank CHECK (length(btrim(name)) > 0),
    CONSTRAINT users_email_format CHECK (email ~ '^[^@ ]+@[^@ ]+\.[^@ ]+$'),
    CONSTRAINT users_email_lowercase CHECK (email = lower(email)),
    CONSTRAINT users_password_hash_not_blank CHECK (length(password_hash) > 0),
    CONSTRAINT users_role_check CHECK (role IN ('CLIENT', 'CONTRACTOR'))
);

COMMENT ON TABLE users IS
    'Accounts for clients and contractors. email is a natural candidate key.';
COMMENT ON COLUMN users.password_hash IS
    'bcrypt digest; the API hashes at 10 rounds and never stores the plain password.';

-- ---------------------------------------------------------------------
-- projects — one client, and one contractor after acceptance.
-- total_paise is the sum of the project's milestone amounts. It is
-- computed once inside the creation transaction, and the API has no
-- project-edit route, so it cannot drift away from the milestones.
-- ---------------------------------------------------------------------
CREATE TABLE projects (
    id             SERIAL PRIMARY KEY,
    client_id      INTEGER NOT NULL,
    contractor_id  INTEGER,
    title          TEXT NOT NULL,
    description    TEXT NOT NULL DEFAULT '',
    total_paise    INTEGER NOT NULL,
    status         TEXT NOT NULL DEFAULT 'OPEN',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT projects_client_id_fkey
        FOREIGN KEY (client_id) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT projects_contractor_id_fkey
        FOREIGN KEY (contractor_id) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT projects_title_not_blank CHECK (length(btrim(title)) > 0),
    CONSTRAINT projects_total_positive CHECK (total_paise > 0),
    CONSTRAINT projects_status_check
        CHECK (status IN ('OPEN', 'ACTIVE', 'DISPUTED', 'COMPLETED')),
    CONSTRAINT projects_distinct_parties
        CHECK (contractor_id IS NULL OR contractor_id <> client_id)
);

COMMENT ON COLUMN projects.total_paise IS
    'Sum of the project milestone amounts, computed once at creation.';
COMMENT ON COLUMN projects.contractor_id IS
    'NULL while the project is OPEN; set when a contractor accepts the job.';
COMMENT ON COLUMN projects.description IS
    'Brief the client writes at creation; the API defaults it to an empty string.';
COMMENT ON TABLE projects IS
    'A job between one client and at most one contractor. The 2-5 milestone count is an API rule, not a database one.';

-- ---------------------------------------------------------------------
-- milestones — ordered payment steps.
-- position is unique per project and capped at 5 because a project has
-- at most five milestones. UNIQUE (id, project_id) looks redundant
-- because id is already unique, but it is what lets ledger rows and
-- disputes carry a composite foreign key, so a release or a dispute
-- cannot name a milestone that belongs to a different project.
-- ---------------------------------------------------------------------
CREATE TABLE milestones (
    id           SERIAL PRIMARY KEY,
    project_id   INTEGER NOT NULL,
    position     INTEGER NOT NULL,
    title        TEXT NOT NULL,
    amount_paise INTEGER NOT NULL,
    status       TEXT NOT NULL DEFAULT 'PENDING',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT milestones_project_id_fkey
        FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
    CONSTRAINT milestones_project_position_key UNIQUE (project_id, position),
    CONSTRAINT milestones_id_project_key UNIQUE (id, project_id),
    CONSTRAINT milestones_position_check CHECK (position BETWEEN 1 AND 5),
    CONSTRAINT milestones_title_not_blank CHECK (length(btrim(title)) > 0),
    CONSTRAINT milestones_amount_positive CHECK (amount_paise > 0),
    CONSTRAINT milestones_status_check
        CHECK (status IN ('PENDING', 'SUBMITTED', 'REJECTED', 'RELEASED'))
);

COMMENT ON TABLE milestones IS
    'Ordered steps of a project. The API allows 2-5 per project and only moves them PENDING -> SUBMITTED -> RELEASED, or SUBMITTED -> REJECTED -> SUBMITTED.';
COMMENT ON CONSTRAINT milestones_id_project_key ON milestones IS
    'Not a business key. It is the target of the composite foreign keys in ledger_entries and disputes.';

-- ---------------------------------------------------------------------
-- proofs — append-only proof history.
-- A milestone can collect several proofs over its life (one rejected,
-- then one resubmitted), but at most one may be SUBMITTED at a time; the
-- partial unique index below enforces that. A review must name its
-- reviewer and carry a timestamp, a rejection must carry a reason, and
-- nobody reviews their own proof. note may be empty because the API lets
-- a contractor submit a link with no comment.
-- ---------------------------------------------------------------------
CREATE TABLE proofs (
    id             SERIAL PRIMARY KEY,
    milestone_id   INTEGER NOT NULL,
    submitted_by   INTEGER NOT NULL,
    url            TEXT NOT NULL,
    note           TEXT NOT NULL DEFAULT '',
    status         TEXT NOT NULL DEFAULT 'SUBMITTED',
    review_note    TEXT,
    reviewed_by    INTEGER,
    reviewed_at    TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT proofs_milestone_id_fkey
        FOREIGN KEY (milestone_id) REFERENCES milestones (id) ON DELETE CASCADE,
    CONSTRAINT proofs_submitted_by_fkey
        FOREIGN KEY (submitted_by) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT proofs_reviewed_by_fkey
        FOREIGN KEY (reviewed_by) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT proofs_url_check CHECK (url ~ '^https?://[^ ]+$'),
    CONSTRAINT proofs_status_check
        CHECK (status IN ('SUBMITTED', 'APPROVED', 'REJECTED')),
    CONSTRAINT proofs_reviewer_distinct
        CHECK (reviewed_by IS NULL OR reviewed_by <> submitted_by),
    CONSTRAINT proofs_review_state_check CHECK (
        (status = 'SUBMITTED'
            AND reviewed_by IS NULL
            AND reviewed_at IS NULL
            AND review_note IS NULL)
        OR (status = 'APPROVED'
            AND reviewed_by IS NOT NULL
            AND reviewed_at IS NOT NULL)
        OR (status = 'REJECTED'
            AND reviewed_by IS NOT NULL
            AND reviewed_at IS NOT NULL
            AND review_note IS NOT NULL
            AND length(btrim(review_note)) > 0)
    )
);

COMMENT ON TABLE proofs IS
    'Every proof submission, including history. Rejected proofs are kept when the contractor resubmits.';
COMMENT ON COLUMN proofs.reviewed_at IS
    'Written by the same UPDATE that sets status and reviewed_by, so the three never disagree.';

-- ---------------------------------------------------------------------
-- ledger_entries — append-only simulated money.
-- A DEPOSIT has no milestone; a RELEASE names exactly one. One deposit
-- per project and one release per milestone are enforced by partial
-- unique indexes, which is how the API detects a double funding attempt
-- before it happens. The composite foreign key is the part a plain
-- milestone_id reference cannot express: a release may only name a
-- milestone of the same project.
-- ---------------------------------------------------------------------
CREATE TABLE ledger_entries (
    id           SERIAL PRIMARY KEY,
    project_id   INTEGER NOT NULL,
    milestone_id INTEGER,
    kind         TEXT NOT NULL,
    amount_paise INTEGER NOT NULL,
    note         TEXT NOT NULL DEFAULT '',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT ledger_entries_project_id_fkey
        FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
    CONSTRAINT ledger_entries_milestone_project_fkey
        FOREIGN KEY (milestone_id, project_id)
        REFERENCES milestones (id, project_id) ON DELETE CASCADE,
    CONSTRAINT ledger_entries_kind_check
        CHECK (kind IN ('DEPOSIT', 'RELEASE')),
    CONSTRAINT ledger_entries_amount_positive CHECK (amount_paise > 0),
    CONSTRAINT ledger_entries_kind_milestone_check CHECK (
        (kind = 'DEPOSIT' AND milestone_id IS NULL)
        OR (kind = 'RELEASE' AND milestone_id IS NOT NULL)
    )
);

COMMENT ON TABLE ledger_entries IS
    'Append-only simulated money. The API derives deposited, released and held from these rows; no balance column exists.';
COMMENT ON COLUMN ledger_entries.note IS
    'Free text the API writes at insert time, e.g. the release reason.';

-- ---------------------------------------------------------------------
-- events — human-readable activity trail.
-- Every project mutation writes one row in the same transaction, so the
-- timeline and the state change can never disagree. kind is not
-- enumerated on purpose: the string comes from route code rather than a
-- shared constant, and a CHECK here would turn a one-line app change into
-- a migration.
-- ---------------------------------------------------------------------
CREATE TABLE events (
    id         SERIAL PRIMARY KEY,
    project_id INTEGER NOT NULL,
    actor_id   INTEGER NOT NULL,
    kind       TEXT NOT NULL,
    message    TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT events_project_id_fkey
        FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
    CONSTRAINT events_actor_id_fkey
        FOREIGN KEY (actor_id) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT events_kind_not_blank CHECK (length(btrim(kind)) > 0),
    CONSTRAINT events_message_not_blank CHECK (length(btrim(message)) > 0)
);

COMMENT ON TABLE events IS
    'Append-only activity timeline, read with the project detail.';

-- ---------------------------------------------------------------------
-- disputes — a participant freezes a milestone.
-- At most one OPEN dispute per milestone. Withdrawing changes status and
-- stamps resolved_at; it never deletes the row, so the history of a
-- contested milestone survives. The composite foreign key keeps the
-- dispute's project aligned with its milestone.
-- ---------------------------------------------------------------------
CREATE TABLE disputes (
    id           SERIAL PRIMARY KEY,
    project_id   INTEGER NOT NULL,
    milestone_id INTEGER NOT NULL,
    raised_by    INTEGER NOT NULL,
    reason       TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'OPEN',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at  TIMESTAMPTZ,

    CONSTRAINT disputes_project_id_fkey
        FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
    CONSTRAINT disputes_milestone_project_fkey
        FOREIGN KEY (milestone_id, project_id)
        REFERENCES milestones (id, project_id) ON DELETE CASCADE,
    CONSTRAINT disputes_raised_by_fkey
        FOREIGN KEY (raised_by) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT disputes_reason_not_blank CHECK (length(btrim(reason)) > 0),
    CONSTRAINT disputes_status_check
        CHECK (status IN ('OPEN', 'WITHDRAWN')),
    CONSTRAINT disputes_resolved_state_check CHECK (
        (status = 'OPEN' AND resolved_at IS NULL)
        OR (status = 'WITHDRAWN' AND resolved_at IS NOT NULL)
    )
);

COMMENT ON TABLE disputes IS
    'Freeze records raised by a project participant. Only the raiser may withdraw.';

-- ---------------------------------------------------------------------
-- Business rules a plain UNIQUE constraint cannot express, because they
-- depend on the row's status:
--   * one SUBMITTED proof per milestone;
--   * one DEPOSIT per project;
--   * one RELEASE per milestone;
--   * one OPEN dispute per milestone.
-- Partial unique indexes are exactly the tool for "unique, but only
-- among rows in this state".
-- ---------------------------------------------------------------------
CREATE UNIQUE INDEX proofs_one_submitted_per_milestone
    ON proofs (milestone_id)
    WHERE status = 'SUBMITTED';

CREATE UNIQUE INDEX ledger_entries_one_deposit_per_project
    ON ledger_entries (project_id)
    WHERE kind = 'DEPOSIT';

CREATE UNIQUE INDEX ledger_entries_one_release_per_milestone
    ON ledger_entries (milestone_id)
    WHERE kind = 'RELEASE';

CREATE UNIQUE INDEX disputes_one_open_per_milestone
    ON disputes (milestone_id)
    WHERE status = 'OPEN';

-- ---------------------------------------------------------------------
-- Lookup indexes. Each one exists because a statement in 04_queries.sql
-- filters or orders on those columns; none is speculative.
-- ---------------------------------------------------------------------
-- Dashboard list, getProjectForUser, getProjectById: "my projects".
CREATE INDEX projects_client_id_idx     ON projects (client_id);
CREATE INDEX projects_contractor_id_idx ON projects (contractor_id);

-- GET /api/jobs: WHERE status = 'OPEN' AND contractor_id IS NULL,
-- ordered by created_at DESC. A partial index matches the predicate
-- exactly, so it holds only unclaimed jobs instead of every project.
CREATE INDEX projects_open_idx
    ON projects (created_at DESC)
    WHERE status = 'OPEN' AND contractor_id IS NULL;

-- GET /api/projects/:id: proofs for a project, newest first. The
-- created_at DESC in the key lets the ORDER BY come from the index.
CREATE INDEX proofs_milestone_idx ON proofs (milestone_id, created_at DESC);

-- Ledger balance SUM and the project-detail ledger list.
CREATE INDEX ledger_project_idx ON ledger_entries (project_id);

-- Project detail timeline: WHERE project_id = $1 ORDER BY created_at.
CREATE INDEX events_project_idx ON events (project_id, created_at);

-- Project detail disputes list.
CREATE INDEX disputes_project_idx ON disputes (project_id);

COMMIT;

-- =====================================================================
-- Notes for the report and the viva
-- =====================================================================
--
-- Foreign keys: 13, not 15.
--   The first submission declared both a single-column reference
--   (ledger_entries.milestone_id -> milestones.id,
--    disputes.milestone_id  -> milestones.id) and a composite one on the
--   same column pair. The composite reference already implies the
--   single-column one, so the extra pair only added two more FK triggers
--   to fire on every insert. Removing them changes nothing that the
--   database allows or rejects, which is why the table-level behaviour
--   still matches the application.
--
-- Stricter than server/db/schema.sql, and why:
--   * users: email format, lower-case email, non-blank name.
--   * projects: non-blank title, distinct parties.
--   * milestones: non-blank title, position 1..5.
--   * proofs: URL scheme check, reviewer != submitter, review state must
--     agree with reviewer/reviewed_at/review_note.
--   * ledger_entries: positive amount, DEPOSIT/RELEASE shape.
--   * disputes: non-blank reason, resolved_at agrees with status.
--   All of these are conditions the API already checks in JavaScript.
--   Checking them again in the database is what stops a second client,
--   a psql session or a future script from writing a row the app would
--   consider impossible.
--
-- Looser than the first submission, on purpose:
--   * proofs.note no longer requires non-blank text. The API submits an
--     empty note when the contractor only pastes a link, so the old
--     CHECK would have rejected legitimate rows.
--
-- Deliberately absent:
--   * No CHECK enumerating events.kind. See the comment on that table.
--   * No trigger maintaining projects.total_paise. The sum is computed
--     once in the creation transaction and projects are immutable
--     afterwards; a trigger would add a write cost to every milestone
--     insert to protect a value that cannot change.
--   * No ON DELETE SET NULL anywhere. Every child row here is either
--     meaningless without its parent (CASCADE) or must block the delete
--     (RESTRICT), so a NULL-ed foreign key would create orphaned
--     history rather than protect it.
-- =====================================================================
