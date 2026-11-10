-- =============================================================================
-- Baseline slots recommendation (BigQuery Editions)
-- =============================================================================
-- PURPOSE
--   Suggests a reservation BASELINE: the slot level your workload met or exceeded
--   in ~90% of minutes.
--   Baseline slots are billed continuously whether used or not. Autoscaled slots
--   (above baseline, up to the max) are billed per second, only while in use.
--
-- OUTPUT
--   baseline_slots - 10th percentile of per-minute slot usage, rounded DOWN to the
--                    nearest 50 (conservative: avoids over-committing).
--
-- HOW TO USE
--   1. Run in the BigQuery console, or:
--        bq query --use_legacy_sql=false --project_id=MY_PROJECT < this_file.sql
--      Needs bigquery.jobs.listAll on the project (roles/bigquery.resourceViewer).
--      Without it you only see your own jobs and the results will be too low.
--
--   2. REGION: replace `region-us` in the FROM clause with the region your jobs run in
--      (region-eu, region-us-central1, region-europe-west1, ...). INFORMATION_SCHEMA
--      only returns jobs from that one region. For several regions, run once per
--      region and size each reservation separately (reservations are regional).
--
--   3. PROJECT: by default the project the query runs in is analyzed. To analyze
--      another project, prefix the view:
--        `my-project`.`region-us`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_PROJECT
--      To size a reservation shared by many projects, run per project and add the
--      results, or use `region-us`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_ORGANIZATION
--      (needs org-level bigquery.jobs.listAll) with a project_id IN (...) filter.
--
--   4. WINDOW: change INTERVAL 30 DAY in start_ts (up to 180 days of history). Use a
--      window that includes your peaks (e.g. month-end), not just a quiet stretch.
--
--   5. JOB TYPES: only QUERY jobs are counted by design; other job types rarely
--      consume meaningful slots.
--
--   6. BASELINE PERCENTILE: OFFSET(10) means busy in 90% of minutes. Lower numbers
--      give a larger baseline. Match it to your break-even utilization (baseline
--      price / autoscale price): OFFSET(20) ~ 80% (1-year commit), OFFSET(40) ~ 60%
--      (3-year commit). Confirm discounts against current pricing.
--
-- HOW IT WORKS
--   Filters on job_creation_time (start_ts to end_ts), the partitioning column of the
--   JOBS_TIMELINE views, so only the needed partitions are scanned. Jobs created
--   before start_ts are therefore excluded, even if still running inside the window.
--   Usage is bucketed by period_start (the timeline slice start); only complete
--   minutes are analyzed, ending one minute before end_ts.
--   Sums slot usage per minute (period_slot_ms / 60000 = average slots in that
--   minute), fills idle minutes with 0, then takes percentiles of that distribution.
--   SCRIPT parent jobs are excluded so child jobs are not double counted. Results are
--   rounded to 50 slots, the Editions autoscaling increment.
--
-- LIMITATIONS
--   Usage is averaged per minute, so sub-minute bursts are smoothed out. Observed
--   on-demand usage is not limited by a reservation's baseline or max, so peaks may
--   exceed what a reservation would allow.
--   Percentiles are approximate (APPROX_QUANTILES). These are heuristics for a
--   starting point, not a pricing guarantee; validate against your workload and
--   current pricing.
-- =============================================================================

-- Analysis window, truncated to the minute. Edit INTERVAL 30 DAY to change it.
DECLARE start_ts TIMESTAMP DEFAULT TIMESTAMP_TRUNC(TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY), MINUTE);
DECLARE end_ts TIMESTAMP DEFAULT TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MINUTE);

-- One row per complete minute in the window, so idle minutes count as 0 slots.
WITH minutes AS (
  SELECT minute
  FROM UNNEST(GENERATE_TIMESTAMP_ARRAY(start_ts, TIMESTAMP_SUB(end_ts, INTERVAL 1 MINUTE), INTERVAL 1 MINUTE)) AS minute
),
-- Average slots in use per minute: slot-milliseconds / 60,000 ms per minute.
-- Change `region-us` (and optionally prefix a project) to match your environment.
usage AS (
  SELECT
    TIMESTAMP_TRUNC(period_start, MINUTE) AS minute,
    SUM(period_slot_ms) / (1000 * 60) AS slots
  FROM `region-us`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_PROJECT
  WHERE job_creation_time >= start_ts AND job_creation_time < end_ts  -- partition filter
    -- QUERY jobs only, by design. Exclude SCRIPT parent jobs, which would double
    -- count the slots already reported by their child jobs.
    AND job_type = 'QUERY'
    AND (statement_type IS NULL OR statement_type != 'SCRIPT')
  GROUP BY minute
),
-- Join onto the minute grid; minutes with no jobs get 0 slots.
per_minute AS (
  SELECT m.minute, COALESCE(u.slots, 0) AS slots
  FROM minutes m
  LEFT JOIN usage u USING (minute)
)
-- Baseline: 10th percentile (usage met or exceeded in ~90% of minutes),
-- rounded DOWN to a multiple of 50.
SELECT
  FLOOR(APPROX_QUANTILES(slots, 100)[OFFSET(10)] / 50) * 50 AS baseline_slots
FROM per_minute;
