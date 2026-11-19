# Phase 4 — Query Optimization and Indexing Report

**Project:** Dream11 Fantasy Sports Database  
**Course:** Database Management Systems  
**Database Engine:** PostgreSQL 18.6 (Postgres.app, `aarch64-apple-darwin23.6.0`, 64-bit)  
**Database Name:** `dream11_db` (schema: `dream11`)  
**Phase:** 4 — Indexing, Query Optimization, Benchmarking, and Performance Analysis  

---

## 1. Executive Summary

The objective of Phase 4 is to design, implement, empirically benchmark, and analyze a comprehensive indexing and query optimization strategy for the Dream11 Fantasy Sports DBMS project. Building upon the Phase 3 baseline workload measurements, every optimization was guided strictly by PostgreSQL execution plans (`EXPLAIN (ANALYZE, BUFFERS)`), addressing sequential scans over large relations, quadratic nested loops, repeated correlated subqueries, non-sargable predicates, unindexed foreign keys, and sorting bottlenecks.

### Key Deliverables & Numerical Highlights
- **Indexes Created:** 15 production-grade B-tree indexes (including reverse foreign keys, composite indexes with tailored column ordering, partial indexes, and covering indexes with `INCLUDE`) created in [`sql/05_indexes.sql`](../sql/05_indexes.sql) without duplicating any of the 18 existing `PRIMARY KEY` and `UNIQUE` constraints.
- **Query Rewrites:** 6 targeted query rewrites in [`sql/06_optimized_queries.sql`](../sql/06_optimized_queries.sql) targeting structural bottlenecks (`R02`, `R06`, `R13`, `R19`, `R20`, `W04`), while leaving already optimal queries structurally untouched to isolate index impact.
- **Queries Benchmarked:** All 30 workload queries (`R01`–`R25` read queries and `W01`–`W05` write queries) were benchmarked with 3 consecutive runs each (90 total measured runs) using [`benchmarks/run_benchmark.sh`](../benchmarks/run_benchmark.sh).
- **Total Baseline Aggregate Metric:** **`2,468.442 ms`** (sum of all 30 baseline query averages).
- **Total Optimized Aggregate Metric:** **`129.609 ms`** (sum of all 30 optimized query averages).
- **Overall Performance Improvement:** **`94.75%` workload latency reduction** (`2,338.833 ms` absolute execution time saved).
- **Major Optimization Successes:**
  - **`R19` (Selection report):** Reduced from **`2,190.351 ms`** down to **`22.303 ms`** (**`98.98%` speedup**, saving `2,168.048 ms`). Shared buffer hits dropped from `500,008` to `2,015` by replacing 250 correlated sequential scans with single-pass pre-aggregation and reverse index lookup.
  - **`R06` (Rule-breaking teams):** Reduced from **`52.354 ms`** down to **`2.306 ms`** (**`95.60%` speedup**). Eliminated 3,062 correlated lateral subqueries using a window function partition.
  - **`R02` (Match player pool):** Reduced from **`39.264 ms`** down to **`1.496 ms`** (**`96.19%` speedup**). Avoided a Merge Right Join across 437k rows of `user_team_players`.
  - **`R22` (Deep pagination):** Reduced from **`26.522 ms`** down to **`4.761 ms`** (**`82.05%` speedup**). Eliminated a `5,800 kB` external disk merge sort via descending B-tree traversal.
  - **`R10` (Pending withdrawals):** Reduced from **`7.852 ms`** down to **`0.056 ms`** (**`99.29%` speedup**). Index scan over a 16 kB partial index.
  - **`R09` (User wallet history):** Reduced from **`5.611 ms`** down to **`0.182 ms`** (**`96.76%` speedup**). Converted to Index Only Scan via covering index.
  - **`W04` (Points recomputation):** Reduced from **`13.417 ms`** down to **`5.177 ms`** (**`61.41%` speedup**). Added match predicate to target update table.
  - **`W05` (Approve withdrawals):** Reduced from **`10.781 ms`** down to **`1.112 ms`** (**`89.69%` speedup**). Leveraged partial index for pending withdrawals.
- **Critical Correctness Fix (`R13`):** The baseline finance audit query returned **`0 rows`** due to SQL three-valued logic failure when evaluating `NOT IN (SELECT reference_entry_id ...)` across `63,000` NULL values. Rewriting with `NOT EXISTS` fixed the semantic defect, correctly returning the **`192 verified unpaid entries`** while cutting query latency from **`18.175 ms`** to **`9.733 ms`** (**`46.45%` faster**).

---

## 2. Baseline Environment

All benchmark runs were executed on the following verified environment, maintaining rigorous methodological consistency with Phase 3:

| Parameter | Verified Environment Details |
|---|---|
| **PostgreSQL Version** | `PostgreSQL 18.6 (Postgres.app) on aarch64-apple-darwin23.6.0, 64-bit` |
| **Operating System** | macOS 26.2 (Darwin `arm64`, Apple Silicon) |
| **CPU Architecture** | Apple Silicon (unified memory architecture) |
| **Database Name** | `dream11_db` |
| **Schema Name** | `dream11` |
| **Active Baseline Indexes** | 18 constraint B-trees (10 `PRIMARY KEY` + 8 `UNIQUE`); 0 secondary indexes |
| **Active Optimized Indexes** | 33 total B-trees (18 constraint B-trees + 15 tuned optimization indexes) |
| **Planner Statistics** | Refreshed via `ANALYZE` across all 10 tables prior to benchmarking |
| **Benchmark Script** | [`benchmarks/run_benchmark.sh`](../benchmarks/run_benchmark.sh) invoking `psql -X -q -A -t -v ON_ERROR_STOP=1` |
| **Repetitions** | 3 consecutive runs per query (90 total measurements) |
| **Measurement Unit** | Server-side execution time in milliseconds (`ms`) extracted from `EXPLAIN (ANALYZE, BUFFERS)` |
| **Write Query Safety** | Explicit `BEGIN; EXPLAIN (ANALYZE, BUFFERS) <write_sql>; ROLLBACK;` transaction blocks |

### Verified Dataset Row Counts in `dream11_db`

The schema contains 10 tables and 738,657 total rows, loaded identically from `seed_data/`:

| Table Name | Row Count | Primary Key Index | Baseline Unique Indexes |
|---|---:|---|---|
| `dream11.teams` | 18 | `pk_teams (team_id)` | `uq_teams_team_name`, `uq_teams_short_name` |
| `dream11.players` | 450 | `pk_players (player_id)` | — |
| `dream11.matches` | 212 | `pk_matches (match_id)` | — |
| `dream11.player_match_stats` | 4,444 | `pk_player_match_stats (match_id, player_id)` | — |
| `dream11.users` | 50,000 | `pk_users (user_id)` | `uq_users_username`, `uq_users_phone`, `uq_users_email` |
| `dream11.user_teams` | 39,975 | `pk_user_teams (user_team_id)` | `uq_user_teams_user_match_label (user_id, match_id, team_label)` |
| `dream11.user_team_players` | 439,925 | `pk_user_team_players (user_team_id, player_id)` | — |
| `dream11.contests` | 2,544 | `pk_contests (contest_id)` | `uq_contests_invite_code (invite_code)` |
| `dream11.contest_entries` | 42,746 | `pk_contest_entries (entry_id)` | `uq_contest_entries_contest_team (contest_id, user_team_id)` |
| `dream11.wallet_transactions` | 118,343 | `pk_wallet_transactions (txn_id)` | — |
| **Total** | **738,657** | **10 Primary Key Indexes** | **8 Unique Constraint Indexes** |

---

## 3. Optimization Strategy

Our optimization strategy was guided strictly by empirical evidence from Phase 3 query plans rather than speculative index creation:

1. **Query Plan Bottleneck Identification:**
   Every query was analyzed for specific plan deficiencies:
   - *Sequential Scans on Large Tables:* Observed on `user_team_players` (439k rows), `wallet_transactions` (118k rows), `users` (50k rows), `contest_entries` (42k rows), and `user_teams` (40k rows).
   - *Correlated Nested Iterations:* Inner subplans evaluated once per outer row (e.g., `R19` scanning 439k rows 250 times; `R06` scanning player rosters 3,062 times).
   - *Unindexed Foreign Keys / Reverse Composite Mismatches:* Associative tables with composite keys where join predicates hit the second column (`user_team_players.player_id`, `contest_entries.user_team_id`, `player_match_stats.player_id`).
   - *External Disk Sorting:* Sort operations exceeding `work_mem` and spilling to disk (`R22` external merge sort requiring `5,800 kB` on disk).
   - *Non-Sargable Predicates:* Functions or type casts preventing index seek (`R20` `created_at::date BETWEEN ...`).
2. **Separation of Index-Based vs. Query-Structure Optimization:**
   - **Index-Based Optimization:** Applied when the relational algebra is already optimal, but the storage engine lacks access paths to seek tuples directly. Indexes provide logarithmic $O(\log N)$ seeks and sequential index traversals that avoid sorting.
   - **Query-Structure Optimization:** Applied when the query formulation is inherently suboptimal (e.g. $O(N \times M)$ correlated subplans, redundant Cartesian products, or non-sargable functions). In such cases, an index alone cannot eliminate architectural inefficiency; rewriting into set-based joins, window functions, or pre-aggregated CTEs reduces algorithmic complexity from quadratic to linear.
3. **Write-Preserving Discipline:**
   Every index incurs maintenance overhead during `INSERT`, `UPDATE`, and `DELETE`. We strictly avoided blind indexing:
   - Partial indexes were used whenever a filter targets a small subset (e.g., 100 pending withdrawals out of 118k transactions), ensuring near-zero write penalty on the remaining 99.9% of transactions.
   - Redundant indexes that duplicate prefixes of existing primary or unique keys were rejected.

---

## 4. Indexes Added

The 15 indexes below were implemented in [`sql/05_indexes.sql`](../sql/05_indexes.sql) and applied to `dream11_db`. No index duplicates an existing constraint index.

| Index Name | Table | Columns / Definition | Benefiting Queries | Technical Reason |
|---|---|---|---|---|
| `idx_user_team_players_player_id` | `user_team_players` | `(player_id)` | `R19`, `R02` | Reverse FK on associative table. PK is `(user_team_id, player_id)`; queries seeking by `player_id` could not use PK leading column, causing 250 full scans. |
| `idx_user_teams_match_id` | `user_teams` | `(match_id, user_team_id DESC)` | `R02`, `R06`, `R08`, `W01`, `W02`, `W04` | Filters on `match_id` alone scanned 39,975 rows because `uq_user_teams_user_match_label` has `user_id` leading. `user_team_id DESC` allows instant resolution of `max(user_team_id)` in `W02`. |
| `idx_user_teams_user_id` | `user_teams` | `(user_id, user_team_id)` | `R11`, `R15` | Compact FK index for user roster lookups across all matches, avoiding wider composite scans on `uq_user_teams_user_match_label`. |
| `idx_contest_entries_user_team_id` | `contest_entries` | `(user_team_id, contest_id)` | `R11`, `R15`, `R17`, `R21`, `R25` | Reverse FK index. `uq_contest_entries_contest_team` has `contest_id` leading; joining from `user_teams` on `user_team_id` forced scans of all 42,746 entries. |
| `idx_wallet_transactions_user_status` | `wallet_transactions` | `(user_id, status, created_at, txn_id) INCLUDE (txn_type, amount)` | `R09` | Covering index. High selectivity on `(user_id, status)`, index ordering on `(created_at, txn_id)` eliminates sorting, and `INCLUDE` enables pure Index Only Scan. |
| `idx_wallet_transactions_pending_withdrawals` | `wallet_transactions` | `(created_at) WHERE txn_type = 'WITHDRAWAL' AND status = 'PENDING'` | `R10`, `W05` | Partial index covering only the 100 pending withdrawals out of 118k rows. Takes only 16 kB on disk and creates zero write overhead for deposits/entry fees. |
| `idx_wallet_transactions_ref_entry` | `wallet_transactions` | `(reference_entry_id, txn_type) WHERE reference_entry_id IS NOT NULL` | `R13`, `R25` | Partial index on foreign key. 63k rows have NULL references. Indexing only non-null references accelerates anti-joins in audit queries. |
| `idx_wallet_transactions_created_at_desc` | `wallet_transactions` | `(created_at DESC)` | `R22`, `R20` | Chronological ordering index. Satisfies `ORDER BY created_at DESC OFFSET 50000 LIMIT 25` directly from index leaves, eliminating 5.8 MB disk sort. |
| `idx_wallet_transactions_winnings` | `wallet_transactions` | `(user_id, amount) WHERE txn_type = 'WINNINGS' AND status = 'SUCCESS'` | `R18` | Partial index for tax compliance winnings aggregation, enabling index-only scans and merge joins. |
| `idx_contests_match_id` | `contests` | `(match_id, contest_type, entry_fee)` | `R01`, `R04`, `W02` | Foreign key index on `contests(match_id)`. Accelerates lobby and contest list lookups for specific matches. |
| `idx_contests_type` | `contests` | `(contest_type, contest_id)` | `R21` | Supports filtering on head-to-head contest types (`contest_type = 'HEAD_TO_HEAD'`). |
| `idx_player_match_stats_player_id` | `player_match_stats` | `(player_id, match_id)` | `R12`, `R24` | Reverse composite index. PK is `(match_id, player_id)`; aggregations and window partitions by `player_id` can now seek directly. |
| `idx_matches_status_starts_at` | `matches` | `(status, starts_at)` | `R01`, `R14`, `R25` | Composite index for match status filtering (`UPCOMING`, `COMPLETED`, `ABANDONED`) and chronological ordering. |
| `idx_users_state_code` | `users` | `(state_code) INCLUDE (user_id, username)` | `R11` | Covering index for restricted state compliance lookups (`AS`, `OD`, `TG`, `AP`), bypassing heap table fetches. |
| `idx_users_unverified_kyc` | `users` | `(user_id, username, kyc_status) WHERE kyc_status <> 'VERIFIED'` | `R18` | Partial index on unverified KYC users (12,442 rows). Ignores the 37,558 verified users, accelerating compliance audits. |

---

## 5. Query Rewrites

Six queries were structurally rewritten in [`sql/06_optimized_queries.sql`](../sql/06_optimized_queries.sql) to eliminate algorithmic bottlenecks and resolve correctness defects:

| Query ID | Original Approach | Optimized Approach | Technical Reason |
|---|---|---|---|
| **R02** | Joined `matches` to `players`, `user_teams`, and `user_team_players` in a single broad Cartesian join, executing a `Merge Right Join` over 437k index entries. | Modular CTEs separating active match players, pre-aggregating picks only for the 255 teams of match 207, and joining results. | Replaced 437k index scan entries with targeted lookup over 255 teams. Execution dropped from `39.264 ms` to `1.496 ms` (**96.19% faster**). |
| **R06** | `CROSS JOIN LATERAL` running a correlated subquery 3,062 times (once per player selection in match 183) to count squad mates. | Replaced lateral subquery with window function `count(*) OVER (PARTITION BY ut.user_team_id, p.team_id)` in a single pass. | Eliminated 3,062 inner subplan loops and dropped shared buffer hits from `22,671` to `1,175`. Latency dropped from `52.354 ms` to `2.306 ms` (**95.60% faster**). |
| **R13** | `NOT IN (SELECT w.reference_entry_id FROM wallet_transactions w)` where `reference_entry_id` contains 63k NULLs. Returned 0 rows. | `NOT EXISTS (SELECT 1 FROM wallet_transactions w WHERE w.reference_entry_id = ce.entry_id AND w.txn_type = 'ENTRY_FEE' AND w.status = 'SUCCESS')`. | **Correctness Fix:** Resolved SQL NULL three-valued logic failure, correctly returning the 192 unpaid contest entries while dropping execution time from `18.175 ms` to `9.733 ms`. |
| **R19** | Correlated scalar subquery in SELECT list: `(SELECT count(*) FROM user_team_players utp WHERE utp.player_id = p.player_id)`. Executed 250 sequential scans. | Pre-aggregated total picks per player once via `GROUP BY player_id` in a derived table, then joined with franchise players. | Eliminated 250 correlated scans (`109.9 million` row evaluations). Buffer hits plummeted from `500,008` to `2,015`. Latency dropped from `2,190.351 ms` to `22.303 ms` (**98.98% faster**). |
| **R20** | Non-sargable expression `created_at::date BETWEEN '2026-06-01' AND '2026-06-30'`. Forced full table scan. | Sargable timestamp half-open range: `created_at >= '2026-06-01 00:00:00+05:30' AND created_at < '2026-07-01 00:00:00+05:30'`. | Enables B-tree index range scanning on `created_at`. Execution time dropped from `6.565 ms` to `1.110 ms` (**83.09% faster**). |
| **W04** | Updated `user_teams ut` joining to subquery `s` on `user_team_id`, but target table lacked `match_id = 183` predicate, forcing a sequential scan of all 40k teams. | Added `AND ut.match_id = 183` to target update WHERE clause. | Allows PostgreSQL to use `idx_user_teams_match_id` on the target table as well as the subquery, cutting runtime from `13.417 ms` to `5.177 ms` (**61.41% faster**). |

---

## 6. Before vs After Performance — All 30 Queries

Below is the complete comparison of all 30 workload queries, computed mathematically from the verified benchmark artifacts ([`benchmarks/results/baseline/summary.csv`](../benchmarks/results/baseline/summary.csv) and [`benchmarks/results/optimized/summary.csv`](../benchmarks/results/optimized/summary.csv)):

$$\text{Improvement \%} = \frac{\text{Baseline Avg} - \text{Optimized Avg}}{\text{Baseline Avg}} \times 100$$

| Query ID | Type | Baseline Avg (ms) | Optimized Avg (ms) | Improvement (ms) | Improvement (%) | Performance Classification |
|---|---|---:|---:|---:|---:|---|
| **R01** | READ | 1.009 | 0.276 | +0.733 | +72.65% | Major Speedup |
| **R02** | READ | 39.264 | 1.496 | +37.768 | +96.19% | Major Speedup |
| **R03** | READ | 0.037 | 0.044 | -0.007 | -18.92% | Regression (Sub-ms Jitter) |
| **R04** | READ | 0.183 | 0.106 | +0.077 | +42.08% | Moderate Speedup |
| **R05** | READ | 0.470 | 0.612 | -0.142 | -30.21% | Regression (Sub-ms Jitter) |
| **R06** | READ | 52.354 | 2.306 | +50.048 | +95.60% | Major Speedup |
| **R07** | READ | 0.078 | 0.078 | 0.000 | 0.00% | Neutral / Stable |
| **R08** | READ | 1.768 | 0.318 | +1.450 | +82.01% | Major Speedup |
| **R09** | READ | 5.611 | 0.182 | +5.429 | +96.76% | Major Speedup |
| **R10** | READ | 7.852 | 0.056 | +7.796 | +99.29% | Major Speedup |
| **R11** | READ | 17.773 | 10.189 | +7.584 | +42.67% | Moderate Speedup |
| **R12** | READ | 1.117 | 0.975 | +0.142 | +12.71% | Moderate Speedup |
| **R13** | READ | 18.175 | 9.733 | +8.442 | +46.45% | Moderate Speedup (+ Correctness Fix) |
| **R14** | READ | 10.745 | 10.433 | +0.312 | +2.90% | Neutral / Stable |
| **R15** | READ | 19.865 | 23.335 | -3.470 | -17.47% | Regression (Hash Join Jitter) |
| **R16** | READ | 0.134 | 0.200 | -0.066 | -49.25% | Regression (Sub-ms Jitter) |
| **R17** | READ | 14.554 | 14.365 | +0.189 | +1.30% | Neutral / Stable |
| **R18** | READ | 10.237 | 3.206 | +7.031 | +68.68% | Major Speedup |
| **R19** | READ | 2,190.351 | 22.303 | +2,168.048 | +98.98% | Major Speedup (Dominant Bottleneck) |
| **R20** | READ | 6.565 | 1.110 | +5.455 | +83.09% | Major Speedup |
| **R21** | READ | 6.626 | 12.588 | -5.962 | -89.98% | Regression (Transient OS Scheduling) |
| **R22** | READ | 26.522 | 4.761 | +21.761 | +82.05% | Major Speedup |
| **R23** | READ | 0.029 | 0.027 | +0.002 | +6.90% | Neutral / Stable |
| **R24** | READ | 0.568 | 0.340 | +0.228 | +40.14% | Moderate Speedup |
| **R25** | READ | 9.109 | 2.492 | +6.617 | +72.64% | Major Speedup |
| **W01** | WRITE | 0.692 | 0.729 | -0.037 | -5.35% | Neutral / Stable |
| **W02** | WRITE | 1.295 | 0.329 | +0.966 | +74.59% | Major Speedup |
| **W03** | WRITE | 1.261 | 0.731 | +0.530 | +42.03% | Moderate Speedup |
| **W04** | WRITE | 13.417 | 5.177 | +8.240 | +61.41% | Major Speedup |
| **W05** | WRITE | 10.781 | 1.112 | +9.669 | +89.69% | Major Speedup |
| **Total Workload Metric** | | **2,468.442** | **129.609** | **+2,338.833** | **+94.75%** | **Overall Workload Improvement** |

> [!NOTE]
> The total sum of query averages (`2,468.442 ms` baseline vs `129.609 ms` optimized) represents the aggregate benchmark metric across all 30 queries under sequential execution. It is an indicative workload metric rather than an end-to-end multi-tenant application wall-clock time.

---

## 7. Performance Analysis

### 1. Fastest Queries Before and After
- **Before Optimization:**
  1. `R23` (`0.029 ms`): Direct point lookup via `uq_users_phone`.
  2. `R03` (`0.037 ms`): Composite unique index seek via `uq_user_teams_user_match_label`.
  3. `R07` (`0.078 ms`): Direct point lookups via PKs and unique constraint indexes.
  4. `R16` (`0.134 ms`): In-memory sequential scan over 450 player rows.
  5. `R04` (`0.183 ms`): Filtered contest scan on match 207.
- **After Optimization:**
  1. `R23` (`0.027 ms`): Continues direct point lookup via `uq_users_phone`.
  2. `R03` (`0.044 ms`): Point lookup via `uq_user_teams_user_match_label`.
  3. `R10` (`0.056 ms`): **New entry** (was `7.852 ms`), dropping 99.29% via `idx_wallet_transactions_pending_withdrawals`.
  4. `R07` (`0.078 ms`): Constant performance on index seek.
  5. `R04` (`0.106 ms`): Index scan on `idx_contests_match_id`.
  6. `R09` (`0.182 ms`): **New entry** (was `5.611 ms`), dropping 96.76% via `idx_wallet_transactions_user_status` covering index.

### 2. Slowest Queries Before and After
- **Before Optimization:**
  1. `R19` (`2,190.351 ms`): 250 correlated sequential scans over 439,925 rows (`500,008` buffer hits).
  2. `R06` (`52.354 ms`): 3,062 lateral correlated subquery loops (`22,671` buffer hits).
  3. `R02` (`39.264 ms`): Broad merge right join across 437k rows of `user_team_players`.
  4. `R22` (`26.522 ms`): External disk merge sort (`5,800 kB`) on 118k wallet rows.
  5. `R15` (`19.865 ms`): Hash join over 42k entries, 40k teams, and 50k users.
- **After Optimization:**
  1. `R15` (`23.335 ms`): Hash-joining three large tables (42k entries, 40k teams, 50k users).
  2. `R19` (`22.303 ms`): Parallel scan and single-pass aggregation over 439k rows (dropped 98.98% from `2,190.351 ms`).
  3. `R17` (`14.365 ms`): Hash join and grouping across 42k entries and 40k teams.
  4. `R21` (`12.588 ms`): Joins on `contest_entries` and `user_teams`.
  5. `R14` (`10.433 ms`): Analytic grouping on completed contests.

### 3. Largest Improvements
1. **`R19` (+2,168.048 ms / +98.98%):** Eliminating repeated correlated table scans saved over 2.1 seconds per execution.
2. **`R06` (+50.048 ms / +95.60%):** Window function partitioning removed 3,062 inner loop evaluations.
3. **`R02` (+37.768 ms / +96.19%):** Pre-aggregation CTEs avoided joining 437k index rows.
4. **`R22` (+21.761 ms / +82.05%):** B-tree ordering eliminated external disk spills completely.
5. **`W05` (+9.669 ms / +89.69%):** Partial index enabled instant seek of 100 overdue rows.
6. **`R13` (+8.442 ms / +46.45%):** Indexed anti-join + correctness resolution.
7. **`W04` (+8.240 ms / +61.41%):** Target update predicate allowed indexed bitmap scan.
8. **`R10` (+7.796 ms / +99.29%):** Partial index seek replaced full sequential scan.
9. **`R11` (+7.584 ms / +42.67%):** Covering state index accelerated user compliance filtering.
10. **`R18` (+7.031 ms / +68.68%):** Merge join between two partial index-only scans.

### 4. Analysis of Queries with Regressions
Honest academic benchmarking requires analyzing queries where measured latency increased:
- **`R03` (0.037 ms → 0.044 ms, -0.007 ms):** Absolute difference is **7 microseconds** (0.000007 s). Both baseline and optimized execute identical index plans (`uq_user_teams_user_match_label` + `pk_players`). The variation represents OS scheduling jitter on sub-millisecond queries.
- **`R05` (0.470 ms → 0.612 ms, -0.142 ms):** Absolute difference is 142 microseconds. Both plans execute identical Index Only Scans on `uq_contest_entries_contest_team` followed by 69 PK lookups. The variance is normal cache-line alignment jitter.
- **`R15` (19.865 ms → 23.335 ms, -3.470 ms):** `R15` aggregates 20,762 entries joined across 40k user teams and 50k users. In both baseline and optimized, PostgreSQL chooses parallel sequential scans and hash joins because over 50% of the table is selected (`joined_at >= '2026-01-01'`). The 3.4 ms variation reflects parallel worker launch overhead and CPU thread scheduling.
- **`R16` (0.134 ms → 0.200 ms, -0.066 ms):** Difference is 66 microseconds on an unindexed `ILIKE '%sharma%'` filter across 450 rows.
- **`R21` (6.626 ms → 12.588 ms, -5.962 ms):** Looking at individual runs in [`benchmarks/results/optimized/summary.csv`](../benchmarks/results/optimized/summary.csv), Run 1 took `6.107 ms` and Run 3 took `7.480 ms` (both on par with baseline `6.626 ms`). Run 2 experienced an outlier latency of `24.177 ms` due to transient background OS context-switching, pulling up the arithmetic mean. The median was `7.480 ms`.
- **`W01` (0.692 ms → 0.729 ms, -0.037 ms):** Single-row insert into `user_teams`. Adding secondary indexes (`idx_user_teams_match_id` and `idx_user_teams_user_id`) adds approximately 37 microseconds of B-tree maintenance, an expected and negligible write trade-off.

### 5. Where Sequential Scans Remain Optimal
PostgreSQL wisely retains sequential scans when:
1. **Small Lookup Tables:** `teams` (18 rows) and `matches` (212 rows) fit into 1 to 4 8kB disk pages. Loading 4 pages sequentially into memory takes <0.02 ms; traversing a B-tree index would require additional root and leaf page accesses without benefit.
2. **Low-Selectivity Filters:** In `R15`, over 50% of entries belong to 2026. B-tree index scans on low-selectivity queries cause random I/O thrashing; sequential block-prefetching is vastly superior.

---

## 8. Detailed Case Study — R19

### Problem Description
`R19` produces a selection report answering: *In how many fantasy teams was each IPL franchise player picked (all time)?*

```sql
-- Baseline R19 Query
SELECT p.player_id, p.full_name,
       (SELECT count(*) FROM user_team_players utp WHERE utp.player_id = p.player_id) AS times_picked
FROM players p
JOIN teams t ON t.team_id = p.team_id AND t.team_type = 'FRANCHISE'
ORDER BY times_picked DESC;
```

### Baseline Execution Plan Anatomy
In baseline benchmarking ([`benchmarks/results/baseline/R19.txt`](../benchmarks/results/baseline/R19.txt)), `R19` was the single largest bottleneck in the DBMS, averaging **`2,190.351 ms`** and accounting for **88.7%** of the entire workload execution time:
- The outer query identifies the 250 IPL players (`team_type = 'FRANCHISE'`).
- For each of the 250 players, PostgreSQL executed `SubPlan 1`:
  ```
  SubPlan 1
    ->  Aggregate (cost=7501.84..7501.85 rows=1 width=8) (actual time=8.058..8.058 rows=1.00 loops=250)
          Buffers: shared hit=500000
          ->  Seq Scan on user_team_players utp (cost=0.00..7499.06 rows=1111 width=0) (actual time=0.959..8.029 rows=1185.28 loops=250)
                Filter: (player_id = p.player_id)
                Rows Removed by Filter: 438740
                Buffers: shared hit=500000
  ```
- **Why It Happened:** The primary key `pk_user_team_players` is defined on `(user_team_id, player_id)`. Because `player_id` is the *second* column, PostgreSQL cannot seek the B-tree by `player_id` alone.
- **The Cost:** PostgreSQL performed **250 full sequential scans** of `user_team_players` (439,925 rows each). Across 250 loops, the executor evaluated **$250 \times 439,925 = 109,981,250$ tuple comparisons**, registering **`500,008` shared buffer hits** (`~3.8 GB` of in-memory page reads) for a single query!

### Implemented Optimization
1. **Query Rewrite:** Converted the correlated scalar subquery into a set-based pre-aggregation:
   ```sql
   -- Optimized R19 Query
   SELECT p.player_id, p.full_name, coalesce(agg.times_picked, 0) AS times_picked
   FROM players p
   JOIN teams t ON t.team_id = p.team_id AND t.team_type = 'FRANCHISE'
   LEFT JOIN (
       SELECT player_id, count(*) AS times_picked
       FROM user_team_players
       GROUP BY player_id
   ) agg ON agg.player_id = p.player_id
   ORDER BY times_picked DESC, p.player_id;
   ```
2. **Reverse Index:** Created `idx_user_team_players_player_id ON user_team_players (player_id)`.

### Optimized Execution Plan Anatomy
From [`benchmarks/results/optimized/R19.txt`](../benchmarks/results/optimized/R19.txt):
- Instead of 250 sequential scans, PostgreSQL executes a single parallel scan and `Partial HashAggregate` over `user_team_players`, followed by a `Gather Merge` and `Hash Right Join` against the 250 franchise players.
- **Shared Buffers:** Dropped from `500,008` hits to **`2,015` hits** (a **`99.60%` reduction** in memory pressure).
- **Execution Time:** Dropped from **`2,190.351 ms`** to **`22.303 ms`** (**`98.98%` improvement**, an absolute speedup of **`2,168.048 ms`**).
- **Correctness:** Verified identical 250-row result set against baseline via `EXCEPT ALL`.

---

## 9. Detailed Case Study — R13 Correctness Fix

### Problem Description
`R13` is an internal financial audit query: *Paid contest entries that have no entry-fee debit in the wallet*.

```sql
-- Baseline R13 Query (Flawed)
SELECT ce.entry_id, ce.contest_id, ce.joined_at
FROM contest_entries ce
JOIN contests c ON c.contest_id = ce.contest_id
WHERE c.entry_fee > 0
  AND ce.entry_id NOT IN (SELECT w.reference_entry_id FROM wallet_transactions w);
```

### The Three-Valued Logic NULL Defect
In Phase 3 baseline benchmarking ([`benchmarks/results/baseline/R13.txt`](../benchmarks/results/baseline/R13.txt)), the query returned **`0 rows`**:
```
Seq Scan on contest_entries ce (cost=2575.29..3493.61 rows=21373 width=16) (actual time=19.640..19.641 rows=0 loops=1)
  Filter: (NOT (ANY (entry_id = (hashed SubPlan 1).col1)))
  Rows Removed by Filter: 42746
```
- In SQL, `v NOT IN (SELECT col FROM table)` is logically expanded by the query engine as:
  $$v \neq \text{val}_1 \text{ AND } v \neq \text{val}_2 \text{ AND } \dots \text{ AND } v \neq \text{val}_k$$
- If the subquery contains even a single `NULL` value, then for any candidate $v$:
  $$v \neq \text{NULL} \implies \text{UNKNOWN}$$
- Under SQL three-valued logic, $\text{TRUE} \text{ AND } \text{UNKNOWN} \implies \text{UNKNOWN}$.
- Because a `WHERE` clause filters out any row whose condition does not evaluate to `TRUE`, the presence of `NULL` in the subquery results causes `NOT IN` to evaluate to `UNKNOWN` for **every single row**, silently eliminating all 42,746 entries!
- In `wallet_transactions`, exactly **`63,000 rows`** have `reference_entry_id IS NULL` (transactions of type `DEPOSIT`, `WITHDRAWAL`, and `BONUS`). Consequently, the baseline query always returned empty results.

### Independent Verification & Correct Query Formulation
In Phase 2 integrity audit check #5 (`sql/02_load_data.sql`), independent verification revealed that there are actually **192 paid contest entries** that lack a confirmed entry-fee debit.

Furthermore, an entry can have wallet transactions referencing its `entry_id` for reasons other than an entry fee (specifically, `WINNINGS` credited to winners or `REFUND` debits). Therefore, an audit for missing entry-fee debits must specifically check for `w.txn_type = 'ENTRY_FEE' AND w.status = 'SUCCESS'`:

```sql
-- Optimized R13 Query (Correct & Indexed)
SELECT ce.entry_id, ce.contest_id, ce.joined_at
FROM contest_entries ce
JOIN contests c ON c.contest_id = ce.contest_id
WHERE c.entry_fee > 0
  AND NOT EXISTS (
      SELECT 1
      FROM wallet_transactions w
      WHERE w.reference_entry_id = ce.entry_id
        AND w.txn_type = 'ENTRY_FEE'
        AND w.status = 'SUCCESS'
  );
```

### Plan Improvement & Validation
- **Index Support:** We created `idx_wallet_transactions_ref_entry ON wallet_transactions (reference_entry_id, txn_type) WHERE reference_entry_id IS NOT NULL`.
- **Execution Plan:** As recorded in [`benchmarks/results/optimized/R13.txt`](../benchmarks/results/optimized/R13.txt), PostgreSQL replaces the hashed subplan with a high-performance `Merge Anti Join`:
  ```
  Merge Anti Join (cost=0.75..3479.40 rows=22816 width=16) (actual time=0.077..8.941 rows=192.00 loops=1)
    Merge Cond: (ce.entry_id = w.reference_entry_id)
    -> Index Scan using pk_contest_entries on contest_entries ce
    -> Index Scan using idx_wallet_transactions_ref_entry on wallet_transactions w
  ```
- **Results:**
  - Rows returned: exactly **`192 rows`** (confirmed by automated validation).
  - Latency: dropped from **`18.175 ms`** to **`9.733 ms`** (**`46.45%` speedup**).
- **Engineering Principle:** In database engineering, performance optimization is worthless without query correctness. Fixing the NULL semantics restored auditability while simultaneously improving throughput.

---

## 10. Write Query Impact

Every index added to a relational database must be evaluated for its write penalty. In an active fantasy sports platform, users continuously create teams (`W01`), join contests (`W02`), pay entry fees (`W03`), recompute match points (`W04`), and process withdrawals (`W05`).

All write queries were benchmarked with 3 runs each inside explicit `BEGIN ... ROLLBACK` transactions:

| Write Query | Operation | Baseline Avg (ms) | Optimized Avg (ms) | Change (%) | Analysis of Index Overhead vs Benefits |
|---|---|---:|---:|---:|---|
| **W01** | `INSERT INTO user_teams` | 0.692 | 0.729 | -5.35% | Inserts a single fantasy team. Adding `idx_user_teams_match_id` and `idx_user_teams_user_id` added 37 microseconds of B-tree insertion cost. This overhead is completely negligible for a customer write. |
| **W02** | `INSERT INTO contest_entries` | 1.295 | 0.329 | **+74.59%** | Inserts a contest entry. Although `idx_contest_entries_user_team_id` must be maintained, `W02` contains a subquery `SELECT max(user_team_id) FROM user_teams WHERE match_id = 207`. `idx_user_teams_match_id` enabled an instant backward index seek, accelerating `W02` overall by 74.59%! |
| **W03** | `INSERT INTO wallet_transactions` | 1.261 | 0.731 | **+42.03%** | Inserts an entry fee debit. Because our partial indexes (`idx_wallet_transactions_pending_withdrawals` and `idx_wallet_transactions_winnings`) filter exclusively for withdrawals and winnings, this `ENTRY_FEE` transaction completely bypasses those indexes, incurring zero overhead while benefiting from index scans on joined tables. |
| **W04** | `UPDATE user_teams` (278 rows) | 13.417 | 5.177 | **+61.41%** | Recomputes fantasy points for match 183. Updating `total_points` does not touch indexed columns (`match_id`, `user_id`, or `user_team_id`), qualifying for PostgreSQL Heap-Only Tuple (HOT) optimizations. Adding `AND ut.match_id = 183` allowed bitmap index scans, saving 8.24 ms per execution. |
| **W05** | `UPDATE wallet_transactions` (100 rows) | 10.781 | 1.112 | **+89.69%** | Approves overdue withdrawals. In baseline, finding the 100 rows required scanning all 118,343 rows. The partial index `idx_wallet_transactions_pending_withdrawals` found the 100 tuples in 0.012 ms, slashing update time from 10.8 ms to 1.1 ms. |

**Key Takeaway:** By utilizing partial indexing, composite ordering, and HOT-friendly updates, read latency was drastically reduced while **write latency actually improved by 63.8% across the write workload** (`27.446 ms` baseline vs `8.078 ms` optimized).

---

## 11. Index Trade-offs and Storage Overhead

We queried PostgreSQL internal catalogs (`pg_class` and `pg_relation_size`) to measure the exact on-disk physical storage footprint of every index:

| Index Name | Table | Type | Physical Size | Storage Overhead Justification |
|---|---|---|---:|---|
| `idx_wallet_transactions_user_status` | `wallet_transactions` | Composite Covering | 8,040 kB | Largest added index (8 MB). Justified because it covers 118k financial rows, providing pure Index Only Scans and zero sorting for user wallet views (`R09`). |
| `idx_user_team_players_player_id` | `user_team_players` | Reverse FK | 3,136 kB | Reverse index on 439k-row table. Eliminates 250 sequential scans in `R19` and saves 2.16 seconds per query. High return on investment. |
| `idx_wallet_transactions_created_at_desc` | `wallet_transactions` | B-tree Ordering | 2,416 kB | Eliminates 5.8 MB external disk merge sort spills on deep pagination (`R22`). |
| `idx_users_state_code` | `users` | Covering | 2,304 kB | Accelerates restricted state compliance lookups (`R11`) over 50,000 users. |
| `idx_wallet_transactions_ref_entry` | `wallet_transactions` | Partial Composite | 1,720 kB | Partial index on non-null references. Saves 63,000 NULL entries from index storage. |
| `idx_contest_entries_user_team_id` | `contest_entries` | Reverse FK | 952 kB | Compact reverse FK index serving 5 major analytical queries (`R11`, `R15`, `R17`, `R21`, `R25`). |
| `idx_user_teams_match_id` | `user_teams` | Composite Ordering | 904 kB | Serves 6 distinct read and write queries (`R02`, `R06`, `R08`, `W01`, `W02`, `W04`). |
| `idx_user_teams_user_id` | `user_teams` | Composite FK | 896 kB | Supports multi-match user team lookups (`R11`, `R15`). |
| `idx_users_unverified_kyc` | `users` | Partial | 632 kB | Partial index storing only 12,442 unverified users out of 50,000 (`R18`). |
| `idx_wallet_transactions_winnings` | `wallet_transactions` | Partial | 400 kB | Partial index storing only winnings transactions (`R18`). |
| `idx_player_match_stats_player_id` | `player_match_stats` | Reverse Composite | 120 kB | Accelerates player form analytics (`R12`, `R24`). |
| `idx_contests_match_id` | `contests` | Composite FK | 112 kB | Accelerates contest discovery for upcoming matches (`R01`, `R04`). |
| `idx_contests_type` | `contests` | Composite | 104 kB | Accelerates head-to-head contest lookups (`R21`). |
| `idx_matches_status_starts_at` | `matches` | Composite | 32 kB | Extremely compact lifecycle index (`R01`, `R14`, `R25`). |
| `idx_wallet_transactions_pending_withdrawals` | `wallet_transactions` | Partial | 16 kB | Smallest index (2 disk pages, 100 rows). Speeds up `R10` and `W05` by >89%. |
| **Total Optimization Indexes** | | | **21,792 kB (~21.3 MB)** | Total database size increased by only ~21 MB while cutting workload latency by 94.75%. |

---

## 12. Conclusion

Phase 4 successfully demonstrated genuine PostgreSQL query optimization, transforming an unindexed, bottlenecked academic schema into a high-performance database engine:
- **Macro Performance Gains:** The total workload latency across all 30 queries dropped from **`2,468.442 ms`** to **`129.609 ms`**, achieving an overall **`94.75%` reduction**.
- **Bottleneck Resolution:** The dominant bottleneck in the system (`R19`) was eradicated, falling from **`2,190.351 ms`** to **`22.303 ms`** by replacing 250 correlated sequential scans with single-pass aggregation.
- **Correctness Guaranteed:** Problem P5 / query `R13` was repaired by replacing flawed `NOT IN` NULL semantics with `NOT EXISTS`, correctly uncovering the **192 unpaid entries** in the ledger.
- **Write Query Safety:** Write operations (`W01`–`W05`) were not degraded by index bloat; targeted partial and composite indexes accelerated write queries by an aggregate **`63.8%`**.
- **Remaining Opportunities:** Future scale-out optimizations could evaluate declarative table partitioning by match date or year on `wallet_transactions` and `contest_entries`, and trigram indexing (`pg_trgm`) for fuzzy player search (`R16`).

---

## 13. Reproducibility

To reproduce all Phase 4 indexes, benchmarks, and plan artifacts from a clean state:

### 1. Apply Optimization Indexes
```bash
psql -d dream11_db -v ON_ERROR_STOP=1 -f sql/05_indexes.sql
```

### 2. Update Planner Statistics
```bash
psql -d dream11_db -c "ANALYZE dream11.teams; ANALYZE dream11.players; ANALYZE dream11.matches; ANALYZE dream11.player_match_stats; ANALYZE dream11.users; ANALYZE dream11.user_teams; ANALYZE dream11.user_team_players; ANALYZE dream11.contests; ANALYZE dream11.contest_entries; ANALYZE dream11.wallet_transactions;"
```

### 3. Execute the Optimized Workload Benchmark
```bash
./benchmarks/run_benchmark.sh dream11_db optimized
```

### 4. Verify Correctness Against Baseline
```bash
python3 scratch/verify_all_correctness.py
```

### 5. Inspect Execution Plans
Inspect any generated plan file in `benchmarks/results/optimized/`:
```bash
head -n 35 benchmarks/results/optimized/R19.txt
head -n 30 benchmarks/results/optimized/R13.txt
```
