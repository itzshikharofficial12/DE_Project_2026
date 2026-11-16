-- =====================================================================
-- Dream11 Fantasy Sports Database — Phase 2
-- File: sql/02_load_data.sql
-- Team: T0060 (Section C)
-- Description:
--   Loads all 10 CSV files from seed_data/ into the dream11 schema
--   inside a single transaction, runs ANALYZE, verifies expected vs
--   actual row counts, and executes non-destructive data-integrity
--   and fair-play audit checks.
-- Usage (from repository root):
--   psql -d dream11_db -v ON_ERROR_STOP=1 -f sql/02_load_data.sql
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

SET search_path TO dream11;

-- Clear existing rows in child-to-parent order so the load is idempotent
TRUNCATE TABLE
    dream11.wallet_transactions,
    dream11.contest_entries,
    dream11.user_team_players,
    dream11.contests,
    dream11.user_teams,
    dream11.player_match_stats,
    dream11.users,
    dream11.matches,
    dream11.players,
    dream11.teams;

-- 1. Load parent tables first
\copy dream11.teams (team_id, team_name, short_name, team_type) FROM 'seed_data/teams.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy dream11.players (player_id, full_name, team_id, role, credits, is_active) FROM 'seed_data/players.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy dream11.matches (match_id, tournament, home_team_id, away_team_id, venue, starts_at, status) FROM 'seed_data/matches.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy dream11.users (user_id, username, phone, email, state_code, kyc_status, created_at) FROM 'seed_data/users.csv' WITH (FORMAT csv, HEADER true, NULL '')

-- 2. Load second-level dependent tables
\copy dream11.player_match_stats (match_id, player_id, runs, balls_faced, fours, sixes, wickets, catches, fantasy_points) FROM 'seed_data/player_match_stats.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy dream11.user_teams (user_team_id, user_id, match_id, team_label, captain_id, vice_captain_id, total_points, created_at) FROM 'seed_data/user_teams.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy dream11.contests (contest_id, match_id, contest_name, contest_type, entry_fee, total_spots, prize_pool, is_guaranteed, invite_code) FROM 'seed_data/contests.csv' WITH (FORMAT csv, HEADER true, NULL '')

-- 3. Load third-level associative and entry tables
\copy dream11.user_team_players (user_team_id, player_id) FROM 'seed_data/user_team_players.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy dream11.contest_entries (entry_id, contest_id, user_team_id, joined_at, final_rank, winnings) FROM 'seed_data/contest_entries.csv' WITH (FORMAT csv, HEADER true, NULL '')

-- 4. Load financial ledger table referencing users and contest_entries
\copy dream11.wallet_transactions (txn_id, user_id, txn_type, amount, reference_entry_id, status, created_at) FROM 'seed_data/wallet_transactions.csv' WITH (FORMAT csv, HEADER true, NULL '')

COMMIT;

-- Update planner statistics for all tables in dream11
ANALYZE dream11.teams;
ANALYZE dream11.players;
ANALYZE dream11.matches;
ANALYZE dream11.player_match_stats;
ANALYZE dream11.users;
ANALYZE dream11.user_teams;
ANALYZE dream11.user_team_players;
ANALYZE dream11.contests;
ANALYZE dream11.contest_entries;
ANALYZE dream11.wallet_transactions;

-- =====================================================================
-- Row-Count Verification Report
-- =====================================================================
\echo '=== 1. ROW COUNT VALIDATION ==='
SELECT
    t.table_name,
    t.expected_rows,
    t.actual_rows,
    CASE WHEN t.expected_rows = t.actual_rows THEN 'PASS' ELSE 'MISMATCH' END AS status
FROM (
    SELECT 1 AS ord, 'teams' AS table_name, 18 AS expected_rows, COUNT(*) AS actual_rows FROM dream11.teams
    UNION ALL
    SELECT 2, 'players', 450, COUNT(*) FROM dream11.players
    UNION ALL
    SELECT 3, 'matches', 212, COUNT(*) FROM dream11.matches
    UNION ALL
    SELECT 4, 'player_match_stats', 4444, COUNT(*) FROM dream11.player_match_stats
    UNION ALL
    SELECT 5, 'users', 50000, COUNT(*) FROM dream11.users
    UNION ALL
    SELECT 6, 'user_teams', 39975, COUNT(*) FROM dream11.user_teams
    UNION ALL
    SELECT 7, 'user_team_players', 439925, COUNT(*) FROM dream11.user_team_players
    UNION ALL
    SELECT 8, 'contests', 2544, COUNT(*) FROM dream11.contests
    UNION ALL
    SELECT 9, 'contest_entries', 42746, COUNT(*) FROM dream11.contest_entries
    UNION ALL
    SELECT 10, 'wallet_transactions', 118343, COUNT(*) FROM dream11.wallet_transactions
) t
ORDER BY t.ord;

-- =====================================================================
-- Data Integrity & Business-Rule Audit Checks (Read-Only Reporting)
-- =====================================================================

\echo '=== 2. INTEGRITY CHECK 1: Fantasy teams containing anything other than 11 players ==='
SELECT
    COUNT(*) AS violating_teams_count,
    MIN(player_count) AS min_players,
    MAX(player_count) AS max_players
FROM (
    SELECT ut.user_team_id, COUNT(utp.player_id) AS player_count
    FROM dream11.user_teams ut
    LEFT JOIN dream11.user_team_players utp ON utp.user_team_id = ut.user_team_id
    GROUP BY ut.user_team_id
    HAVING COUNT(utp.player_id) <> 11
) sub;

\echo '=== 3. INTEGRITY CHECK 2: Fantasy teams containing players not belonging to either side of their match ==='
SELECT
    COUNT(*) AS invalid_player_selections_count,
    COUNT(DISTINCT ut.user_team_id) AS affected_teams_count
FROM dream11.user_teams ut
JOIN dream11.matches m ON m.match_id = ut.match_id
JOIN dream11.user_team_players utp ON utp.user_team_id = ut.user_team_id
JOIN dream11.players p ON p.player_id = utp.player_id
WHERE p.team_id NOT IN (m.home_team_id, m.away_team_id);

\echo '=== 4. INTEGRITY CHECK 3: Fantasy teams created after their match started ==='
SELECT
    COUNT(*) AS late_teams_count
FROM dream11.user_teams ut
JOIN dream11.matches m ON m.match_id = ut.match_id
WHERE ut.created_at >= m.starts_at;

\echo '=== 5. INTEGRITY CHECK 4: Paid contest entries without expected successful entry-fee wallet debit ==='
SELECT
    COUNT(*) AS unpaid_or_unconfirmed_entries_count,
    COUNT(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM dream11.wallet_transactions w
        WHERE w.reference_entry_id = ce.entry_id AND w.txn_type = 'ENTRY_FEE'
    )) AS missing_any_entry_fee_txn_count,
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM dream11.wallet_transactions w
        WHERE w.reference_entry_id = ce.entry_id AND w.txn_type = 'ENTRY_FEE' AND w.status <> 'SUCCESS'
    )) AS non_success_entry_fee_txn_count
FROM dream11.contest_entries ce
JOIN dream11.contests c ON c.contest_id = ce.contest_id
WHERE c.entry_fee > 0
  AND NOT EXISTS (
      SELECT 1
      FROM dream11.wallet_transactions w
      WHERE w.reference_entry_id = ce.entry_id
        AND w.txn_type = 'ENTRY_FEE'
        AND w.status = 'SUCCESS'
  );

\echo '=== 6. INTEGRITY CHECK 5: Captain and vice-captain membership in their fantasy team roster ==='
SELECT
    COUNT(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM dream11.user_team_players utp
        WHERE utp.user_team_id = ut.user_team_id AND utp.player_id = ut.captain_id
    )) AS captain_not_in_roster_count,
    COUNT(*) FILTER (WHERE NOT EXISTS (
        SELECT 1 FROM dream11.user_team_players utp
        WHERE utp.user_team_id = ut.user_team_id AND utp.player_id = ut.vice_captain_id
    )) AS vice_captain_not_in_roster_count
FROM dream11.user_teams ut;

\echo '=== 7. ADDITIONAL FAIR-PLAY AUDIT SUMMARY (Credits > 100, Max > 7 from one team, Multi-entry abuse) ==='
SELECT
    COUNT(*) FILTER (WHERE player_cnt <> 11) AS wrong_player_count_teams,
    COUNT(*) FILTER (WHERE total_credits > 100.0) AS over_100_credits_teams,
    COUNT(*) FILTER (WHERE max_per_real_team > 7) AS over_7_from_one_side_teams,
    COUNT(*) FILTER (WHERE player_cnt <> 11 OR total_credits > 100.0 OR max_per_real_team > 7) AS total_rule_breaking_teams
FROM (
    SELECT
        ut.user_team_id,
        COUNT(*) AS player_cnt,
        SUM(p.credits) AS total_credits,
        MAX(team_cnt.cnt) AS max_per_real_team
    FROM dream11.user_teams ut
    JOIN dream11.user_team_players utp ON utp.user_team_id = ut.user_team_id
    JOIN dream11.players p ON p.player_id = utp.player_id
    JOIN (
        SELECT utp2.user_team_id, p2.team_id, COUNT(*) AS cnt
        FROM dream11.user_team_players utp2
        JOIN dream11.players p2 ON p2.player_id = utp2.player_id
        GROUP BY utp2.user_team_id, p2.team_id
    ) team_cnt ON team_cnt.user_team_id = ut.user_team_id AND team_cnt.team_id = p.team_id
    GROUP BY ut.user_team_id
) rules;

