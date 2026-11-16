-- =====================================================================
-- Dream11 Fantasy Sports Database — Phase 2
-- File: sql/01_schema.sql
-- Team: T0060 (Section C)
-- Compatibility: PostgreSQL 15+ (Tested on PostgreSQL 17.10)
-- Description:
--   Creates the dream11 schema and all 10 relational tables with
--   appropriate PostgreSQL data types, primary keys, foreign keys
--   with justified ON DELETE actions, UNIQUE constraints, NOT NULL
--   constraints, and validated CHECK constraints.
--   No manually tuned performance indexes are created in Phase 2.
-- =====================================================================

DROP SCHEMA IF EXISTS dream11 CASCADE;
CREATE SCHEMA dream11;
SET search_path TO dream11;

-- ---------------------------------------------------------------------
-- 1. teams
-- Real cricket teams (IPL franchises and national teams)
-- ---------------------------------------------------------------------
CREATE TABLE dream11.teams (
    team_id     INTEGER      NOT NULL,
    team_name   VARCHAR(100) NOT NULL,
    short_name  VARCHAR(10)  NOT NULL,
    team_type   VARCHAR(20)  NOT NULL,

    CONSTRAINT pk_teams PRIMARY KEY (team_id),
    CONSTRAINT uq_teams_team_name UNIQUE (team_name),
    CONSTRAINT uq_teams_short_name UNIQUE (short_name),
    CONSTRAINT chk_teams_short_name_format CHECK (short_name ~ '^[A-Z]{2,5}$'),
    CONSTRAINT chk_teams_team_type CHECK (team_type IN ('FRANCHISE', 'INTERNATIONAL'))
);

-- ---------------------------------------------------------------------
-- 2. players
-- Real players belonging to squads, with role, credit cost, and status
-- ---------------------------------------------------------------------
CREATE TABLE dream11.players (
    player_id   INTEGER      NOT NULL,
    full_name   VARCHAR(120) NOT NULL,
    team_id     INTEGER      NOT NULL,
    role        VARCHAR(10)  NOT NULL,
    credits     NUMERIC(4,1) NOT NULL,
    is_active   BOOLEAN      NOT NULL,

    CONSTRAINT pk_players PRIMARY KEY (player_id),
    -- ON DELETE RESTRICT: prevent deleting a real team that still has squad players
    CONSTRAINT fk_players_team FOREIGN KEY (team_id)
        REFERENCES dream11.teams (team_id) ON DELETE RESTRICT,
    CONSTRAINT chk_players_role CHECK (role IN ('WK', 'BAT', 'AR', 'BOWL')),
    CONSTRAINT chk_players_credits_range CHECK (credits BETWEEN 5.0 AND 15.0)
);

-- ---------------------------------------------------------------------
-- 3. matches
-- Real cricket matches scheduled across tournaments
-- ---------------------------------------------------------------------
CREATE TABLE dream11.matches (
    match_id      INTEGER      NOT NULL,
    tournament    VARCHAR(80)  NOT NULL,
    home_team_id  INTEGER      NOT NULL,
    away_team_id  INTEGER      NOT NULL,
    venue         VARCHAR(150) NOT NULL,
    starts_at     TIMESTAMPTZ  NOT NULL,
    status        VARCHAR(20)  NOT NULL,

    CONSTRAINT pk_matches PRIMARY KEY (match_id),
    -- ON DELETE RESTRICT: preserve historical match fixtures if a team deletion is attempted
    CONSTRAINT fk_matches_home_team FOREIGN KEY (home_team_id)
        REFERENCES dream11.teams (team_id) ON DELETE RESTRICT,
    CONSTRAINT fk_matches_away_team FOREIGN KEY (away_team_id)
        REFERENCES dream11.teams (team_id) ON DELETE RESTRICT,
    CONSTRAINT chk_matches_distinct_teams CHECK (home_team_id <> away_team_id),
    CONSTRAINT chk_matches_status CHECK (status IN ('UPCOMING', 'LIVE', 'COMPLETED', 'ABANDONED'))
);

-- ---------------------------------------------------------------------
-- 4. player_match_stats
-- Per-match performance scorecard and calculated fantasy points per player
-- ---------------------------------------------------------------------
CREATE TABLE dream11.player_match_stats (
    match_id        INTEGER      NOT NULL,
    player_id       INTEGER      NOT NULL,
    runs            SMALLINT     NOT NULL,
    balls_faced     SMALLINT     NOT NULL,
    fours           SMALLINT     NOT NULL,
    sixes           SMALLINT     NOT NULL,
    wickets         SMALLINT     NOT NULL,
    catches         SMALLINT     NOT NULL,
    fantasy_points  NUMERIC(6,1) NOT NULL,

    CONSTRAINT pk_player_match_stats PRIMARY KEY (match_id, player_id),
    -- ON DELETE CASCADE: if an entire match is purged, its dependent scorecard rows are removed with it
    CONSTRAINT fk_pms_match FOREIGN KEY (match_id)
        REFERENCES dream11.matches (match_id) ON DELETE CASCADE,
    -- ON DELETE RESTRICT: never allow deleting a player who has recorded match performances
    CONSTRAINT fk_pms_player FOREIGN KEY (player_id)
        REFERENCES dream11.players (player_id) ON DELETE RESTRICT,
    CONSTRAINT chk_pms_non_negative_stats CHECK (
        runs >= 0 AND balls_faced >= 0 AND fours >= 0 AND sixes >= 0 AND wickets >= 0 AND catches >= 0
    ),
    CONSTRAINT chk_pms_wickets_range CHECK (wickets <= 10)
);

-- ---------------------------------------------------------------------
-- 5. users
-- Registered Dream11 platform users and compliance attributes
-- ---------------------------------------------------------------------
CREATE TABLE dream11.users (
    user_id     INTEGER      NOT NULL,
    username    VARCHAR(50)  NOT NULL,
    phone       CHAR(10)     NOT NULL,
    email       VARCHAR(254) NULL,
    state_code  CHAR(2)      NOT NULL,
    kyc_status  VARCHAR(20)  NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL,

    CONSTRAINT pk_users PRIMARY KEY (user_id),
    CONSTRAINT uq_users_username UNIQUE (username),
    CONSTRAINT uq_users_phone UNIQUE (phone),
    CONSTRAINT uq_users_email UNIQUE (email),
    CONSTRAINT chk_users_username_format CHECK (username ~ '^[A-Za-z0-9_]+$'),
    CONSTRAINT chk_users_phone_format CHECK (phone ~ '^[0-9]{10}$'),
    CONSTRAINT chk_users_state_code_format CHECK (state_code ~ '^[A-Z]{2}$'),
    CONSTRAINT chk_users_kyc_status CHECK (kyc_status IN ('PENDING', 'VERIFIED', 'REJECTED'))
);

-- ---------------------------------------------------------------------
-- 6. user_teams
-- Fantasy teams created by users for specific matches
-- ---------------------------------------------------------------------
CREATE TABLE dream11.user_teams (
    user_team_id     INTEGER      NOT NULL,
    user_id          INTEGER      NOT NULL,
    match_id         INTEGER      NOT NULL,
    team_label       VARCHAR(10)  NOT NULL,
    captain_id       INTEGER      NOT NULL,
    vice_captain_id  INTEGER      NOT NULL,
    total_points     NUMERIC(7,1) NULL,
    created_at       TIMESTAMPTZ  NOT NULL,

    CONSTRAINT pk_user_teams PRIMARY KEY (user_team_id),
    CONSTRAINT uq_user_teams_user_match_label UNIQUE (user_id, match_id, team_label),
    -- ON DELETE RESTRICT: preserve fantasy teams for contest and audit history
    CONSTRAINT fk_user_teams_user FOREIGN KEY (user_id)
        REFERENCES dream11.users (user_id) ON DELETE RESTRICT,
    CONSTRAINT fk_user_teams_match FOREIGN KEY (match_id)
        REFERENCES dream11.matches (match_id) ON DELETE RESTRICT,
    CONSTRAINT fk_user_teams_captain FOREIGN KEY (captain_id)
        REFERENCES dream11.players (player_id) ON DELETE RESTRICT,
    CONSTRAINT fk_user_teams_vice_captain FOREIGN KEY (vice_captain_id)
        REFERENCES dream11.players (player_id) ON DELETE RESTRICT,
    CONSTRAINT chk_user_teams_distinct_leaders CHECK (captain_id <> vice_captain_id),
    CONSTRAINT chk_user_teams_label_format CHECK (team_label ~ '^T[1-9][0-9]*$')
);

-- ---------------------------------------------------------------------
-- 7. user_team_players
-- Associative table mapping fantasy teams to their selected players
-- ---------------------------------------------------------------------
CREATE TABLE dream11.user_team_players (
    user_team_id  INTEGER NOT NULL,
    player_id     INTEGER NOT NULL,

    CONSTRAINT pk_user_team_players PRIMARY KEY (user_team_id, player_id),
    -- ON DELETE CASCADE: roster line-items are weak dependents of the parent fantasy team
    CONSTRAINT fk_utp_user_team FOREIGN KEY (user_team_id)
        REFERENCES dream11.user_teams (user_team_id) ON DELETE CASCADE,
    -- ON DELETE RESTRICT: prevent deleting a player referenced in any fantasy team roster
    CONSTRAINT fk_utp_player FOREIGN KEY (player_id)
        REFERENCES dream11.players (player_id) ON DELETE RESTRICT
);

-- ---------------------------------------------------------------------
-- 8. contests
-- Contests offered for matches (Mega, Small, Head-to-Head, Private)
-- ---------------------------------------------------------------------
CREATE TABLE dream11.contests (
    contest_id     INTEGER       NOT NULL,
    match_id       INTEGER       NOT NULL,
    contest_name   VARCHAR(120)  NOT NULL,
    contest_type   VARCHAR(20)   NOT NULL,
    entry_fee      NUMERIC(10,2) NOT NULL,
    total_spots    INTEGER       NOT NULL,
    prize_pool     NUMERIC(12,2) NOT NULL,
    is_guaranteed  BOOLEAN       NOT NULL,
    invite_code    VARCHAR(20)   NULL,

    CONSTRAINT pk_contests PRIMARY KEY (contest_id),
    CONSTRAINT uq_contests_invite_code UNIQUE (invite_code),
    -- ON DELETE RESTRICT: preserve contests and their financial pools if match deletion is attempted
    CONSTRAINT fk_contests_match FOREIGN KEY (match_id)
        REFERENCES dream11.matches (match_id) ON DELETE RESTRICT,
    CONSTRAINT chk_contests_type CHECK (contest_type IN ('MEGA', 'SMALL', 'HEAD_TO_HEAD', 'PRIVATE')),
    CONSTRAINT chk_contests_amounts_spots CHECK (entry_fee >= 0 AND total_spots >= 2 AND prize_pool >= 0),
    CONSTRAINT chk_contests_h2h_spots CHECK (contest_type <> 'HEAD_TO_HEAD' OR total_spots = 2),
    CONSTRAINT chk_contests_private_invite CHECK (
        (contest_type = 'PRIVATE' AND invite_code IS NOT NULL)
        OR (contest_type <> 'PRIVATE' AND invite_code IS NULL)
    )
);

-- ---------------------------------------------------------------------
-- 9. contest_entries
-- Fantasy teams entered into contests, with final rank and winnings
-- ---------------------------------------------------------------------
CREATE TABLE dream11.contest_entries (
    entry_id      INTEGER       NOT NULL,
    contest_id    INTEGER       NOT NULL,
    user_team_id  INTEGER       NOT NULL,
    joined_at     TIMESTAMPTZ   NOT NULL,
    final_rank    INTEGER       NULL,
    winnings      NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    CONSTRAINT pk_contest_entries PRIMARY KEY (entry_id),
    -- Prevents the same fantasy team from entering the same contest twice (also required by W02 ON CONFLICT)
    CONSTRAINT uq_contest_entries_contest_team UNIQUE (contest_id, user_team_id),
    -- ON DELETE RESTRICT: contest entries are financial and leaderboard records that must not be cascaded away
    CONSTRAINT fk_ce_contest FOREIGN KEY (contest_id)
        REFERENCES dream11.contests (contest_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ce_user_team FOREIGN KEY (user_team_id)
        REFERENCES dream11.user_teams (user_team_id) ON DELETE RESTRICT,
    CONSTRAINT chk_ce_final_rank CHECK (final_rank IS NULL OR final_rank >= 1),
    CONSTRAINT chk_ce_winnings CHECK (winnings >= 0)
);

-- ---------------------------------------------------------------------
-- 10. wallet_transactions
-- Immutable financial ledger of user wallet credits and debits
-- ---------------------------------------------------------------------
CREATE TABLE dream11.wallet_transactions (
    txn_id              INTEGER       NOT NULL,
    user_id             INTEGER       NOT NULL,
    txn_type            VARCHAR(20)   NOT NULL,
    amount              NUMERIC(12,2) NOT NULL,
    reference_entry_id  INTEGER       NULL,
    status              VARCHAR(20)   NOT NULL,
    created_at          TIMESTAMPTZ   NOT NULL,

    CONSTRAINT pk_wallet_transactions PRIMARY KEY (txn_id),
    -- ON DELETE RESTRICT: financial ledger entries must never be deleted or orphaned
    CONSTRAINT fk_wt_user FOREIGN KEY (user_id)
        REFERENCES dream11.users (user_id) ON DELETE RESTRICT,
    CONSTRAINT fk_wt_reference_entry FOREIGN KEY (reference_entry_id)
        REFERENCES dream11.contest_entries (entry_id) ON DELETE RESTRICT,
    CONSTRAINT chk_wt_txn_type CHECK (
        txn_type IN ('DEPOSIT', 'ENTRY_FEE', 'WINNINGS', 'REFUND', 'BONUS', 'WITHDRAWAL')
    ),
    CONSTRAINT chk_wt_status CHECK (status IN ('SUCCESS', 'PENDING', 'FAILED')),
    CONSTRAINT chk_wt_amount_positive CHECK (amount > 0),
    CONSTRAINT chk_wt_reference_entry_consistency CHECK (
        (txn_type IN ('ENTRY_FEE', 'WINNINGS', 'REFUND') AND reference_entry_id IS NOT NULL)
        OR (txn_type IN ('DEPOSIT', 'BONUS', 'WITHDRAWAL') AND reference_entry_id IS NULL)
    )
);

