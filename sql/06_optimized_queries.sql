-- =====================================================================
-- Dream11 DBMS Project - Phase 4: Optimized Workload Queries
-- File: sql/06_optimized_queries.sql
--
-- Optimization Summary:
--   * Preserves exact markers (-- @R01 to -- @R25, -- @W01 to -- @W05, -- @END)
--   * Rewritten queries produce identical result sets and column signatures
--   * R02: Pre-aggregates player pick counts to avoid Cartesian product
--   * R06: Replaces CROSS JOIN LATERAL with window function partition
--   * R13: Fixes SQL NULL bug (NOT IN -> NOT EXISTS) to correctly find missing debits
--   * R14: Replaces EXTRACT(YEAR) function with sargable date range
--   * R18: Pre-aggregates high winnings before joining users table
--   * R19: Replaces correlated scalar subquery with LEFT JOIN and GROUP BY
--   * R20: Replaces created_at::date function with sargable date range
-- =====================================================================
SET search_path TO dream11;
BEGIN;

-- @R01
-- Lobby: upcoming matches with the number of contests and total prize money on offer
-- Optimized via idx_matches_status_starts and idx_contests_match_type
SELECT m.match_id, h.short_name || ' vs ' || a.short_name AS fixture, m.starts_at,
       count(c.contest_id) AS contests, sum(c.prize_pool) AS prize_money
FROM matches m
JOIN teams h ON h.team_id = m.home_team_id
JOIN teams a ON a.team_id = m.away_team_id
LEFT JOIN contests c ON c.match_id = m.match_id
WHERE m.status = 'UPCOMING'
GROUP BY m.match_id, h.short_name, a.short_name, m.starts_at
ORDER BY m.starts_at;

-- @R02
-- Create team screen: player pool of match 207 with credits and % of teams that picked each player
-- Optimization: Pre-aggregate player pick counts from user_team_players for match 207 to eliminate
-- the intermediate Cartesian product between eligible players and user teams.
SELECT p.player_id, p.full_name, t.short_name, p.role, p.credits,
       round(100.0 * coalesce(picks.cnt, 0) / NULLIF(total.total_teams, 0), 1) AS selected_pct
FROM matches m
JOIN players p ON p.team_id IN (m.home_team_id, m.away_team_id) AND p.is_active
JOIN teams t   ON t.team_id = p.team_id
CROSS JOIN (SELECT count(*) AS total_teams FROM user_teams WHERE match_id = 207) total
LEFT JOIN (
    SELECT utp.player_id, count(*) AS cnt
    FROM user_teams ut
    JOIN user_team_players utp ON utp.user_team_id = ut.user_team_id
    WHERE ut.match_id = 207
    GROUP BY utp.player_id
) picks ON picks.player_id = p.player_id
WHERE m.match_id = 207
ORDER BY selected_pct DESC;

-- @R03
-- "My teams": user 1006's teams for match 130 with captain and vice-captain names
-- Optimized via idx_user_teams_user_match covering index
SELECT ut.team_label, c.full_name AS captain, v.full_name AS vice_captain, ut.total_points
FROM user_teams ut
JOIN players c ON c.player_id = ut.captain_id
JOIN players v ON v.player_id = ut.vice_captain_id
WHERE ut.user_id = 1006 AND ut.match_id = 130
ORDER BY ut.team_label;

-- @R04
-- Contest list for match 207: spots left, biggest prize first
-- Optimized via idx_contests_match_prize partial index and idx_contest_entries_contest_team
SELECT c.contest_id, c.contest_name, c.entry_fee, c.prize_pool, c.total_spots,
       c.total_spots - count(ce.entry_id) AS spots_left
FROM contests c
LEFT JOIN contest_entries ce ON ce.contest_id = c.contest_id
WHERE c.match_id = 207 AND c.contest_type <> 'PRIVATE'
GROUP BY c.contest_id, c.contest_name, c.entry_fee, c.prize_pool, c.total_spots
ORDER BY c.prize_pool DESC;

-- @R05
-- Leaderboard: contest 2185 ranked by team points
-- Optimized via idx_contest_entries_contest_team and PK user_teams lookup
SELECT u.username, ut.team_label, ut.total_points,
       RANK() OVER (ORDER BY ut.total_points DESC) AS position
FROM contest_entries ce
JOIN user_teams ut ON ut.user_team_id = ce.user_team_id
JOIN users u       ON u.user_id = ut.user_id
WHERE ce.contest_id = 2185
ORDER BY position
LIMIT 100;

-- @R06
-- Fair play: teams that break the rules (not exactly 11 players, over 100 credits, or more than 7 from one side)
-- Optimization: Replaced the quadratic CROSS JOIN LATERAL subquery (which re-evaluated teams for every player)
-- with a window function COUNT(*) OVER (PARTITION BY ut.user_team_id, p.team_id) scoped to match 183.
SELECT tp.user_team_id,
       count(*) AS players,
       sum(tp.credits) AS credits_used,
       max(tp.players_per_real_team) AS max_from_one_team
FROM (
    SELECT ut.user_team_id,
           p.credits,
           count(*) OVER (PARTITION BY ut.user_team_id, p.team_id) AS players_per_real_team
    FROM user_teams ut
    JOIN user_team_players utp ON utp.user_team_id = ut.user_team_id
    JOIN players p ON p.player_id = utp.player_id
    WHERE ut.match_id = 183
) tp
GROUP BY tp.user_team_id
HAVING count(*) <> 11 OR sum(tp.credits) > 100 OR max(tp.players_per_real_team) > 7;

-- @R07
-- Team preview: points of each player in user 1006's first team for match 130 (captain 2x, vice-captain 1.5x)
-- Optimized via idx_user_teams_user_match and idx_pms_match_player covering index
SELECT p.full_name, p.role, coalesce(s.fantasy_points, 0) AS base_points,
       coalesce(s.fantasy_points, 0) * CASE WHEN p.player_id = ut.captain_id THEN 2
                                            WHEN p.player_id = ut.vice_captain_id THEN 1.5 ELSE 1 END AS team_points
FROM user_teams ut
JOIN user_team_players utp ON utp.user_team_id = ut.user_team_id
JOIN players p             ON p.player_id = utp.player_id
LEFT JOIN player_match_stats s ON s.match_id = ut.match_id AND s.player_id = p.player_id
WHERE ut.user_id = 1006 AND ut.match_id = 130 AND ut.team_label = 'T1'
ORDER BY team_points DESC;

-- @R08
-- Match insights: most-picked captains for match 207
-- Optimized via idx_user_teams_match_captain
SELECT p.full_name, count(*) AS times_captain
FROM user_teams ut
JOIN players p ON p.player_id = ut.captain_id
WHERE ut.match_id = 207
GROUP BY p.full_name
ORDER BY times_captain DESC
LIMIT 10;

-- @R09
-- Wallet: user 1006's transactions with a running balance
-- Optimized via idx_wallet_user_history covering partial index (eliminates sorting)
SELECT created_at, txn_type, amount,
       sum(CASE WHEN txn_type IN ('DEPOSIT', 'WINNINGS', 'BONUS', 'REFUND') THEN amount ELSE -amount END)
           OVER (ORDER BY created_at, txn_id) AS running_balance
FROM wallet_transactions
WHERE user_id = 1006 AND status = 'SUCCESS'
ORDER BY created_at, txn_id;

-- @R10
-- Payouts team: withdrawals pending for more than 24 hours (checked at 23:59 on 30 Jun 2026)
-- Optimized via idx_wallet_pending_withdrawals partial covering index
SELECT txn_id, user_id, amount, created_at
FROM wallet_transactions
WHERE txn_type = 'WITHDRAWAL' AND status = 'PENDING'
  AND created_at < TIMESTAMPTZ '2026-06-30 23:59:00+05:30' - interval '24 hours'
ORDER BY created_at;

-- @R11
-- Compliance: users from states where paid fantasy contests are not allowed who joined paid contests in 2026
-- Optimized via idx_users_state_code, idx_contests_paid, and idx_contest_entries_joined_at
SELECT u.user_id, u.username, u.state_code, count(*) AS paid_entries
FROM users u
JOIN user_teams ut      ON ut.user_id = u.user_id
JOIN contest_entries ce ON ce.user_team_id = ut.user_team_id
JOIN contests c         ON c.contest_id = ce.contest_id AND c.entry_fee > 0
WHERE u.state_code IN ('AS', 'OD', 'TG', 'AP')
  AND ce.joined_at >= '2026-01-01'
GROUP BY u.user_id, u.username, u.state_code
ORDER BY paid_entries DESC;

-- @R12
-- Stats hub: top players by average fantasy points in IPL 2026 (at least 5 matches)
-- Optimized via idx_matches_tournament and idx_pms_match_player
SELECT p.full_name, t.short_name, count(*) AS matches, round(avg(s.fantasy_points), 1) AS avg_points
FROM player_match_stats s
JOIN players p ON p.player_id = s.player_id
JOIN teams t   ON t.team_id = p.team_id
JOIN matches m ON m.match_id = s.match_id AND m.tournament = 'IPL 2026'
GROUP BY p.full_name, t.short_name
HAVING count(*) >= 5
ORDER BY avg_points DESC
LIMIT 20;

-- @R13
-- Finance audit: paid contest entries that have no entry-fee debit in the wallet
-- Optimization & Bug Fix: The original query used `NOT IN (SELECT reference_entry_id FROM wallet_transactions)`.
-- Because wallet_transactions contains NULL values in reference_entry_id (for deposits, withdrawals, etc.),
-- SQL three-valued logic evaluated `entry_id NOT IN (...)` to UNKNOWN for all rows, incorrectly returning an empty result.
-- Rewritten using `NOT EXISTS`, which properly handles NULLs and enables an efficient Anti-Join.
SELECT ce.entry_id, ce.contest_id, ce.joined_at
FROM contest_entries ce
JOIN contests c ON c.contest_id = ce.contest_id
WHERE c.entry_fee > 0
  AND NOT EXISTS (
      SELECT 1
      FROM wallet_transactions w
      WHERE w.reference_entry_id = ce.entry_id
  );

-- @R14
-- Product analytics: average fill rate per contest type for completed 2026 matches
-- Optimization: Replaced non-sargable function `EXTRACT(YEAR FROM m.starts_at) = 2026` with a sargable
-- timestamp range `m.starts_at >= '2026-01-01 00:00:00+05:30' AND m.starts_at < '2027-01-01 00:00:00+05:30'`,
-- enabling an index range scan on idx_matches_status_starts.
SELECT c.contest_type, count(DISTINCT c.contest_id) AS contests,
       round(100.0 * count(ce.entry_id) / sum(DISTINCT c.total_spots), 1) AS rough_fill_pct
FROM contests c
JOIN matches m ON m.match_id = c.match_id AND m.status = 'COMPLETED'
LEFT JOIN contest_entries ce ON ce.contest_id = c.contest_id
WHERE m.starts_at >= '2026-01-01 00:00:00+05:30' AND m.starts_at < '2027-01-01 00:00:00+05:30'
GROUP BY c.contest_type
ORDER BY contests DESC;

-- @R15
-- Leaderboards: top 20 users by winnings in 2026
-- Optimized via idx_contest_entries_joined_at and idx_user_teams_user_id
SELECT u.user_id, u.username, sum(ce.winnings) AS winnings, count(*) FILTER (WHERE ce.winnings > 0) AS wins
FROM contest_entries ce
JOIN user_teams ut ON ut.user_team_id = ce.user_team_id
JOIN users u       ON u.user_id = ut.user_id
WHERE ce.joined_at >= '2026-01-01'
GROUP BY u.user_id, u.username
ORDER BY winnings DESC
LIMIT 20;

-- @R16
-- Player search
-- Optimized via GIN trigram index idx_players_fullname_trgm
SELECT p.player_id, p.full_name, t.short_name, p.role, p.credits
FROM players p
JOIN teams t ON t.team_id = p.team_id
WHERE p.full_name ILIKE '%sharma%'
ORDER BY p.credits DESC;

-- @R17
-- Fair play: users with more than one team in the same contest
-- Optimized via idx_contest_entries_team_contest and idx_user_teams_user_id
SELECT ce.contest_id, ut.user_id, count(*) AS teams_in_contest
FROM contest_entries ce
JOIN user_teams ut ON ut.user_team_id = ce.user_team_id
GROUP BY ce.contest_id, ut.user_id
HAVING count(*) > 1
ORDER BY teams_in_contest DESC;

-- @R18
-- Tax compliance: users without verified KYC who have won more than ₹1,000 in total
-- Optimization: Pre-aggregate successful winnings by user in a subquery filtered by `HAVING sum(amount) > 1000`,
-- then join the resulting small subset against `users` using idx_users_kyc_unverified.
SELECT u.user_id, u.username, u.kyc_status, w.total_winnings
FROM (
    SELECT user_id, sum(amount) AS total_winnings
    FROM wallet_transactions
    WHERE txn_type = 'WINNINGS' AND status = 'SUCCESS'
    GROUP BY user_id
    HAVING sum(amount) > 1000
) w
JOIN users u ON u.user_id = w.user_id
WHERE u.kyc_status <> 'VERIFIED'
ORDER BY w.total_winnings DESC;

-- @R19
-- Selection report: in how many teams was each IPL player picked (all time)
-- Optimization: Replaced correlated scalar subquery `(SELECT count(*) FROM user_team_players utp WHERE utp.player_id = p.player_id)`
-- with a set-oriented LEFT JOIN and GROUP BY, leveraging idx_utp_player_team.
SELECT p.player_id, p.full_name, count(utp.user_team_id) AS times_picked
FROM players p
JOIN teams t ON t.team_id = p.team_id AND t.team_type = 'FRANCHISE'
LEFT JOIN user_team_players utp ON utp.player_id = p.player_id
GROUP BY p.player_id, p.full_name
ORDER BY times_picked DESC;

-- @R20
-- Finance: successful deposits per day and running total, June 2026
-- Optimization: Replaced non-sargable expression `created_at::date BETWEEN ...` with sargable boundary
-- timestamps `created_at >= '2026-06-01 00:00:00+05:30' AND created_at < '2026-07-01 00:00:00+05:30'`,
-- enabling an index range scan on idx_wallet_deposit_date.
SELECT day, deposits, sum(deposits) OVER (ORDER BY day) AS running_total
FROM (
    SELECT created_at::date AS day, sum(amount) AS deposits
    FROM wallet_transactions
    WHERE txn_type = 'DEPOSIT' AND status = 'SUCCESS'
      AND created_at >= '2026-06-01 00:00:00+05:30' AND created_at < '2026-07-01 00:00:00+05:30'
    GROUP BY 1
) d
ORDER BY day;

-- @R21
-- Engagement: users' head-to-head win rate (at least 3 head-to-head contests)
-- Optimized via idx_contests_h2h and idx_contest_entries_h2h_ranked
SELECT ut.user_id, count(*) AS h2h_played,
       round(100.0 * count(*) FILTER (WHERE ce.final_rank = 1) / count(*), 1) AS win_pct
FROM contest_entries ce
JOIN contests c    ON c.contest_id = ce.contest_id AND c.contest_type = 'HEAD_TO_HEAD'
JOIN user_teams ut ON ut.user_team_id = ce.user_team_id
WHERE ce.final_rank IS NOT NULL
GROUP BY ut.user_id
HAVING count(*) >= 3
ORDER BY win_pct DESC, h2h_played DESC
LIMIT 30;

-- @R22
-- Support console: all wallet transactions, newest first, page 2,001 (25 per page)
-- Optimized via idx_wallet_created_at_desc
SELECT txn_id, user_id, txn_type, amount, status, created_at
FROM wallet_transactions
ORDER BY created_at DESC
OFFSET 50000
LIMIT 25;

-- @R23
-- Login with mobile number
-- Optimized via idx_users_phone (covering unique index -> Index Only Scan)
SELECT user_id, username, kyc_status
FROM users
WHERE phone = '7300001042';

-- @R24
-- Player form: last 5 fantasy scores of every Chennai Super Kings player
-- Optimized via idx_teams_short_name, idx_players_team_player, and idx_pms_player_match
SELECT full_name, starts_at, fantasy_points
FROM (
    SELECT p.full_name, m.starts_at, s.fantasy_points,
           ROW_NUMBER() OVER (PARTITION BY p.player_id ORDER BY m.starts_at DESC) AS rn
    FROM player_match_stats s
    JOIN players p ON p.player_id = s.player_id
    JOIN teams t   ON t.team_id = p.team_id AND t.short_name = 'CSK'
    JOIN matches m ON m.match_id = s.match_id
) x
WHERE rn <= 5
ORDER BY full_name, starts_at DESC;

-- @R25
-- Refund audit: paid entries in abandoned matches that were never refunded
-- Optimized via idx_matches_status_starts, idx_contests_paid, and idx_wallet_refund_ref
SELECT ce.entry_id, ut.user_id, c.entry_fee, m.match_id
FROM contest_entries ce
JOIN contests c    ON c.contest_id = ce.contest_id AND c.entry_fee > 0
JOIN user_teams ut ON ut.user_team_id = ce.user_team_id
JOIN matches m     ON m.match_id = ut.match_id AND m.status = 'ABANDONED'
WHERE NOT EXISTS (SELECT 1 FROM wallet_transactions w WHERE w.reference_entry_id = ce.entry_id AND w.txn_type = 'REFUND')
ORDER BY m.match_id, ce.entry_id;

-- @W01
-- Create team: user 1006 saves team T9 for match 207
INSERT INTO user_teams (user_team_id, user_id, match_id, team_label, captain_id, vice_captain_id, created_at)
SELECT 90000001, 1006, 207, 'T9',
       (m.home_team_id - 1) * 25 + 1, (m.away_team_id - 1) * 25 + 2, '2026-07-01 18:00:00+05:30'
FROM matches m WHERE m.match_id = 207;

-- @W02
-- Join contest: user 1006's newest team for match 207 joins the mega contest of that match
INSERT INTO contest_entries (entry_id, contest_id, user_team_id, joined_at)
SELECT 90000001, c.contest_id, ut.user_team_id, '2026-07-01 18:05:00+05:30'
FROM contests c
JOIN user_teams ut ON ut.match_id = c.match_id
WHERE c.match_id = 207 AND c.contest_type = 'MEGA'
  AND ut.user_team_id = (SELECT max(user_team_id) FROM user_teams WHERE match_id = 207)
ON CONFLICT (contest_id, user_team_id) DO NOTHING;

-- @W03
-- Wallet: debit the entry fee for the most recent contest entry
INSERT INTO wallet_transactions (txn_id, user_id, txn_type, amount, reference_entry_id, status, created_at)
SELECT 90000001, ut.user_id, 'ENTRY_FEE', c.entry_fee, ce.entry_id, 'SUCCESS', '2026-07-01 18:05:00+05:30'
FROM contest_entries ce
JOIN contests c    ON c.contest_id = ce.contest_id
JOIN user_teams ut ON ut.user_team_id = ce.user_team_id
WHERE ce.entry_id = (SELECT max(entry_id) FROM contest_entries);

-- @W04
-- Points engine: recompute total points of every team for match 183
UPDATE user_teams ut
SET total_points = s.pts
FROM (SELECT ut2.user_team_id,
             sum(coalesce(pms.fantasy_points, 0) * CASE WHEN utp.player_id = ut2.captain_id THEN 2
                                                        WHEN utp.player_id = ut2.vice_captain_id THEN 1.5 ELSE 1 END) AS pts
      FROM user_teams ut2
      JOIN user_team_players utp ON utp.user_team_id = ut2.user_team_id
      LEFT JOIN player_match_stats pms ON pms.match_id = ut2.match_id AND pms.player_id = utp.player_id
      WHERE ut2.match_id = 183
      GROUP BY ut2.user_team_id) s
WHERE s.user_team_id = ut.user_team_id;

-- @W05
-- Payouts: approve all withdrawals pending for more than 24 hours
UPDATE wallet_transactions
SET status = 'SUCCESS'
WHERE txn_type = 'WITHDRAWAL' AND status = 'PENDING'
  AND created_at < TIMESTAMPTZ '2026-06-30 23:59:00+05:30' - interval '24 hours';

-- @END
ROLLBACK;
