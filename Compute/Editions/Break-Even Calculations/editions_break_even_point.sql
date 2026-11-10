-- =============================================================================
-- Editions break-even point: on-demand vs. Editions cost (BigQuery Editions)
-- =============================================================================
-- PURPOSE
--   Compares what your project paid for on-demand (per TiB billed) against what the
--   same workload would have cost on an Editions reservation using autoscaling only
--   (no baseline slots). Use it to see whether moving from on-demand to Editions
--   would have saved money over the window.
--   Two autoscaling models are estimated:
--     fluid    - each second rounded up to 50 slots, billed per second.
--     standard - the highest second in each minute rounded up to 50 slots and held
--                for the full minute (a more conservative, higher estimate).
--
-- OUTPUT (one row)
--   tib_billed             - TiB billed by on-demand queries in the window.
--   on_demand_cost         - tib_billed * tib_rate.
--   editions_cost_standard - estimated Editions cost using the standard model.
--   editions_cost_fluid    - estimated Editions cost using the fluid model.
--   savings_standard       - on_demand_cost - editions_cost_standard.
--   savings_fluid          - on_demand_cost - editions_cost_fluid.
--   A positive savings value means Editions would have been cheaper; negative means
--   on-demand would have been cheaper.
--   recommendation         - plain-language result based on the savings columns:
--                            savings_standard > 0   -> move to Editions
--                            only savings_fluid > 0 -> borderline (depends on per-second
--                                                      billing; test before moving)
--                            otherwise              -> stay on on-demand
--                            It compares cost only and ignores performance, baseline
--                            commitments and workload changes; treat it as a starting point.
--
-- HOW TO USE
--   1. Run in the BigQuery console, or:
--        bq query --use_legacy_sql=false --project_id=MY_PROJECT < this_file.sql
--      Needs bigquery.jobs.listAll on the project (roles/bigquery.resourceViewer).
--      Without it you only see your own jobs and the results will be too low.
--
--   2. RATES: set the two DECLAREs at the top to your actual prices.
--        slot_hour_rate - price per slot-hour for your edition and region. The default
--                         0.06 is Enterprise pay-as-you-go in US/EU regions.
--        tib_rate       - on-demand price per TiB. The default 6.25 is for US/EU regions.
--      Prices vary by edition, region and commitment; confirm against current pricing.
--
--   3. REGION: replace `region-us` in BOTH FROM clauses (JOBS_TIMELINE_BY_PROJECT and
--      JOBS_BY_PROJECT) with the region your jobs run in (region-eu,
--      region-us-central1, ...). INFORMATION_SCHEMA only returns jobs from that one
--      region. For several regions, run once per region.
--
--   4. PROJECT: by default the project the query runs in is analyzed. To analyze
--      another project, prefix BOTH views, for example:
--        `my-project`.`region-us`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_PROJECT
--        `my-project`.`region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
--      To compare a reservation shared by many projects, uncomment the OPTIONAL
--      UNION ALL block in BOTH the `timeline` and `billed` CTEs for each extra
--      project, so slot usage and on-demand cost are combined across projects.
--
--   5. WINDOW: change INTERVAL 30 DAY in start_ts (up to 180 days of history). Use a
--      window that includes your peaks (e.g. month-end), not just a quiet stretch.
--
--   6. JOB TYPES: only QUERY jobs are counted by design.
--
-- HOW IT WORKS
--   Slot usage is summed per second from JOBS_TIMELINE_BY_PROJECT (period_slot_ms /
--   1000 = slots in that second), then costed under each autoscaling model above and
--   multiplied by slot_hour_rate. On-demand cost comes from total_bytes_billed in
--   JOBS_BY_PROJECT. SCRIPT parent jobs are excluded so child jobs are not double
--   counted. Slot-hours are rounded up to 50 slots, the Editions autoscaling increment.
--
-- LIMITATIONS
--   Estimates Editions with autoscaling only and no baseline or commitment discounts,
--   so it is a conservative comparison; use the baseline queries to model those.
--   Observed on-demand usage is not limited by a reservation's max, so peaks may
--   exceed what a reservation would allow. These are estimates for a starting point,
--   not a pricing guarantee; validate against your workload and current pricing.
-- =============================================================================

-- Analysis window, truncated to the minute. Edit INTERVAL 30 DAY to change it.
DECLARE start_ts TIMESTAMP DEFAULT TIMESTAMP_TRUNC(TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY), MINUTE);
DECLARE end_ts TIMESTAMP DEFAULT TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MINUTE);
-- Prices: update to match your edition and region (see HOW TO USE, item 2).
DECLARE slot_hour_rate FLOAT64 DEFAULT 0.06;  -- Enterprise pay-as-you-go, default is US/EU regions
DECLARE tib_rate FLOAT64 DEFAULT 6.25;        -- On-Demand per TiB, default is US/EU regions

-- Raw timeline rows of query jobs for the project being analyzed.
-- Change `region-us` (and optionally prefix a project) to match your environment.
WITH timeline AS (
  (
    SELECT period_start, period_slot_ms
    FROM `region-us`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_PROJECT
    WHERE period_start >= start_ts AND period_start < end_ts
      AND job_type = 'QUERY'
      AND (statement_type IS NULL OR statement_type != 'SCRIPT')  -- avoid double-counting script parents
  )

  -- OPTIONAL: combine additional projects (e.g. a reservation with several projects
  -- assigned). Uncomment one parenthesized block per extra project and replace
  -- `other-project` and the region. Keep the filters identical to the block above.
  -- This is a UNION ALL rather than a JOIN so usage from all projects is summed per
  -- second by the `per_second` CTE below. Add the matching block to `billed` as well,
  -- or the on-demand cost will only cover the first project. Each project's region
  -- must match, and you need bigquery.jobs.listAll on every project.
  -- UNION ALL
  -- (
  --   SELECT period_start, period_slot_ms
  --   FROM `other-project`.`region-us`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_PROJECT
  --   WHERE period_start >= start_ts AND period_start < end_ts
  --     AND job_type = 'QUERY'
  --     AND (statement_type IS NULL OR statement_type != 'SCRIPT')
  -- )
),
per_second AS (
  -- Total slots in use across all queries (and projects) for each second
  SELECT
    period_start,
    SUM(period_slot_ms) / 1000 AS slots
  FROM timeline
  GROUP BY period_start
),
fluid AS (
  -- Fluid scaling: each second rounded up to 50 slots, billed per second
  -- (hence / 3600 to convert slot-seconds to slot-hours)
  SELECT SUM(CEIL(slots / 50) * 50) / 3600 AS slot_hours
  FROM per_second
),
per_minute_peak AS (
  -- Standard autoscaling: highest second in each minute, held for the full minute
  SELECT
    TIMESTAMP_TRUNC(period_start, MINUTE) AS minute,
    MAX(slots) AS peak_slots
  FROM per_second
  GROUP BY minute
),
-- Slot-hours under the standard model: each minute's peak rounded up to 50 slots,
-- held for 60 seconds (hence / 60 to convert minutes to hours).
standard AS (
  SELECT SUM(CEIL(peak_slots / 50) * 50) / 60 AS slot_hours
  FROM per_minute_peak
),
-- Bytes billed by the same queries on on-demand.
-- Change `region-us` here too.
billed AS (
  (
    SELECT total_bytes_billed
    FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
    WHERE creation_time >= start_ts AND creation_time < end_ts
      AND job_type = 'QUERY'
      AND (statement_type IS NULL OR statement_type != 'SCRIPT')
  )

  -- OPTIONAL: same extra projects as in `timeline` above. Uncomment one
  -- parenthesized block per extra project and replace `other-project` and the region.
  -- UNION ALL
  -- (
  --   SELECT total_bytes_billed
  --   FROM `other-project`.`region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
  --   WHERE creation_time >= start_ts AND creation_time < end_ts
  --     AND job_type = 'QUERY'
  --     AND (statement_type IS NULL OR statement_type != 'SCRIPT')
  -- )
),
-- What the same queries cost on on-demand: bytes billed, converted to TiB.
on_demand AS (
  SELECT SUM(total_bytes_billed) / POW(1024, 4) AS tib_billed
  FROM billed
)
-- Costs and savings. Positive savings means Editions would have been cheaper.
-- The outer SELECT adds a plain-language recommendation based on those savings.
SELECT
  *,
  CASE
    WHEN savings_standard > 0 THEN 'Move to Editions: cheaper under both autoscaling models'
    WHEN savings_fluid > 0 THEN 'Borderline: cheaper only if autoscaling bills per second (fluid); consider staying on-demand or testing first'
    ELSE 'Stay on on-demand: Editions would have cost more'
  END AS recommendation
FROM (
  SELECT
    ROUND(on_demand.tib_billed, 2) AS tib_billed,
    ROUND(on_demand.tib_billed * tib_rate, 2) AS on_demand_cost,
    ROUND(standard.slot_hours * slot_hour_rate, 2) AS editions_cost_standard,
    ROUND(fluid.slot_hours * slot_hour_rate, 2) AS editions_cost_fluid,
    ROUND(on_demand.tib_billed * tib_rate - standard.slot_hours * slot_hour_rate, 2) AS savings_standard,
    ROUND(on_demand.tib_billed * tib_rate - fluid.slot_hours * slot_hour_rate, 2) AS savings_fluid
  FROM on_demand, standard, fluid
);