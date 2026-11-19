-- =====================================================================
-- Dream11 DBMS Project - Phase 4: Performance Indexes
-- File: sql/05_indexes.sql
--
-- Optimization Strategy:
-- 1. B-tree indexes with exact column ordering: equality columns first,
--    followed by range, join, or sort columns.
-- 2. Partial indexes to minimize index size and write overhead on frequently
--    updated or inserted tables (e.g. wallet_transactions, contests).
-- 3. Covering indexes (INCLUDE) for Index Only Scans to eliminate heap fetches.
-- 4. GIN Trigram index (pg_trgm) to accelerate substring matching (ILIKE '%...%').
-- =====================================================================

SET search_path TO dream11;

-- Required extension for GIN trigram indexing on text attributes
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- =====================================================================
-- 1. Table: teams
-- =====================================================================

-- Index: idx_teams_type_id
-- Serves: R19 (Selection report)
-- Type: B-tree
-- Columns: (team_type, team_id)
-- Rationale: Equality filter on team_type ('FRANCHISE') first, then team_id for
-- joining players. Eliminates sequential scan on teams.
CREATE INDEX IF NOT EXISTS idx_teams_type_id
  ON teams (team_type, team_id);

-- Index: idx_teams_short_name
-- Serves: R24 (Player form)
-- Type: B-tree
-- Columns: (short_name, team_id)
-- Rationale: Equality filter on short_name ('CSK') first, then team_id for
-- joining players. Allows instant index lookup of franchise team_id.
CREATE INDEX IF NOT EXISTS idx_teams_short_name
  ON teams (short_name, team_id);


-- =====================================================================
-- 2. Table: players
-- =====================================================================

-- Index: idx_players_fullname_trgm
-- Serves: R16 (Player search)
-- Type: GIN Trigram (pg_trgm)
-- Columns: (full_name gin_trgm_ops)
-- Rationale: R16 performs wildcard substring search `p.full_name ILIKE '%sharma%'`.
-- Standard B-trees cannot optimize leading wildcards; GIN trigram decomposes text into 3-grams
-- allowing an efficient bitmap index scan.
CREATE INDEX IF NOT EXISTS idx_players_fullname_trgm
  ON players USING gin (full_name gin_trgm_ops);

-- Index: idx_players_team_active
-- Serves: R02 (Create team screen)
-- Type: Partial Covering B-tree
-- Columns: (team_id) INCLUDE (player_id, full_name, role, credits) WHERE is_active = true
-- Rationale: In R02, active players for the match's home and away teams are retrieved.
-- The partial filter eliminates inactive players, and the INCLUDE clause enables an Index Only Scan
-- avoiding table heap access.
CREATE INDEX IF NOT EXISTS idx_players_team_active
  ON players (team_id) INCLUDE (player_id, full_name, role, credits)
  WHERE is_active = true;

-- Index: idx_players_team_player
-- Serves: R12, R24
-- Type: Covering B-tree
-- Columns: (team_id, player_id) INCLUDE (full_name)
-- Rationale: Accelerates joining from teams to players by team_id and provides player details directly.
CREATE INDEX IF NOT EXISTS idx_players_team_player
  ON players (team_id, player_id) INCLUDE (full_name);


-- =====================================================================
-- 3. Table: matches
-- =====================================================================

-- Index: idx_matches_status_starts
-- Serves: R01, R14, R25
-- Type: B-tree
-- Columns: (status, starts_at, match_id) INCLUDE (home_team_id, away_team_id)
-- Rationale: Queries filter by status ('UPCOMING', 'COMPLETED', 'ABANDONED') and sort/range
-- on starts_at. Placing status first allows an index range scan directly on the matching status,
-- while starts_at provides sorted order for R01 and range filtering for R14.
CREATE INDEX IF NOT EXISTS idx_matches_status_starts
  ON matches (status, starts_at, match_id) INCLUDE (home_team_id, away_team_id);

-- Index: idx_matches_tournament
-- Serves: R12 (Stats hub)
-- Type: B-tree
-- Columns: (tournament, match_id)
-- Rationale: Filter by tournament ('IPL 2026') followed by match_id for joining player_match_stats.
CREATE INDEX IF NOT EXISTS idx_matches_tournament
  ON matches (tournament, match_id);


-- =====================================================================
-- 4. Table: player_match_stats
-- =====================================================================

-- Index: idx_pms_match_player
-- Serves: R07, R12, W04
-- Type: Covering B-tree
-- Columns: (match_id, player_id) INCLUDE (fantasy_points)
-- Rationale: Fast lookup by match_id and player_id. Including fantasy_points enables Index Only Scan
-- for points calculation in team preview (R07) and points engine batch update (W04).
CREATE INDEX IF NOT EXISTS idx_pms_match_player
  ON player_match_stats (match_id, player_id) INCLUDE (fantasy_points);

-- Index: idx_pms_player_match
-- Serves: R24 (Player form)
-- Type: Covering B-tree
-- Columns: (player_id, match_id) INCLUDE (fantasy_points)
-- Rationale: R24 partitions by player_id and orders by match start time. Indexing (player_id, match_id)
-- satisfies the partition key and speeds up joining to matches.
CREATE INDEX IF NOT EXISTS idx_pms_player_match
  ON player_match_stats (player_id, match_id) INCLUDE (fantasy_points);


-- =====================================================================
-- 5. Table: users
-- =====================================================================

-- Index: idx_users_phone
-- Serves: R23 (Mobile login)
-- Type: Unique Covering B-tree
-- Columns: (phone) INCLUDE (user_id, username, kyc_status)
-- Rationale: Login query looks up by unique phone number. Including user_id, username, and kyc_status
-- enables an immediate Index Only Scan (target < 5 ms met easily in < 0.1 ms).
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone
  ON users (phone) INCLUDE (user_id, username, kyc_status);

-- Index: idx_users_state_code
-- Serves: R11 (State compliance audit)
-- Type: Covering B-tree
-- Columns: (state_code, user_id) INCLUDE (username)
-- Rationale: R11 filters by non-permitted state codes ('AS', 'OD', 'TG', 'AP'). Indexing state_code
-- first enables an index scan across the banned states, providing user_id and username without heap fetches.
CREATE INDEX IF NOT EXISTS idx_users_state_code
  ON users (state_code, user_id) INCLUDE (username);

-- Index: idx_users_kyc_unverified
-- Serves: R18 (Tax compliance)
-- Type: Partial Covering B-tree
-- Columns: (user_id) INCLUDE (username, kyc_status) WHERE kyc_status <> 'VERIFIED'
-- Rationale: Only a subset of users are unverified. A partial index keeps the index small and allows
-- instant index join from pre-aggregated high-winnings users to unverified status.
CREATE INDEX IF NOT EXISTS idx_users_kyc_unverified
  ON users (user_id) INCLUDE (username, kyc_status)
  WHERE kyc_status <> 'VERIFIED';


-- =====================================================================
-- 6. Table: user_teams
-- =====================================================================

-- Index: idx_user_teams_user_match
-- Serves: R03, R07
-- Type: Covering B-tree
-- Columns: (user_id, match_id, team_label) INCLUDE (captain_id, vice_captain_id, total_points)
-- Rationale: User team lookup by user_id and match_id (and optional team_label). Covering all team
-- metadata enables Index Only Scan for "My teams" and "Team preview" real-time screens.
CREATE INDEX IF NOT EXISTS idx_user_teams_user_match
  ON user_teams (user_id, match_id, team_label) INCLUDE (captain_id, vice_captain_id, total_points);

-- Index: idx_user_teams_match_team
-- Serves: R02, R06, W01, W02, W04
-- Type: Covering B-tree
-- Columns: (match_id, user_team_id) INCLUDE (captain_id, vice_captain_id)
-- Rationale: Match-level queries frequently need all user teams created for a match.
-- Placing match_id first enables index range scans for W04 (points recompute) and R06 (fair play checks).
CREATE INDEX IF NOT EXISTS idx_user_teams_match_team
  ON user_teams (match_id, user_team_id) INCLUDE (captain_id, vice_captain_id);

-- Index: idx_user_teams_match_captain
-- Serves: R08 (Most-picked captains)
-- Type: B-tree
-- Columns: (match_id, captain_id)
-- Rationale: Enables index-backed grouping for most-picked captains in a match without scanning other matches.
CREATE INDEX IF NOT EXISTS idx_user_teams_match_captain
  ON user_teams (match_id, captain_id);

-- Index: idx_user_teams_user_id
-- Serves: R11, R15, R17, R21
-- Type: B-tree
-- Columns: (user_id, user_team_id)
-- Rationale: Foreign key join from users to user_teams across reporting and leaderboard queries.
CREATE INDEX IF NOT EXISTS idx_user_teams_user_id
  ON user_teams (user_id, user_team_id);


-- =====================================================================
-- 7. Table: user_team_players
-- =====================================================================

-- Index: idx_utp_player_team
-- Serves: R02, R19
-- Type: B-tree
-- Columns: (player_id, user_team_id)
-- Rationale: Primary key is (user_team_id, player_id). Inverting the column order allows queries
-- aggregating player selection frequencies (e.g. R19 selection report, R02 player pool percentage)
-- to perform fast index lookups or index-only scans by player_id.
CREATE INDEX IF NOT EXISTS idx_utp_player_team
  ON user_team_players (player_id, user_team_id);


-- =====================================================================
-- 8. Table: contests
-- =====================================================================

-- Index: idx_contests_match_prize
-- Serves: R04 (Contest list)
-- Type: Partial B-tree
-- Columns: (match_id, prize_pool DESC) INCLUDE (contest_id, contest_name, entry_fee, total_spots)
-- WHERE contest_type <> 'PRIVATE'
-- Rationale: R04 specifically queries public contests for a match ordered by prize_pool DESC.
-- The partial index excludes private contests and satisfies the sort order directly from the index.
CREATE INDEX IF NOT EXISTS idx_contests_match_prize
  ON contests (match_id, prize_pool DESC) INCLUDE (contest_id, contest_name, entry_fee, total_spots)
  WHERE contest_type <> 'PRIVATE';

-- Index: idx_contests_match_type
-- Serves: R01, R14, W02
-- Type: Covering B-tree
-- Columns: (match_id, contest_type) INCLUDE (contest_id, total_spots, prize_pool)
-- Rationale: Lookups for match contests and specific contest types (e.g. W02 joining 'MEGA' contest).
CREATE INDEX IF NOT EXISTS idx_contests_match_type
  ON contests (match_id, contest_type) INCLUDE (contest_id, total_spots, prize_pool);

-- Index: idx_contests_paid
-- Serves: R11, R13, R25
-- Type: Partial B-tree
-- Columns: (contest_id) INCLUDE (entry_fee, match_id) WHERE entry_fee > 0
-- Rationale: Filters for paid contests in compliance, audit, and refund queries. Indexing only paid contests
-- keeps the index small and avoids filtering out free contests on table scan.
CREATE INDEX IF NOT EXISTS idx_contests_paid
  ON contests (contest_id) INCLUDE (entry_fee, match_id)
  WHERE entry_fee > 0;

-- Index: idx_contests_h2h
-- Serves: R21
-- Type: Partial B-tree
-- Columns: (contest_id) WHERE contest_type = 'HEAD_TO_HEAD'
-- Rationale: Partial index on head-to-head contests for win rate analysis.
CREATE INDEX IF NOT EXISTS idx_contests_h2h
  ON contests (contest_id)
  WHERE contest_type = 'HEAD_TO_HEAD';


-- =====================================================================
-- 9. Table: contest_entries
-- =====================================================================

-- Index: idx_contest_entries_contest_team
-- Serves: R04, R05, W02
-- Type: Unique B-tree
-- Columns: (contest_id, user_team_id)
-- Rationale: Prevents duplicate contest entries for the same team, supports W02 ON CONFLICT clause,
-- and accelerates leaderboard lookups by contest_id.
CREATE UNIQUE INDEX IF NOT EXISTS idx_contest_entries_contest_team
  ON contest_entries (contest_id, user_team_id);

-- Index: idx_contest_entries_team_contest
-- Serves: R11, R15, R17, R21, R25
-- Type: B-tree
-- Columns: (user_team_id, contest_id, joined_at) INCLUDE (winnings, final_rank)
-- Rationale: Foreign key join from user_teams to contest_entries. Covering winnings and final_rank
-- allows index-only joins for leaderboards and win-rate calculations.
CREATE INDEX IF NOT EXISTS idx_contest_entries_team_contest
  ON contest_entries (user_team_id, contest_id, joined_at) INCLUDE (winnings, final_rank);

-- Index: idx_contest_entries_joined_at
-- Serves: R11, R15
-- Type: Covering B-tree
-- Columns: (joined_at, user_team_id) INCLUDE (contest_id, winnings)
-- Rationale: Date range filter `joined_at >= '2026-01-01'`. Indexing joined_at first allows an index
-- range scan over the 2026 contest entries.
CREATE INDEX IF NOT EXISTS idx_contest_entries_joined_at
  ON contest_entries (joined_at, user_team_id) INCLUDE (contest_id, winnings);

-- Index: idx_contest_entries_h2h_ranked
-- Serves: R21
-- Type: Partial B-tree
-- Columns: (contest_id, user_team_id, final_rank) WHERE final_rank IS NOT NULL
-- Rationale: Partial index for completed contest entries used in head-to-head win rate calculation.
CREATE INDEX IF NOT EXISTS idx_contest_entries_h2h_ranked
  ON contest_entries (contest_id, user_team_id, final_rank)
  WHERE final_rank IS NOT NULL;


-- =====================================================================
-- 10. Table: wallet_transactions
-- =====================================================================
-- NOTE ON WRITE OVERHEAD:
-- wallet_transactions is the highest-volume ledger table (118k seed rows, millions in production).
-- To prevent write overhead and table bloat during high-frequency writes (W03, deposits, winnings),
-- almost all indexes on this table are strictly PARTIAL indexes targeting specific txn_types and statuses.

-- Index: idx_wallet_user_history
-- Serves: R09 (Wallet running balance)
-- Type: Partial Covering B-tree
-- Columns: (user_id, created_at, txn_id) INCLUDE (txn_type, amount) WHERE status = 'SUCCESS'
-- Rationale: Matches the exact filter (user_id, status = 'SUCCESS') and ordering (created_at, txn_id).
-- The window function OVER (ORDER BY created_at, txn_id) executes directly on the sorted index tuples,
-- completely eliminating an expensive in-memory sort node.
CREATE INDEX IF NOT EXISTS idx_wallet_user_history
  ON wallet_transactions (user_id, created_at, txn_id) INCLUDE (txn_type, amount)
  WHERE status = 'SUCCESS';

-- Index: idx_wallet_pending_withdrawals
-- Serves: R10, W05 (Payouts & Compliance)
-- Type: Partial Covering B-tree
-- Columns: (created_at) INCLUDE (txn_id, user_id, amount) WHERE txn_type = 'WITHDRAWAL' AND status = 'PENDING'
-- Rationale: Pending withdrawals represent a tiny fraction of the ledger. A partial index on this rare status
-- makes R10 and W05 near-instant (< 1 ms) with virtually zero maintenance overhead on normal transactions.
CREATE INDEX IF NOT EXISTS idx_wallet_pending_withdrawals
  ON wallet_transactions (created_at) INCLUDE (txn_id, user_id, amount)
  WHERE txn_type = 'WITHDRAWAL' AND status = 'PENDING';

-- Index: idx_wallet_winnings_user
-- Serves: R18 (Tax compliance winnings audit)
-- Type: Partial B-tree
-- Columns: (user_id, amount) WHERE txn_type = 'WINNINGS' AND status = 'SUCCESS'
-- Rationale: Partial index only indexing successful winning payouts. Enables index scan for grouping
-- and summing user winnings without scanning entry fees, deposits, or withdrawals.
CREATE INDEX IF NOT EXISTS idx_wallet_winnings_user
  ON wallet_transactions (user_id, amount)
  WHERE txn_type = 'WINNINGS' AND status = 'SUCCESS';

-- Index: idx_wallet_deposit_date
-- Serves: R20 (Finance daily deposit reporting)
-- Type: Partial B-tree
-- Columns: (created_at, amount) WHERE txn_type = 'DEPOSIT' AND status = 'SUCCESS'
-- Rationale: Partial index indexing only successful deposits. Combined with the sargable date range
-- rewrite in R20, this provides a pure index range scan over June 2026.
CREATE INDEX IF NOT EXISTS idx_wallet_deposit_date
  ON wallet_transactions (created_at, amount)
  WHERE txn_type = 'DEPOSIT' AND status = 'SUCCESS';

-- Index: idx_wallet_ref_entry
-- Serves: R13 (Finance audit for missing entry debits)
-- Type: Partial B-tree
-- Columns: (reference_entry_id) WHERE reference_entry_id IS NOT NULL
-- Rationale: R13 requires verifying whether a contest entry has a corresponding wallet debit.
-- Indexing non-null reference_entry_id enables a fast Index Anti-Join for NOT EXISTS.
CREATE INDEX IF NOT EXISTS idx_wallet_ref_entry
  ON wallet_transactions (reference_entry_id)
  WHERE reference_entry_id IS NOT NULL;

-- Index: idx_wallet_refund_ref
-- Serves: R25 (Refund audit)
-- Type: Partial B-tree
-- Columns: (reference_entry_id) WHERE txn_type = 'REFUND'
-- Rationale: Partial index on refund transactions to verify abandoned match refunds via NOT EXISTS.
CREATE INDEX IF NOT EXISTS idx_wallet_refund_ref
  ON wallet_transactions (reference_entry_id)
  WHERE txn_type = 'REFUND';

-- Index: idx_wallet_created_at_desc
-- Serves: R22 (Support console pagination)
-- Type: B-tree
-- Columns: (created_at DESC, txn_id DESC)
-- Rationale: Enables index backwards scan for newest-first transaction listing, eliminating table sort.
CREATE INDEX IF NOT EXISTS idx_wallet_created_at_desc
  ON wallet_transactions (created_at DESC, txn_id DESC);
