-- =====================================================================
-- Dream11 Fantasy Sports Database — Phase 4
-- File: sql/05_indexes.sql
-- Description:
--   Production-grade indexing script for query performance optimization.
--   Every index added is empirically justified by PostgreSQL query execution
--   plans (EXPLAIN ANALYZE BUFFERS) from the Phase 3 baseline workload.
--   Avoids duplicating existing PK and UNIQUE constraint indexes.
--
-- Existing constraint indexes (18 total - not recreated here):
--   teams: pk_teams (team_id), uq_teams_team_name (team_name), uq_teams_short_name (short_name)
--   players: pk_players (player_id)
--   matches: pk_matches (match_id)
--   player_match_stats: pk_player_match_stats (match_id, player_id)
--   users: pk_users (user_id), uq_users_username (username), uq_users_phone (phone), uq_users_email (email)
--   user_teams: pk_user_teams (user_team_id), uq_user_teams_user_match_label (user_id, match_id, team_label)
--   user_team_players: pk_user_team_players (user_team_id, player_id)
--   contests: pk_contests (contest_id), uq_contests_invite_code (invite_code)
--   contest_entries: pk_contest_entries (entry_id), uq_contest_entries_contest_team (contest_id, user_team_id)
--   wallet_transactions: pk_wallet_transactions (txn_id)
-- =====================================================================

SET search_path TO dream11;

-- ---------------------------------------------------------------------
-- 1. idx_user_team_players_player_id
-- Table: dream11.user_team_players
-- Type: Secondary B-tree index (Reverse FK / Join key)
-- Benefiting queries: R19, R02
-- Justification:
--   The primary key `pk_user_team_players` is defined on `(user_team_id, player_id)`.
--   Because `player_id` is the second column, seeking roster appearances by
--   `player_id` cannot use the PK index leading column. In baseline R19, this
--   caused 250 sequential scans of 439,925 rows (500,008 buffer hits, ~2,190 ms).
--   This reverse index enables index-only scans and fast joins on `player_id`.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_user_team_players_player_id
    ON dream11.user_team_players (player_id);

-- ---------------------------------------------------------------------
-- 2. idx_user_teams_match_id
-- Table: dream11.user_teams
-- Type: Composite B-tree index (FK + Ordering)
-- Benefiting queries: R02, R06, R08, W01, W02, W04
-- Justification:
--   The unique index `uq_user_teams_user_match_label` has `user_id` leading,
--   so queries filtering on `match_id` alone (e.g. match 207 or match 183)
--   were forced to sequentially scan all 39,975 rows of `user_teams`.
--   Including `user_team_id DESC` allows instant resolution of `max(user_team_id)`
--   in W02 via a single backward index seek, and provides efficient index
--   scans for roster rule auditing (R06), captain statistics (R08), and
--   points recomputation (W04).
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_user_teams_match_id
    ON dream11.user_teams (match_id, user_team_id DESC);

-- ---------------------------------------------------------------------
-- 3. idx_user_teams_user_id
-- Table: dream11.user_teams
-- Type: Composite B-tree index (FK + Surrogate Key)
-- Benefiting queries: R11, R15
-- Justification:
--   Accelerates queries that join `users` to `user_teams` across all matches.
--   While `uq_user_teams_user_match_label` has `user_id` as its leading column,
--   its key size is wider and includes `team_label`. A compact index on
--   `(user_id, user_team_id)` allows fast index-only scans and hash/merge joins.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_user_teams_user_id
    ON dream11.user_teams (user_id, user_team_id);

-- ---------------------------------------------------------------------
-- 4. idx_contest_entries_user_team_id
-- Table: dream11.contest_entries
-- Type: Secondary B-tree index (Reverse FK / Join key)
-- Benefiting queries: R11, R15, R17, R21, R25
-- Justification:
--   Existing unique index `uq_contest_entries_contest_team` has `contest_id`
--   leading `(contest_id, user_team_id)`. Joining from `user_teams` to
--   `contest_entries` on `user_team_id` forced sequential scans of all 42,746
--   entries. This reverse index enables index scans and efficient joins.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_contest_entries_user_team_id
    ON dream11.contest_entries (user_team_id, contest_id);

-- ---------------------------------------------------------------------
-- 5. idx_wallet_transactions_user_status
-- Table: dream11.wallet_transactions
-- Type: Covering composite B-tree index
-- Benefiting queries: R09
-- Justification:
--   In R09, a user reviews their ledger transactions with running balance
--   (`WHERE user_id = 1006 AND status = 'SUCCESS' ORDER BY created_at, txn_id`).
--   Without this index, PostgreSQL scanned all 118,343 rows.
--   By putting `(user_id, status)` leading and `(created_at, txn_id)` next,
--   the index filters immediately and delivers rows already in sort order,
--   avoiding a Sort node. `INCLUDE (txn_type, amount)` provides all remaining
--   columns directly from the index leaf pages, turning R09 into an Index Only Scan.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_user_status
    ON dream11.wallet_transactions (user_id, status, created_at, txn_id)
    INCLUDE (txn_type, amount);

-- ---------------------------------------------------------------------
-- 6. idx_wallet_transactions_pending_withdrawals
-- Table: dream11.wallet_transactions
-- Type: Partial B-tree index
-- Benefiting queries: R10, W05
-- Justification:
--   R10 and W05 both search for pending withdrawals older than 24 hours.
--   Only 100 out of 118,343 rows match `txn_type = 'WITHDRAWAL' AND status = 'PENDING'`.
--   A partial index covers exclusively these 100 tuples, reducing execution
--   time from ~8 ms (R10) / ~11 ms (W05) down to ~0.03 ms / ~0.5 ms.
--   Write overhead is near zero because deposits, entry fees, and winnings
--   are excluded from index maintenance.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_pending_withdrawals
    ON dream11.wallet_transactions (created_at)
    WHERE txn_type = 'WITHDRAWAL' AND status = 'PENDING';

-- ---------------------------------------------------------------------
-- 7. idx_wallet_transactions_ref_entry
-- Table: dream11.wallet_transactions
-- Type: Partial composite B-tree index
-- Benefiting queries: R13, R25
-- Justification:
--   63,000 out of 118,343 rows have `reference_entry_id IS NULL` (deposits, bonuses).
--   R13 (finance audit on unpaid entries) and R25 (refund audit) perform anti-joins
--   on `reference_entry_id` with `txn_type` filters. Indexing only non-null
--   references turns 118,343-row sequential scans into instant index anti-joins.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_ref_entry
    ON dream11.wallet_transactions (reference_entry_id, txn_type)
    WHERE reference_entry_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 8. idx_wallet_transactions_created_at_desc
-- Table: dream11.wallet_transactions
-- Type: B-tree index (Ordering / Pagination)
-- Benefiting queries: R22
-- Justification:
--   R22 queries all transactions ordered newest-first with deep pagination
--   (`ORDER BY created_at DESC OFFSET 50000 LIMIT 25`). In baseline, this
--   caused a 5.8 MB external disk merge sort across all 118,343 rows.
--   This index allows PostgreSQL to traverse the B-tree in descending order,
--   completely eliminating the external disk sort.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_created_at_desc
    ON dream11.wallet_transactions (created_at DESC);

-- ---------------------------------------------------------------------
-- 9. idx_wallet_transactions_winnings
-- Table: dream11.wallet_transactions
-- Type: Partial composite B-tree index
-- Benefiting queries: R18
-- Justification:
--   R18 computes total winnings for users with unverified KYC.
--   This partial index includes only successful winnings transactions,
--   enabling fast index scans and merge joins on `user_id`.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_winnings
    ON dream11.wallet_transactions (user_id, amount)
    WHERE txn_type = 'WINNINGS' AND status = 'SUCCESS';

-- ---------------------------------------------------------------------
-- 10. idx_contests_match_id
-- Table: dream11.contests
-- Type: Composite B-tree index
-- Benefiting queries: R01, R04, W02
-- Justification:
--   Contests are frequently filtered or joined by `match_id` (e.g. match 207).
--   Adding `contest_type` and `entry_fee` supports filtering on non-private
--   or paid contests directly from the index.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_contests_match_id
    ON dream11.contests (match_id, contest_type, entry_fee);

-- ---------------------------------------------------------------------
-- 11. idx_contests_type
-- Table: dream11.contests
-- Type: Composite B-tree index
-- Benefiting queries: R21
-- Justification:
--   Accelerates filtering by contest type (e.g. `contest_type = 'HEAD_TO_HEAD'`)
--   and supports joins with `contest_entries`.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_contests_type
    ON dream11.contests (contest_type, contest_id);

-- ---------------------------------------------------------------------
-- 12. idx_player_match_stats_player_id
-- Table: dream11.player_match_stats
-- Type: Composite B-tree index (Reverse PK)
-- Benefiting queries: R12, R24
-- Justification:
--   Primary key `pk_player_match_stats` is on `(match_id, player_id)`.
--   Queries aggregating or partitioning by `player_id` (R12, R24) could not
--   seek the PK index. This reverse composite index provides direct index access.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_player_match_stats_player_id
    ON dream11.player_match_stats (player_id, match_id);

-- ---------------------------------------------------------------------
-- 13. idx_matches_status_starts_at
-- Table: dream11.matches
-- Type: Composite B-tree index
-- Benefiting queries: R01, R14, R25
-- Justification:
--   Supports filtering by lifecycle status (`UPCOMING`, `COMPLETED`, `ABANDONED`)
--   and sorting by `starts_at`.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_matches_status_starts_at
    ON dream11.matches (status, starts_at);

-- ---------------------------------------------------------------------
-- 14. idx_users_state_code
-- Table: dream11.users
-- Type: Covering B-tree index
-- Benefiting queries: R11
-- Justification:
--   R11 filters compliance-restricted states (`AS`, `OD`, `TG`, `AP`).
--   Covering `(user_id, username)` avoids heap page visits for 50,000 user rows.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_users_state_code
    ON dream11.users (state_code)
    INCLUDE (user_id, username);

-- ---------------------------------------------------------------------
-- 15. idx_users_unverified_kyc
-- Table: dream11.users
-- Type: Partial B-tree index
-- Benefiting queries: R18
-- Justification:
--   75% of users (37,558 rows) have verified KYC. R18 only audits unverified users.
--   A partial index covers only the remaining 12,442 rows, providing direct
--   index-only access for compliance reporting.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_users_unverified_kyc
    ON dream11.users (user_id, username, kyc_status)
    WHERE kyc_status <> 'VERIFIED';
