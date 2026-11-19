-- =====================================================================
-- Dream11 Fantasy Sports Database — Phase 5: Table Partitioning
-- File: sql/08_partitioning.sql
-- Description:
--   Implements declarative range partitioning for the financial ledger
--   table `dream11.wallet_transactions`. Includes partition definitions,
--   local index inheritance, data migration from the unpartitioned table,
--   row count distribution verification, and partition pruning tests.
--
-- Compatibility: PostgreSQL 15+ (Tested on PostgreSQL 18.6)
--
-- Technical Rationale for Partitioning wallet_transactions:
--   1. Volume & Growth: wallet_transactions is the largest transactional
--      entity (118,343 rows in seed data, scaling to ~2.37M rows at 20x,
--      and >100M rows in multi-year production).
--   2. Time-Series Query Patterns: Queries such as R20 (monthly deposit
--      aggregation) and R10 / W05 (pending withdrawals audit and payouts)
--      filter specifically on timestamp ranges (e.g. June 2026).
--   3. Partition Pruning: Queries targeting specific months or quarters
--      skip untouched partitions entirely, reducing buffer reads and index tree depth.
--   4. Data Lifecycle & Archival: Old fiscal years (e.g., 2024, 2025) can be
--      detached (`ALTER TABLE ... DETACH PARTITION`) and moved to compressed cold
--      storage or dropped without locking or vacuuming the active ledger.
--
-- Primary Key Constraint Rule in Partitioned Tables:
--   In PostgreSQL, any UNIQUE or PRIMARY KEY constraint on a partitioned table
--   MUST include all partition key columns. Therefore, the primary key is
--   defined as `(txn_id, created_at)` instead of `(txn_id)` alone.
-- =====================================================================

SET search_path TO dream11;

-- ---------------------------------------------------------------------
-- 1. Create the partitioned parent table
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dream11.wallet_transactions_partitioned CASCADE;

CREATE TABLE dream11.wallet_transactions_partitioned (
    txn_id              INTEGER                  NOT NULL,
    user_id             INTEGER                  NOT NULL,
    txn_type            VARCHAR(20)              NOT NULL,
    amount              NUMERIC(10,2)            NOT NULL,
    reference_entry_id  INTEGER,
    status              VARCHAR(20)              NOT NULL,
    created_at          TIMESTAMPTZ              NOT NULL,

    -- Primary Key must include the partition key `created_at`
    CONSTRAINT pk_wallet_txns_part PRIMARY KEY (txn_id, created_at),
    CONSTRAINT fk_wallet_user_part FOREIGN KEY (user_id)
        REFERENCES dream11.users (user_id) ON DELETE RESTRICT,
    CONSTRAINT chk_wallet_txn_type_part CHECK (txn_type IN ('DEPOSIT', 'ENTRY_FEE', 'WINNINGS', 'REFUND', 'BONUS', 'WITHDRAWAL')),
    CONSTRAINT chk_wallet_status_part CHECK (status IN ('SUCCESS', 'PENDING', 'FAILED')),
    CONSTRAINT chk_wallet_amount_pos_part CHECK (amount > 0)
) PARTITION BY RANGE (created_at);

-- ---------------------------------------------------------------------
-- 2. Define range partition boundaries
-- ---------------------------------------------------------------------

-- Historical partition: All transactions from calendar year 2025
CREATE TABLE dream11.wallet_txns_2025 PARTITION OF dream11.wallet_transactions_partitioned
    FOR VALUES FROM ('2025-01-01 00:00:00+05:30') TO ('2026-01-01 00:00:00+05:30');

-- 2026 Q1 partition: Jan 1, 2026 to Mar 31, 2026
CREATE TABLE dream11.wallet_txns_2026_q1 PARTITION OF dream11.wallet_transactions_partitioned
    FOR VALUES FROM ('2026-01-01 00:00:00+05:30') TO ('2026-04-01 00:00:00+05:30');

-- 2026 Q2 partition: Apr 1, 2026 to Jun 30, 2026 (Peak IPL season & financial audits)
CREATE TABLE dream11.wallet_txns_2026_q2 PARTITION OF dream11.wallet_transactions_partitioned
    FOR VALUES FROM ('2026-04-01 00:00:00+05:30') TO ('2026-07-01 00:00:00+05:30');

-- 2026 Q3 partition: Jul 1, 2026 to Sep 30, 2026 (Live match season & finals)
CREATE TABLE dream11.wallet_txns_2026_q3 PARTITION OF dream11.wallet_transactions_partitioned
    FOR VALUES FROM ('2026-07-01 00:00:00+05:30') TO ('2026-10-01 00:00:00+05:30');

-- Future partition: Q4 2026 onwards
CREATE TABLE dream11.wallet_txns_future PARTITION OF dream11.wallet_transactions_partitioned
    FOR VALUES FROM ('2026-10-01 00:00:00+05:30') TO ('2027-01-01 00:00:00+05:30');

-- ---------------------------------------------------------------------
-- 3. Data Migration: Populate partitioned table from source table
-- ---------------------------------------------------------------------
INSERT INTO dream11.wallet_transactions_partitioned (
    txn_id, user_id, txn_type, amount, reference_entry_id, status, created_at
)
SELECT txn_id, user_id, txn_type, amount, reference_entry_id, status, created_at
FROM dream11.wallet_transactions;

-- ---------------------------------------------------------------------
-- 4. Create local partitioned indexes
-- In PostgreSQL, indexes defined on the partitioned parent table are
-- automatically created on every existing and future child partition.
-- ---------------------------------------------------------------------

-- Covering index for R09 (user ledger history)
CREATE INDEX idx_part_wallet_user_status
    ON dream11.wallet_transactions_partitioned (user_id, status, created_at, txn_id)
    INCLUDE (txn_type, amount);

-- Ordering index for R22 pagination
CREATE INDEX idx_part_wallet_created_at_desc
    ON dream11.wallet_transactions_partitioned (created_at DESC);

-- Partial index for R10 & W05 (pending withdrawal audits)
CREATE INDEX idx_part_wallet_pending
    ON dream11.wallet_transactions_partitioned (created_at)
    WHERE txn_type = 'WITHDRAWAL' AND status = 'PENDING';

-- Partial index for R13 & R25 (non-null entry reference anti-joins)
CREATE INDEX idx_part_wallet_ref_entry
    ON dream11.wallet_transactions_partitioned (reference_entry_id, txn_type)
    WHERE reference_entry_id IS NOT NULL;

-- Partial index for R18 (winnings tax compliance)
CREATE INDEX idx_part_wallet_winnings
    ON dream11.wallet_transactions_partitioned (user_id, amount)
    WHERE txn_type = 'WINNINGS' AND status = 'SUCCESS';

-- Update planner statistics across all partitions
ANALYZE dream11.wallet_transactions_partitioned;

-- ---------------------------------------------------------------------
-- 5. Verification & Partition Pruning Demonstration
-- ---------------------------------------------------------------------

-- Verification 1: Verify row counts per partition
SELECT
    tableoid::regclass AS partition_name,
    count(*) AS total_rows,
    min(created_at) AS earliest_txn,
    max(created_at) AS latest_txn
FROM dream11.wallet_transactions_partitioned
GROUP BY tableoid
ORDER BY partition_name;

-- Verification 2: Demonstrate partition pruning on R20 (June 2026 deposits)
-- Notice that EXPLAIN ANALYZE accesses ONLY wallet_txns_2026_q2; all other partitions are pruned!
EXPLAIN (ANALYZE, BUFFERS)
SELECT day, deposits, sum(deposits) OVER (ORDER BY day) AS running_total
FROM (
    SELECT created_at::date AS day, sum(amount) AS deposits
    FROM dream11.wallet_transactions_partitioned
    WHERE txn_type = 'DEPOSIT' AND status = 'SUCCESS'
      AND created_at >= '2026-06-01 00:00:00+05:30'
      AND created_at <  '2026-07-01 00:00:00+05:30'
    GROUP BY 1
) d
ORDER BY day;

-- Verification 3: Demonstrate partition pruning on R10 (pending withdrawals older than 24h as of 2026-06-30)
-- Subplans for 2026-Q3 and Future partitions are removed from execution!
EXPLAIN (ANALYZE, BUFFERS)
SELECT txn_id, user_id, amount, created_at
FROM dream11.wallet_transactions_partitioned
WHERE txn_type = 'WITHDRAWAL' AND status = 'PENDING'
  AND created_at < TIMESTAMPTZ '2026-06-30 23:59:00+05:30' - interval '24 hours'
ORDER BY created_at;
