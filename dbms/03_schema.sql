-- =====================================================================
-- BuildBond — AP DBMS CP2 schema
-- Seven-table normalized design from:
--   * BuildBond README "Database Design"
--   * dbms/01_normalization.md (1NF -> 2NF -> 3NF, with BCNF notes)
--
-- Target: PostgreSQL 15+.
-- Run on an empty database:
--   psql -d buildbond_ap -v ON_ERROR_STOP=1 -f dbms/03_schema.sql
--
-- Money is stored as integer paise (1 rupee = 100 paise), never as float.
-- The ledger is append-only; there is no mutable balance column.
-- The application state machine and role checks remain in the API, while
-- the constraints below enforce the data shape and the money uniqueness
-- rules at the database level.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- users: clients and contractors.
-- email is stored lowercase by the API; the CHECK keeps it normalized.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
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
    'Accounts for clients and contractors. email is a natural candidate key; password_hash stores a bcrypt hash, never a plain password.';

-- ---------------------------------------------------------------------
-- projects: one client and (after acceptance) one contractor.
-- total_paise is the sum of the project's milestone amounts. It is
-- intentionally stored once for the project; the creation transaction
-- computes it from the 2–5 milestones and projects cannot be edited.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS projects (
    id             SERIAL PRIMARY KEY,
    client_id      INTEGER NOT NULL,
    contractor_id  INTEGER,
    title          TEXT NOT NULL,
    total_paise    INTEGER NOT NULL,
    status         TEXT NOT NULL DEFAULT 'OPEN',

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
    'Derived once from the sum of the project milestone amounts; the app does not allow project editing after creation.';
COMMENT ON COLUMN projects.contractor_id IS
    'NULL while the project is OPEN; set when a contractor accepts the job.';
COMMENT ON TABLE projects IS
    'A high-value job between one client and at most one contractor. The 2–5 milestone count and CLIENT/CONTRACTOR roles are enforced by the API.';

-- ---------------------------------------------------------------------
-- milestones: ordered payment steps. position is unique per project and
-- limited to 1..5 because a project has 2–5 milestones.
-- The extra UNIQUE (id, project_id) lets child tables enforce that a
-- referenced milestone belongs to the same project.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS milestones (
    id           SERIAL PRIMARY KEY,
    project_id   INTEGER NOT NULL,
    position     INTEGER NOT NULL,
    title        TEXT NOT NULL,
    amount_paise INTEGER NOT NULL,
    status       TEXT NOT NULL DEFAULT 'PENDING',

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
    'Ordered steps of a project. The API enforces 2–5 milestones; position is 1..5 and unique per project.';

-- ---------------------------------------------------------------------
-- proofs: append-only proof history. A milestone may have many proofs
-- over time, but at most one SUBMITTED proof at a time (partial unique
-- index below). A review must have a reviewer; a rejection must have a
-- reason. The reviewer cannot be the submitter.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS proofs (
    id             SERIAL PRIMARY KEY,
    milestone_id   INTEGER NOT NULL,
    submitted_by   INTEGER NOT NULL,
    url            TEXT NOT NULL,
    note           TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'SUBMITTED',
    review_note    TEXT,
    reviewed_by    INTEGER,

    CONSTRAINT proofs_milestone_id_fkey
        FOREIGN KEY (milestone_id) REFERENCES milestones (id) ON DELETE CASCADE,
    CONSTRAINT proofs_submitted_by_fkey
        FOREIGN KEY (submitted_by) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT proofs_reviewed_by_fkey
        FOREIGN KEY (reviewed_by) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT proofs_url_check CHECK (url ~ '^https?://[^ ]+$'),
    CONSTRAINT proofs_note_not_blank CHECK (length(btrim(note)) > 0),
    CONSTRAINT proofs_status_check
        CHECK (status IN ('SUBMITTED', 'APPROVED', 'REJECTED')),
    CONSTRAINT proofs_reviewer_distinct
        CHECK (reviewed_by IS NULL OR reviewed_by <> submitted_by),
    CONSTRAINT proofs_review_state_check CHECK (
        (status = 'SUBMITTED'
            AND reviewed_by IS NULL
            AND review_note IS NULL)
        OR (status = 'APPROVED'
            AND reviewed_by IS NOT NULL)
        OR (status = 'REJECTED'
            AND reviewed_by IS NOT NULL
            AND review_note IS NOT NULL
            AND length(btrim(review_note)) > 0)
    )
);

COMMENT ON TABLE proofs IS
    'Every proof submission, including history. Old rejected proofs are kept when the contractor resubmits.';

-- ---------------------------------------------------------------------
-- ledger_entries: append-only simulated money. A DEPOSIT has no
-- milestone; a RELEASE belongs to exactly one milestone. One deposit per
-- project and one release per milestone are enforced by partial unique
-- indexes. The composite (milestone_id, project_id) FK prevents a release
-- from referring to a milestone in another project.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ledger_entries (
    id           SERIAL PRIMARY KEY,
    project_id   INTEGER NOT NULL,
    milestone_id INTEGER,
    kind         TEXT NOT NULL,
    amount_paise INTEGER NOT NULL,

    CONSTRAINT ledger_entries_project_id_fkey
        FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
    CONSTRAINT ledger_entries_milestone_id_fkey
        FOREIGN KEY (milestone_id) REFERENCES milestones (id) ON DELETE CASCADE,
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
    'Append-only simulated money. deposited/released/held are derived from these rows; no balance column exists.';

-- ---------------------------------------------------------------------
-- events: human-readable activity trail. Every project mutation writes
-- one row in the same transaction.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS events (
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
    'Append-only human-readable activity timeline, read with the project detail.';

-- ---------------------------------------------------------------------
-- disputes: a participant raises a freeze on a milestone. At most one
-- OPEN dispute per milestone. Withdrawing changes status, not a delete.
-- The composite FK keeps the dispute's project aligned with its milestone.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS disputes (
    id           SERIAL PRIMARY KEY,
    project_id   INTEGER NOT NULL,
    milestone_id INTEGER NOT NULL,
    raised_by    INTEGER NOT NULL,
    reason       TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'OPEN',

    CONSTRAINT disputes_project_id_fkey
        FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
    CONSTRAINT disputes_milestone_id_fkey
        FOREIGN KEY (milestone_id) REFERENCES milestones (id) ON DELETE CASCADE,
    CONSTRAINT disputes_milestone_project_fkey
        FOREIGN KEY (milestone_id, project_id)
        REFERENCES milestones (id, project_id) ON DELETE CASCADE,
    CONSTRAINT disputes_raised_by_fkey
        FOREIGN KEY (raised_by) REFERENCES users (id) ON DELETE RESTRICT,
    CONSTRAINT disputes_reason_not_blank CHECK (length(btrim(reason)) > 0),
    CONSTRAINT disputes_status_check
        CHECK (status IN ('OPEN', 'WITHDRAWN'))
);

COMMENT ON TABLE disputes IS
    'Freeze records raised by a project participant. Only the raiser may withdraw; withdrawal sets status to WITHDRAWN.';

-- ---------------------------------------------------------------------
-- Business uniqueness that a plain UNIQUE constraint cannot express:
--   * one active proof per milestone;
--   * one deposit per project;
--   * one release per milestone;
--   * one open dispute per milestone.
-- ---------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS proofs_one_submitted_per_milestone
    ON proofs (milestone_id)
    WHERE status = 'SUBMITTED';

CREATE UNIQUE INDEX IF NOT EXISTS ledger_entries_one_deposit_per_project
    ON ledger_entries (project_id)
    WHERE kind = 'DEPOSIT';

CREATE UNIQUE INDEX IF NOT EXISTS ledger_entries_one_release_per_milestone
    ON ledger_entries (milestone_id)
    WHERE kind = 'RELEASE';

CREATE UNIQUE INDEX IF NOT EXISTS disputes_one_open_per_milestone
    ON disputes (milestone_id)
    WHERE status = 'OPEN';

-- Foreign-key lookup indexes used by the app's project-detail and
-- dashboard queries. They do not change the schema's meaning.
CREATE INDEX IF NOT EXISTS projects_client_id_idx ON projects (client_id);
CREATE INDEX IF NOT EXISTS projects_contractor_id_idx ON projects (contractor_id);
CREATE INDEX IF NOT EXISTS proofs_milestone_id_idx ON proofs (milestone_id);
CREATE INDEX IF NOT EXISTS proofs_submitted_by_idx ON proofs (submitted_by);
CREATE INDEX IF NOT EXISTS proofs_reviewed_by_idx ON proofs (reviewed_by);
CREATE INDEX IF NOT EXISTS ledger_entries_project_id_idx ON ledger_entries (project_id);
CREATE INDEX IF NOT EXISTS ledger_entries_milestone_id_idx ON ledger_entries (milestone_id);
CREATE INDEX IF NOT EXISTS events_project_id_idx ON events (project_id);
CREATE INDEX IF NOT EXISTS events_created_at_idx ON events (created_at);
CREATE INDEX IF NOT EXISTS disputes_project_id_idx ON disputes (project_id);
CREATE INDEX IF NOT EXISTS disputes_milestone_id_idx ON disputes (milestone_id);
CREATE INDEX IF NOT EXISTS disputes_raised_by_idx ON disputes (raised_by);

COMMIT;
