-- with_vs_without.sql
-- Every custom aggregate next to the plain SQL you would write without it: correctness,
-- query length and execution time compared on the same data.
-- Run adnanaggregatefn.sql and 01_retail_aggregates.sql first. Takes about three minutes,
-- most of it the custom-aggregate summary on 10,000-row groups; lower @reps to go faster.
--
--   1. The demo summary query, both ways, on portfolio_returns
--   2. The one-liners that look right and are not
--   3. A benchmark: each function with and without, on 50,000 generated rows cut into
--      500, 50 and 5 groups, @reps timed runs each after one warm-up run
--   4. Reports: query length, whether the results agree, and timings

USE capstone_agg;

-- Timed runs per query and data shape. Set @reps before running this file to change it;
-- CI uses 1:  { echo "SET @reps = 1;"; cat with_vs_without.sql; } | mariadb -u root -p
SET @reps = COALESCE(@reps, 5);

-- ---------------------------------------------------------------------------
-- 1. The summary, both ways
-- ---------------------------------------------------------------------------

-- With the custom aggregates: one GROUP BY, one line per statistic.
SELECT portfolio,
       ROUND(AVG(growth), 6)                         AS arithmetic_mean,
       ROUND(geo_mean(growth), 6)                    AS geometric_mean,
       ROUND(weighted_geo_mean(growth, capital), 6)  AS capital_weighted,
       ROUND(percentile(growth, 0.5), 6)             AS median,
       ROUND(percentile(growth, 0.9), 6)             AS p90,
       mode_value(risk)                              AS usual_risk
FROM portfolio_returns
GROUP BY portfolio
ORDER BY portfolio;

-- Without them: PERCENTILE_CONT and ROW_NUMBER are window functions, so they cannot sit in
-- the same GROUP BY as the rest. Each needs its own derived table, joined back on portfolio.
-- The geometric means need guards: LN(0) is NULL plus a warning in a SELECT (and an error
-- when the result is written to a table under strict mode), and AVG() would skip that NULL.
-- capital is NOT NULL and positive in this table; a general weighted version is in section 3.
SELECT s.portfolio,
       ROUND(s.arithmetic_mean, 6)  AS arithmetic_mean,
       ROUND(s.geometric_mean, 6)   AS geometric_mean,
       ROUND(s.capital_weighted, 6) AS capital_weighted,
       ROUND(p.median, 6)           AS median,
       ROUND(p.p90, 6)              AS p90,
       m.usual_risk
FROM (SELECT portfolio,
             AVG(growth) AS arithmetic_mean,
             IF(MIN(growth) <= 0, NULL,
                EXP(AVG(LN(IF(growth > 0, growth, NULL))))) AS geometric_mean,
             IF(MIN(growth) <= 0, NULL,
                EXP(SUM(IF(growth > 0, capital * LN(growth), NULL))
                    / SUM(IF(growth > 0, capital, NULL)))) AS capital_weighted
        FROM portfolio_returns
       GROUP BY portfolio) AS s
LEFT JOIN (SELECT DISTINCT portfolio,
                  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY growth)
                    OVER (PARTITION BY portfolio) AS median,
                  PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY growth)
                    OVER (PARTITION BY portfolio) AS p90
             FROM portfolio_returns
            WHERE growth IS NOT NULL) AS p USING (portfolio)
LEFT JOIN (SELECT portfolio, risk AS usual_risk
             FROM (SELECT portfolio, risk,
                          ROW_NUMBER() OVER (PARTITION BY portfolio
                                             ORDER BY COUNT(*) DESC, risk) AS rn
                     FROM portfolio_returns
                    GROUP BY portfolio, risk) AS counted
            WHERE rn = 1) AS m USING (portfolio)
ORDER BY s.portfolio;

-- ---------------------------------------------------------------------------
-- 2. The one-liners that look right
-- ---------------------------------------------------------------------------

-- EXP(AVG(LN(x))) is the textbook geometric mean, but LN(0) is NULL and AVG() skips it,
-- so gamma (which lost everything in 2021) gets 1.27, a 27% yearly gain. The only sign is a warning.
SELECT portfolio,
       ROUND(EXP(AVG(LN(growth))), 6) AS textbook_one_liner,
       ROUND(geo_mean(growth), 6)     AS geo_mean
FROM portfolio_returns
GROUP BY portfolio
ORDER BY portfolio;

-- ---------------------------------------------------------------------------
-- 3. Benchmark
-- ---------------------------------------------------------------------------

-- Every query reads returns_data, which has the columns of portfolio_returns plus fee_pct,
-- and returns one row per portfolio. Queries with checked = TRUE return (portfolio, val),
-- and their val is compared with the 'with' query of the same function.
CREATE OR REPLACE TABLE bench_queries (
  id       INT AUTO_INCREMENT PRIMARY KEY,
  fn       VARCHAR(40) NOT NULL,
  approach VARCHAR(40) NOT NULL,          -- 'with' = custom aggregate, anything else = without
  checked  BOOLEAN     NOT NULL DEFAULT TRUE,
  sql_text TEXT        NOT NULL,
  UNIQUE (fn, approach)
);

CREATE OR REPLACE TABLE bench_times (
  id       INT AUTO_INCREMENT PRIMARY KEY,
  shape    VARCHAR(40) NOT NULL,
  fn       VARCHAR(40) NOT NULL,
  approach VARCHAR(40) NOT NULL,
  run      INT         NOT NULL,
  ms       DOUBLE      NOT NULL
);

CREATE OR REPLACE TABLE bench_results (
  shape     VARCHAR(40) NOT NULL,
  fn        VARCHAR(40) NOT NULL,
  approach  VARCHAR(40) NOT NULL,
  portfolio VARCHAR(20) NOT NULL,
  val       VARCHAR(64) NULL,
  PRIMARY KEY (shape, fn, approach, portfolio)
);

INSERT INTO bench_queries (fn, approach, checked, sql_text) VALUES
('geo_mean', 'with', TRUE,
'SELECT portfolio, geo_mean(growth) AS val
FROM returns_data
GROUP BY portfolio'),
('geo_mean', 'without', TRUE,
'SELECT portfolio,
       IF(MIN(growth) <= 0, NULL,
          EXP(AVG(LN(IF(growth > 0, growth, NULL))))) AS val
FROM returns_data
GROUP BY portfolio'),

('weighted_geo_mean', 'with', TRUE,
'SELECT portfolio, weighted_geo_mean(growth, capital) AS val
FROM returns_data
GROUP BY portfolio'),
('weighted_geo_mean', 'without', TRUE,
'SELECT portfolio,
       IF(SUM(growth IS NOT NULL AND capital <> 0
              AND (capital < 0 OR growth <= 0)) > 0, NULL,
          EXP(SUM(IF(growth > 0 AND capital > 0, capital * LN(growth), NULL))
              / SUM(IF(growth > 0 AND capital > 0, capital, NULL)))) AS val
FROM returns_data
GROUP BY portfolio'),

('percentile', 'with', TRUE,
'SELECT portfolio, percentile(growth, 0.5) AS val
FROM returns_data
GROUP BY portfolio'),
('percentile', 'without', TRUE,
'SELECT DISTINCT portfolio,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY growth)
         OVER (PARTITION BY portfolio) AS val
FROM returns_data
WHERE growth IS NOT NULL'),

('mode_value', 'with', TRUE,
'SELECT portfolio, mode_value(risk) AS val
FROM returns_data
GROUP BY portfolio'),
('mode_value', 'without', TRUE,
'SELECT portfolio, risk AS val
FROM (SELECT portfolio, risk,
             ROW_NUMBER() OVER (PARTITION BY portfolio
                                ORDER BY COUNT(*) DESC, risk) AS rn
        FROM returns_data
       WHERE risk IS NOT NULL
       GROUP BY portfolio, risk) AS counted
WHERE rn = 1'),

('compound_discount', 'with', TRUE,
'SELECT portfolio, retail_agg.compound_discount(fee_pct) AS val
FROM returns_data
GROUP BY portfolio'),
('compound_discount', 'without', TRUE,
'SELECT portfolio,
       CASE WHEN SUM(fee_pct < 0 OR fee_pct > 100) > 0 THEN NULL
            WHEN SUM(fee_pct = 100) > 0 THEN 100
            ELSE (1 - EXP(SUM(LN(IF(fee_pct < 100, 1 - fee_pct / 100, NULL))))) * 100
       END AS val
FROM returns_data
GROUP BY portfolio'),

('harmonic_mean', 'with', TRUE,
'SELECT portfolio, retail_agg.harmonic_mean(growth) AS val
FROM returns_data
GROUP BY portfolio'),
('harmonic_mean', 'without', TRUE,
'SELECT portfolio,
       IF(MIN(growth) <= 0, NULL, COUNT(growth) / SUM(1 / NULLIF(growth, 0))) AS val
FROM returns_data
GROUP BY portfolio'),

('gini_coefficient', 'with', TRUE,
'SELECT portfolio, retail_agg.gini_coefficient(capital) AS val
FROM returns_data
GROUP BY portfolio'),
('gini_coefficient', 'without', TRUE,
'SELECT portfolio,
       IF(SUM(capital < 0) > 0 OR SUM(capital) = 0, NULL,
          2 * SUM(rn * capital) / (COUNT(*) * SUM(capital))
          - (COUNT(*) + 1e0) / COUNT(*)) AS val
FROM (SELECT portfolio, capital,
             ROW_NUMBER() OVER (PARTITION BY portfolio ORDER BY capital) AS rn
        FROM returns_data
       WHERE capital IS NOT NULL) AS ranked
GROUP BY portfolio'),

('trend_slope', 'with', TRUE,
'SELECT portfolio, retail_agg.trend_slope(year, growth) AS val
FROM returns_data
GROUP BY portfolio'),
('trend_slope', 'without (two passes)', TRUE,
'SELECT portfolio,
       SUM((year - mean_year) * (growth - mean_growth))
       / NULLIF(SUM((year - mean_year) * (year - mean_year)), 0) AS val
FROM (SELECT portfolio, year, growth,
             AVG(year)   OVER (PARTITION BY portfolio) AS mean_year,
             AVG(growth) OVER (PARTITION BY portfolio) AS mean_growth
        FROM returns_data
       WHERE year IS NOT NULL AND growth IS NOT NULL) AS centred
GROUP BY portfolio'),
('trend_slope', 'without (textbook formula)', TRUE,
'SELECT portfolio,
       (COUNT(*) * SUM(year * growth) - SUM(year) * SUM(growth))
       / NULLIF(COUNT(*) * SUM(year * year) - SUM(year) * SUM(year), 0) AS val
FROM returns_data
WHERE year IS NOT NULL AND growth IS NOT NULL
GROUP BY portfolio'),

('summary (section 1)', 'with', FALSE,
'SELECT portfolio,
       AVG(growth)                        AS arithmetic_mean,
       geo_mean(growth)                   AS geometric_mean,
       weighted_geo_mean(growth, capital) AS capital_weighted,
       percentile(growth, 0.5)            AS median,
       percentile(growth, 0.9)            AS p90,
       mode_value(risk)                   AS usual_risk
FROM returns_data
GROUP BY portfolio'),
('summary (section 1)', 'without', FALSE,
'SELECT s.portfolio, s.arithmetic_mean, s.geometric_mean, s.capital_weighted,
       p.median, p.p90, m.usual_risk
FROM (SELECT portfolio,
             AVG(growth) AS arithmetic_mean,
             IF(MIN(growth) <= 0, NULL,
                EXP(AVG(LN(IF(growth > 0, growth, NULL))))) AS geometric_mean,
             IF(MIN(growth) <= 0, NULL,
                EXP(SUM(IF(growth > 0, capital * LN(growth), NULL))
                    / SUM(IF(growth > 0, capital, NULL)))) AS capital_weighted
        FROM returns_data
       GROUP BY portfolio) AS s
LEFT JOIN (SELECT DISTINCT portfolio,
                  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY growth)
                    OVER (PARTITION BY portfolio) AS median,
                  PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY growth)
                    OVER (PARTITION BY portfolio) AS p90
             FROM returns_data
            WHERE growth IS NOT NULL) AS p USING (portfolio)
LEFT JOIN (SELECT portfolio, risk AS usual_risk
             FROM (SELECT portfolio, risk,
                          ROW_NUMBER() OVER (PARTITION BY portfolio
                                             ORDER BY COUNT(*) DESC, risk) AS rn
                     FROM returns_data
                    GROUP BY portfolio, risk) AS counted
            WHERE rn = 1) AS m USING (portfolio)');

-- run_bench(shape, reps): runs every query in bench_queries against the current returns_data.
-- One warm-up run keeps the result for the correctness check, then reps timed runs.
-- Each query is wrapped in CREATE TEMPORARY TABLE ... AS so the result is materialised
-- the same way for both approaches and nothing is sent to the client.
-- The SQL text comes only from bench_queries above, never from user input.
DELIMITER //
CREATE OR REPLACE PROCEDURE run_bench(p_shape VARCHAR(40), p_reps INT)
BEGIN
  DECLARE done BOOLEAN DEFAULT FALSE;
  DECLARE v_fn, v_approach VARCHAR(40);
  DECLARE v_checked BOOLEAN;
  DECLARE v_sql TEXT;
  DECLARE i INT;
  DECLARE t0 DATETIME(6);
  DECLARE queries CURSOR FOR
    SELECT fn, approach, checked, sql_text FROM bench_queries ORDER BY id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

  OPEN queries;
  each_query: LOOP
    SET done = FALSE;
    FETCH queries INTO v_fn, v_approach, v_checked, v_sql;
    IF done THEN
      LEAVE each_query;
    END IF;

    SET @bench_sql = CONCAT('CREATE OR REPLACE TEMPORARY TABLE bench_out AS ', v_sql);
    PREPARE stmt FROM @bench_sql;

    EXECUTE stmt;  -- warm-up
    IF v_checked THEN
      INSERT INTO bench_results
        SELECT p_shape, v_fn, v_approach, portfolio, val FROM bench_out;
    END IF;

    SET i = 1;
    WHILE i <= p_reps DO
      SET t0 = SYSDATE(6);  -- SYSDATE, unlike NOW(), is the time it is evaluated
      EXECUTE stmt;
      INSERT INTO bench_times (shape, fn, approach, run, ms)
        VALUES (p_shape, v_fn, v_approach, i, TIMESTAMPDIFF(MICROSECOND, t0, SYSDATE(6)) / 1000);
      SET i = i + 1;
    END WHILE;

    DEALLOCATE PREPARE stmt;
  END LOOP;
  CLOSE queries;
  DROP TEMPORARY TABLE IF EXISTS bench_out;
END //
DELIMITER ;

CREATE OR REPLACE TABLE returns_data (
  portfolio VARCHAR(20) NOT NULL,
  year      INT         NOT NULL,
  growth    DOUBLE      NULL,
  capital   DOUBLE      NOT NULL,
  risk      VARCHAR(10) NOT NULL,
  fee_pct   DOUBLE      NULL,          -- yearly fee in percent, for compound_discount
  PRIMARY KEY (portfolio, year)
);

-- Shape 0: the 15 demo rows, with their NULL and zero growth. Checks the edge cases agree.
INSERT INTO returns_data
SELECT portfolio, year, growth, capital, risk, 0.5 + (year MOD 3) * 0.25
FROM portfolio_returns;
CALL run_bench('demo, 3 x 5', 1);

-- Shapes 1-3: the same 50,000 generated rows, cut into fewer and larger groups.
-- seq_0_to_49999 is a table of the Sequence storage engine, built into MariaDB.
-- The values are deterministic, so every run of this script sees the same data:
-- growth 0.85 - 1.20, capital 50 - 1058, risk 40% low, 40% medium, 20% high.
SET @groups = 500;
TRUNCATE TABLE returns_data;
INSERT INTO returns_data
SELECT CONCAT('p', LPAD(seq MOD @groups, 3, '0')),
       2000 + seq DIV @groups,
       0.85 + MOD(seq * 7919, 10007) * 0.35e0 / 10007,
       50 + MOD(seq * 104729, 1009),
       ELT(1 + MOD(seq * 37, 10) DIV 4, 'low', 'medium', 'high'),
       0.5 + MOD(seq, 4) * 0.25
FROM seq_0_to_49999;
CALL run_bench('500 groups x 100 rows', @reps);

SET @groups = 50;
TRUNCATE TABLE returns_data;
INSERT INTO returns_data
SELECT CONCAT('p', LPAD(seq MOD @groups, 3, '0')),
       2000 + seq DIV @groups,
       0.85 + MOD(seq * 7919, 10007) * 0.35e0 / 10007,
       50 + MOD(seq * 104729, 1009),
       ELT(1 + MOD(seq * 37, 10) DIV 4, 'low', 'medium', 'high'),
       0.5 + MOD(seq, 4) * 0.25
FROM seq_0_to_49999;
CALL run_bench('50 groups x 1,000 rows', @reps);

SET @groups = 5;
TRUNCATE TABLE returns_data;
INSERT INTO returns_data
SELECT CONCAT('p', LPAD(seq MOD @groups, 3, '0')),
       2000 + seq DIV @groups,
       0.85 + MOD(seq * 7919, 10007) * 0.35e0 / 10007,
       50 + MOD(seq * 104729, 1009),
       ELT(1 + MOD(seq * 37, 10) DIV 4, 'low', 'medium', 'high'),
       0.5 + MOD(seq, 4) * 0.25
FROM seq_0_to_49999;
CALL run_bench('5 groups x 10,000 rows', @reps);

-- ---------------------------------------------------------------------------
-- 4. Reports
-- ---------------------------------------------------------------------------

-- 4a. Query length: lines as written above, characters with whitespace collapsed,
--     and the number of SELECTs (1 = no subquery).
SELECT fn, approach,
       LENGTH(sql_text) - LENGTH(REPLACE(sql_text, '\n', '')) + 1          AS `lines`,
       CHAR_LENGTH(REGEXP_REPLACE(TRIM(sql_text), '[[:space:]]+', ' '))    AS chars,
       (CHAR_LENGTH(sql_text)
        - CHAR_LENGTH(REPLACE(UPPER(sql_text), 'SELECT', ''))) DIV 6       AS selects
FROM bench_queries
ORDER BY id;

-- 4b. Do both approaches give the same answer for every group? Numbers must agree to
--     1e-9 relative, text exactly, NULL with NULL. groups_that_differ should be 0.
SELECT w.shape, q.fn, q.approach,
       COUNT(*) AS groups_compared,
       SUM(NOT (o.val <=> w.val
                OR COALESCE(ABS(CAST(o.val AS DOUBLE) - CAST(w.val AS DOUBLE))
                            <= 1e-9 * GREATEST(1, ABS(CAST(w.val AS DOUBLE))), FALSE))) AS groups_that_differ
FROM bench_results w
JOIN bench_queries q
  ON q.fn = w.fn AND q.approach <> 'with' AND q.checked
LEFT JOIN bench_results o
  ON o.shape = w.shape AND o.fn = q.fn AND o.approach = q.approach AND o.portfolio = w.portfolio
WHERE w.approach = 'with'
GROUP BY w.shape, q.id, q.fn, q.approach
ORDER BY w.shape DESC, q.id;  -- demo first, then 500, 50 and 5 groups

-- 4c. Timings per run (the demo shape is left out: 15 rows say nothing about speed).
--     The median is taken with this project's own percentile() aggregate.
SELECT shape, fn, approach,
       COUNT(*)                        AS runs,
       ROUND(percentile(ms, 0.5), 1)   AS median_ms,
       ROUND(MIN(ms), 1)               AS min_ms,
       ROUND(MAX(ms), 1)               AS max_ms,
       ROUND(STDDEV_SAMP(ms), 1)       AS sd_ms
FROM bench_times
WHERE shape <> 'demo, 3 x 5'
GROUP BY shape, fn, approach
ORDER BY MIN(id);

-- 4d. Side by side: median time with the custom aggregate, without it, and the ratio.
WITH medians AS (
  SELECT shape, fn, approach, percentile(ms, 0.5) AS ms, MIN(id) AS first_id
  FROM bench_times
  WHERE shape <> 'demo, 3 x 5'
  GROUP BY shape, fn, approach
)
SELECT w.shape, w.fn,
       ROUND(w.ms, 1)        AS with_ms,
       o.approach            AS compared_with,
       ROUND(o.ms, 1)        AS without_ms,
       ROUND(w.ms / o.ms, 1) AS with_over_without
FROM medians w
JOIN medians o ON o.shape = w.shape AND o.fn = w.fn AND o.approach <> 'with'
WHERE w.approach = 'with'
ORDER BY w.first_id, o.first_id;

DROP PROCEDURE run_bench;
