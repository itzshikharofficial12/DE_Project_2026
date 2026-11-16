# 01 — Problem Understanding

**Project:** Dream11 Fantasy Sports Database  
**Course:** Database Management Systems  
**Database:** PostgreSQL 15+  
**Phase:** 1 — Problem Understanding

## 1. Business context

Dream11 is a fantasy-cricket platform. For each real cricket match, a user creates one or more fantasy teams by selecting 11 players from the two participating real teams, staying within a 100-credit budget. Each fantasy team has a captain (2× points) and vice-captain (1.5× points). Players earn fantasy points from their real match performance.

Users can enter contests using an entry fee paid from their wallet. Contests may distribute winnings, while abandoned matches may require refunds. The database therefore supports match-day user experiences, contest operations, fair-play checks, points calculation, wallet transactions, payouts, compliance, and business reporting.

The existing database schema is undocumented. The surviving CSV exports must be examined to reconstruct a relational schema that preserves the supplied data and supports the required workload.

## 2. Business problems, stakeholders and workload classification

| ID | Business need in my own words | Main stakeholders affected | Classification | Related queries |
|---|---|---|---|---|
| **P1 — Lobby and contest discovery** | Before a match locks, users need the upcoming-match lobby, available player pool and contest list to load quickly. Match information, contest counts and prize pools must be available without noticeable delay. | Fantasy players (users), user-app/product team | **Customer-facing / real-time** | R01, R02, R04, R08 |
| **P2 — Personal teams and live information** | Users need to open their saved fantasy teams, preview player points, see leaderboards and review wallet activity quickly, including during busy live-match periods. | Fantasy players (users), user-app team | **Customer-facing / real-time** | R03, R05, R07, R09 |
| **P3 — Reliable team and contest transactions** | Saving a team, joining a contest and recording the corresponding wallet debit must complete quickly and consistently. Related writes must not leave the system in a partially updated state. | Fantasy players, contest/product team, contest engine, finance team | **Customer-facing / real-time** | W01, W02, W03 |
| **P4 — Fair-play enforcement** | The platform must identify teams that violate selection rules, such as having the wrong number of players, exceeding the credit limit, selecting too many players from one real team, or entering multiple teams in the same contest. | Fair-play team, contest/product team | **Reporting / analytics** (with operational investigation use) | R06, R17 |
| **P5 — Entry-fee auditability** | Finance must be able to find paid contest entries that do not have a corresponding wallet entry-fee debit. The audit should reliably detect missing or inconsistent ledger records. | Finance and audit team, contest operations | **Reporting / analytics** | R13 |
| **P6 — Payouts, refunds and compliance** | Operations must identify overdue pending withdrawals, users restricted by state-specific rules, users who need KYC/TDS attention, and paid entries in abandoned matches that have not been refunded. | Payouts team, finance team, compliance team, support team | **Reporting / analytics** (some results trigger operational action) | R10, R11, R18, R25, W05 |
| **P7 — Fantasy-points calculation and player statistics** | The points engine must calculate team scores efficiently. Users and product teams also need player averages, recent form and player-selection statistics. | Points engine, fantasy players, stats/product team | **Mixed: real-time for score calculation; reporting / analytics for statistics** | R12, R19, R24, W04 |
| **P8 — Product and finance reporting at growth** | Product and finance teams need reports about contest fill rates, user winnings, head-to-head performance and deposits. These reports must remain usable as the platform grows to around 20 times the current data volume. | Product team, finance team, business analysts and management | **Reporting / analytics** | R14, R15, R16, R20, R21, R22, R23 |

## 3. Performance-oriented grouping

The project brief gives the following target groups for the large-data phase. These classifications guide later performance work; they do not change the required query results.

- **Real-time / match-day:** R01, R02, R03, R04, R05, R07, R08, R09, R23, W01, W02 and W03.
- **Interactive tools:** R06, R10, R13, R16, R22, R25, W04 and W05.
- **Reports and analytics:** R11, R12, R14, R15, R17, R18, R19, R20, R21 and R24.

A query may be used by an operational team even when it is classified as reporting or analytics. For example, an overdue-withdrawal report can be used to decide which withdrawals to process.

## 4. Assumptions

1. The supplied CSV exports are the source of truth for the initial schema. Column names and table names must match the supplied files because the provided 30-query workload depends on them.
2. A match has two participating real teams, represented by `home_team_id` and `away_team_id`.
3. A fantasy team belongs to one user and one match. Its selected players, captain and vice-captain must be valid for that match.
4. A fantasy team is intended to contain exactly 11 distinct players, use no more than 100 credits and contain no more than 7 players from either participating real team. These are business rules; a normal row-level `CHECK` constraint cannot validate counts across related rows.
5. Captain and vice-captain must be different players and should be members of the fantasy team. The cross-table membership requirement needs validation beyond a simple `CHECK`.
6. Contest entry fees, prize pools, wallet amounts and winnings are monetary values and should use exact decimal types rather than floating-point types.
7. Wallet transactions form a ledger. Deposits, entry fees, winnings, refunds, bonuses and withdrawals have different business meanings; the sign/direction of a transaction must be interpreted consistently by the application and reports.
8. Empty CSV fields must be inspected before deciding whether a column is nullable. In particular, `email`, `total_points`, `final_rank`, `invite_code` and `reference_entry_id` may have legitimate missing values as described in the project brief.
9. The exact allowed values for status, role, contest type, transaction type and KYC status will be confirmed by inspecting distinct values in the CSV files. The sample rows alone are not sufficient to establish every allowed value.
10. The seed-data row counts and all constraints must be verified by loading the supplied CSVs. No timing, integrity-check result or successful-load claim is assumed in this document.

## 5. Phase 1 conclusion

The database must provide fast match-day reads and reliable contest/wallet writes while also supporting fair-play, finance, compliance and product analytics. The first technical priority is to reconstruct a normalized, well-constrained relational schema from all ten CSV exports. The schema must preserve the supplied records and support the unchanged 30-query workload before any performance indexes or query optimizations are introduced.
