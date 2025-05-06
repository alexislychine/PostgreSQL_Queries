#!/bin/bash

# Define connection parameters
PGUSER="your_user"
PGDATABASE="your_database"
PGHOST="localhost"
PGPORT="5432"
PGPASSWORD="your_password"   # Optional: use environment variable for better security

# Please update the file as follow chmod +x pg_healthcheck.sh
# Export PGPASSWORD if needed
export PGPASSWORD

# Output file
OUTPUT_FILE="healthcheck_result.txt"
echo "PostgreSQL Health Check Report" > "$OUTPUT_FILE"
echo "Generated on: $(date)" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"

# Run queries
psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -Atc "
SELECT '--- Active Sessions ---';
SELECT usename, datname, state, count(*) FROM pg_stat_activity GROUP BY 1, 2, 3, 4 ORDER BY 4 DESC;

SELECT '--- Index Usage ---';
SELECT relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch FROM pg_stat_user_indexes;

SELECT '--- Background Writer Stats ---';
SELECT checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time, buffers_clean FROM pg_stat_bgwriter;

SELECT '--- Blocking Queries ---';
SELECT query FROM pg_stat_activity WHERE pid IN (
  SELECT unnest(pg_blocking_pids(pid)) AS blocked_by
  FROM pg_stat_activity
  WHERE cardinality(pg_blocking_pids(pid)) > 0
);

SELECT '--- Blocking Details ---';
SELECT activity.pid, activity.usename, activity.query,
       blocking.pid AS blocking_id, blocking.query AS blocking_query
FROM pg_stat_activity AS activity
JOIN pg_stat_activity AS blocking ON blocking.pid = ANY(pg_blocking_pids(activity.pid));

SELECT '--- Database Statistics ---';
SELECT datname, conflicts, temp_files, pg_size_pretty(temp_bytes) AS temp_file_size,
       deadlocks, idle_in_transaction_time, sessions_abandoned,
       sessions_fatal, sessions_killed, stats_reset
FROM pg_stat_database ORDER BY temp_bytes DESC;

SELECT '--- Cache Hit Ratio ---';
SELECT datname, ROUND(100.0 * blks_hit / NULLIF((blks_hit + blks_read), 0), 2) AS cache_hit_ratio
FROM pg_stat_database WHERE (blks_hit + blks_read) > 0;

SELECT '--- Commit Ratio ---';
SELECT datname, ROUND(100.0 * xact_commit / NULLIF((xact_commit + xact_rollback), 0), 2) AS commit_ratio
FROM pg_stat_database WHERE (xact_commit + xact_rollback) > 0;

SELECT '--- Table Tuples ---';
SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC, n_dead_tup DESC;

WITH constants AS (
-- define some constants for sizes of things
-- for reference down the query and easy maintenance
SELECT current_setting('block_size')::numeric AS bs, 23 AS hdr, 8 AS ma
),
no_stats AS (
-- screen out table who have attributes
-- which dont have stats, such as JSON
SELECT table_schema, table_name, 
n_live_tup::numeric as est_rows,
pg_table_size(relid)::numeric as table_size
FROM information_schema.columns
JOIN pg_stat_user_tables as psut
ON table_schema = psut.schemaname
AND table_name = psut.relname
LEFT OUTER JOIN pg_stats
ON table_schema = pg_stats.schemaname
AND table_name = pg_stats.tablename
AND column_name = attname 
WHERE attname IS NULL
AND table_schema NOT IN ('pg_catalog', 'information_schema')
GROUP BY table_schema, table_name, relid, n_live_tup 
),
null_headers AS (
-- calculate null header sizes
-- omitting tables which dont have complete stats
-- and attributes which aren't visible
SELECT
hdr+1+(sum(case when null_frac <> 0 THEN 1 else 0 END)/8) as nullhdr,
SUM((1-null_frac)*avg_width) as datawidth,
MAX(null_frac) as maxfracsum,
schemaname, tablename, hdr, ma, bs FROM pg_stats CROSS JOIN constants
LEFT OUTER JOIN no_stats
ON schemaname = no_stats.table_schema
AND tablename = no_stats.table_name
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
AND no_stats.table_name IS NULL
AND EXISTS ( SELECT 1
FROM information_schema.columns
WHERE schemaname = columns.table_schema
AND tablename = columns.table_name )
GROUP BY schemaname, tablename, hdr, ma, bs
), data_headers AS (
-- estimate header and row size
SELECT
ma, bs, hdr, schemaname, tablename, (datawidth+(hdr+ma-(case when hdr%ma=0 THEN ma ELSE hdr%ma END)))::numeric AS datahdr, (maxfracsum*(nullhdr+ma-(case when nullhdr%ma=0 THEN ma ELSE nullhdr%ma END))) AS nullhdr2
FROM null_headers), table_estimates AS (
-- make estimates of how large the table should be
-- based on row and page size
SELECT schemaname, tablename, bs,
reltuples::numeric as est_rows, relpages * bs as table_bytes,
CEIL((reltuples*
(datahdr + nullhdr2 + 4 + ma -
(CASE WHEN datahdr%ma=0 
THEN ma ELSE datahdr%ma END)
)/(bs-20))) * bs AS expected_bytes, reltoastrelid FROM data_headers
JOIN pg_class ON tablename = relname
JOIN pg_namespace ON relnamespace = pg_namespace.oid
AND schemaname = nspname
WHERE pg_class.relkind = 'r'),
estimates_with_toast AS (
-- add in estimated TOAST table sizes
-- estimate based on 4 toast tuples per page because we dont have 
-- anything better.  also append the no_data tables
SELECT schemaname, tablename, 
TRUE as can_estimate, est_rows,
table_bytes + ( coalesce(toast.relpages, 0) * bs ) as table_bytes,
expected_bytes + ( ceil( coalesce(toast.reltuples, 0) / 4 ) * bs ) as expected_bytes
FROM table_estimates LEFT OUTER JOIN pg_class as toast
ON table_estimates.reltoastrelid = toast.oid
AND toast.relkind = 't'),
table_estimates_plus AS (
-- add some extra metadata to the table data
-- and calculations to be reused
-- including whether we cant estimate it
-- or whether we think it might be compressed
SELECT current_database() as databasename,
schemaname, tablename, can_estimate, est_rows,
CASE WHEN table_bytes > 0
THEN table_bytes::NUMERIC
ELSE NULL::NUMERIC END
AS table_bytes,
CASE WHEN expected_bytes > 0 
THEN expected_bytes::NUMERIC
ELSE NULL::NUMERIC END
AS expected_bytes,
CASE WHEN expected_bytes > 0 AND table_bytes > 0
AND expected_bytes <= table_bytes
THEN (table_bytes - expected_bytes)::NUMERIC
ELSE 0::NUMERIC END AS bloat_bytes
FROM estimates_with_toast
UNION ALL
SELECT current_database() as databasename, 
table_schema, table_name, FALSE, 
est_rows, table_size,
NULL::NUMERIC, NULL::NUMERIC
FROM no_stats),
bloat_data AS (
-- do final math calculations and formatting
select current_database() as databasename,
schemaname, tablename, can_estimate, 
table_bytes, round(table_bytes/(1024^2)::NUMERIC,3) as table_mb,
expected_bytes, round(expected_bytes/(1024^2)::NUMERIC,3) as expected_mb,
round(bloat_bytes*100/table_bytes) as pct_bloat,
round(bloat_bytes/(1024::NUMERIC^2),2) as mb_bloat,
table_bytes, expected_bytes, est_rows
FROM table_estimates_plus)
-- filter output for bloated tables
SELECT databasename, schemaname, tablename, can_estimate, est_rows, pct_bloat, mb_bloat, table_mb FROM bloat_data
WHERE ( pct_bloat >= 50 AND mb_bloat >= 00 ) --[more than 20mb bloat,at the same time if this bloat 50% of the table size, requires vacuum full]
OR ( pct_bloat >= 25 AND mb_bloat >= 1000 ) --[more than 1gb bloat, minimum 25% of tablesize]
ORDER BY pct_bloat DESC;

" >> "$OUTPUT_FILE"

echo "✅ Health check completed. Results saved to $OUTPUT_FILE"

