-- 01_retail_aggregates.sql
-- Retail-specific custom aggregate functions for MariaDB.
-- Needs: MariaDB 10.6+ (stored aggregates 10.3.3+, JSON_TABLE 10.6+, window functions 10.2+).
--
--   compound_discount(pct)     combined % off from several stacked offers
--   harmonic_mean(x)           correct average for rates / unit prices
--   gini_coefficient(x)        concentration of revenue (0 = equal, ->1 = one item dominates)
--   trend_slope(x, y)          least-squares slope of y over x (e.g. price per day)
--
-- Conventions (same as built-in AVG): NULL inputs are ignored; an empty group returns NULL.
-- Functions live in their own database, so other files call them as retail_agg.<name>(...).
-- Run this file FIRST, then 02_india_mall.sql and 03_germany_mall.sql.

CREATE DATABASE IF NOT EXISTS retail_agg;
USE retail_agg;

DROP FUNCTION IF EXISTS compound_discount;
DROP FUNCTION IF EXISTS harmonic_mean;
DROP FUNCTION IF EXISTS gini_coefficient;
DROP FUNCTION IF EXISTS trend_slope;

DELIMITER //

-- compound_discount(pct): stacked offers multiply, they do not add.
--   20% then 10% is 1 - 0.8*0.9 = 28% off, not 30%.
-- MariaDB has no PRODUCT() aggregate, so this cannot be written with built-ins in one pass.
-- Returns NULL if any pct is outside [0, 100].
CREATE AGGREGATE FUNCTION compound_discount(pct DOUBLE) RETURNS DOUBLE
  DETERMINISTIC
BEGIN
  DECLARE remaining DOUBLE DEFAULT 1;   -- share of the price that is still payable
  DECLARE n BIGINT DEFAULT 0;
  DECLARE invalid BOOLEAN DEFAULT FALSE;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
    RETURN IF(n = 0 OR invalid, NULL, (1 - remaining) * 100);

  LOOP
    FETCH GROUP NEXT ROW;
    IF pct IS NOT NULL THEN
      IF pct < 0 OR pct > 100 THEN
        SET invalid = TRUE;
      ELSE
        SET remaining = remaining * (1 - pct / 100);
        SET n = n + 1;
      END IF;
    END IF;
  END LOOP;
END //

-- harmonic_mean(x) = n / SUM(1/x)
-- The right average when x is a price per unit and the same MONEY is spent on each item
-- (averaging unit prices arithmetically over-weights the expensive ones).
-- Returns NULL if any x <= 0.
CREATE AGGREGATE FUNCTION harmonic_mean(x DOUBLE) RETURNS DOUBLE
  DETERMINISTIC
BEGIN
  DECLARE inv_sum DOUBLE DEFAULT 0;
  DECLARE n BIGINT DEFAULT 0;
  DECLARE invalid BOOLEAN DEFAULT FALSE;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
    RETURN IF(n = 0 OR invalid, NULL, n / inv_sum);

  LOOP
    FETCH GROUP NEXT ROW;
    IF x IS NOT NULL THEN
      IF x <= 0 THEN
        SET invalid = TRUE;
      ELSE
        SET inv_sum = inv_sum + 1 / x;
        SET n = n + 1;
      END IF;
    END IF;
  END LOOP;
END //

-- gini_coefficient(x): inequality of non-negative values, e.g. revenue per product.
--   sorted ascending x(1..n):  G = 2 * SUM(i * x(i)) / (n * SUM(x)) - (n + 1) / n
-- A stored aggregate sees one row at a time, so values are collected into a JSON-style
-- list and sorted at the end with JSON_TABLE (same technique as percentile() in PR #3).
-- Returns NULL if any x < 0 or the total is 0.
CREATE AGGREGATE FUNCTION gini_coefficient(x DOUBLE) RETURNS DOUBLE
  DETERMINISTIC
BEGIN
  DECLARE vals LONGTEXT DEFAULT NULL;
  DECLARE n BIGINT DEFAULT 0;
  DECLARE invalid BOOLEAN DEFAULT FALSE;
  DECLARE weighted_sum DOUBLE;
  DECLARE total DOUBLE;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
  BEGIN
    IF n = 0 OR invalid THEN
      RETURN NULL;
    END IF;

    SELECT SUM(rn * v), SUM(v)
      INTO weighted_sum, total
      FROM (SELECT v, ROW_NUMBER() OVER (ORDER BY v) AS rn
              FROM JSON_TABLE(CONCAT('[', vals, ']'), '$[*]'
                              COLUMNS (v DOUBLE PATH '$')) AS jt) AS sorted;

    IF total IS NULL OR total = 0 THEN
      RETURN NULL;
    END IF;
    -- 1e0 makes this a DOUBLE division: (n + 1) / n on integers is a DECIMAL rounded
    -- by div_precision_increment, which put gini(1,2,3) off by 3e-10.
    RETURN 2 * weighted_sum / (n * total) - (n + 1e0) / n;
  END;

  LOOP
    FETCH GROUP NEXT ROW;
    IF x IS NOT NULL THEN
      IF x < 0 THEN
        SET invalid = TRUE;
      ELSE
        SET vals = CONCAT_WS(',', vals, CAST(x AS CHAR));  -- CAST keeps full precision
        SET n = n + 1;
      END IF;
    END IF;
  END LOOP;
END //

-- trend_slope(x, y): ordinary least-squares slope, single pass.
-- Uses running means and co-moments (Welford-style updates) instead of SUM(x*y) - SUM(x)*SUM(y)/n,
-- because x is often a day number around 740000. Measured on MariaDB 10.11 with 365 daily points
-- of y = 0.5x - 370000: the naive formula returns 0.4999999993, this function returns 0.5.
-- Rows with a NULL x or y are skipped. NULL if fewer than 2 points or all x equal.
CREATE AGGREGATE FUNCTION trend_slope(x DOUBLE, y DOUBLE) RETURNS DOUBLE
  DETERMINISTIC
BEGIN
  DECLARE n BIGINT DEFAULT 0;
  DECLARE mean_x DOUBLE DEFAULT 0;
  DECLARE mean_y DOUBLE DEFAULT 0;
  DECLARE sxx DOUBLE DEFAULT 0;
  DECLARE sxy DOUBLE DEFAULT 0;
  DECLARE dx DOUBLE;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
    RETURN IF(n < 2 OR sxx = 0, NULL, sxy / sxx);

  LOOP
    FETCH GROUP NEXT ROW;
    IF x IS NOT NULL AND y IS NOT NULL THEN
      SET n = n + 1;
      SET dx = x - mean_x;
      SET mean_x = mean_x + dx / n;
      SET mean_y = mean_y + (y - mean_y) / n;
      SET sxx = sxx + dx * (x - mean_x);
      SET sxy = sxy + dx * (y - mean_y);
    END IF;
  END LOOP;
END //

DELIMITER ;

-- ---------------------------------------------------------------------------
-- Self-checks: every row must show pass = 1. Expected values are worked out by hand.
-- ---------------------------------------------------------------------------
SELECT 'compound 20+10 = 28' AS test,
       ABS(compound_discount(p) - 28) < 1e-9 AS pass
  FROM (SELECT 20 AS p UNION ALL SELECT 10) t
UNION ALL
SELECT 'compound 20+10+5 = 31.6 (additive would say 35)',
       ABS(compound_discount(p) - 31.6) < 1e-9
  FROM (SELECT 20 AS p UNION ALL SELECT 10 UNION ALL SELECT 5) t
UNION ALL
SELECT 'compound ignores NULL',
       ABS(compound_discount(p) - 15) < 1e-9
  FROM (SELECT 15 AS p UNION ALL SELECT NULL) t
UNION ALL
SELECT 'compound 100 = 100',
       ABS(compound_discount(p) - 100) < 1e-9
  FROM (SELECT 100 AS p UNION ALL SELECT 10) t
UNION ALL
SELECT 'compound pct > 100 -> NULL',
       compound_discount(p) IS NULL
  FROM (SELECT 20 AS p UNION ALL SELECT 120) t
UNION ALL
SELECT 'compound empty group -> NULL',
       compound_discount(p) IS NULL
  FROM (SELECT 1 AS p) t WHERE p > 1
UNION ALL
SELECT 'harmonic 40,60 = 48',
       ABS(harmonic_mean(v) - 48) < 1e-9
  FROM (SELECT 40 AS v UNION ALL SELECT 60) t
UNION ALL
SELECT 'harmonic 1,4,4 = 2',
       ABS(harmonic_mean(v) - 2) < 1e-9
  FROM (SELECT 1 AS v UNION ALL SELECT 4 UNION ALL SELECT 4) t
UNION ALL
SELECT 'harmonic with 0 -> NULL',
       harmonic_mean(v) IS NULL
  FROM (SELECT 0 AS v UNION ALL SELECT 4) t
UNION ALL
SELECT 'gini equal values = 0',
       ABS(gini_coefficient(v)) < 1e-9
  FROM (SELECT 5 AS v UNION ALL SELECT 5 UNION ALL SELECT 5 UNION ALL SELECT 5) t
UNION ALL
SELECT 'gini 0,0,0,10 = 0.75',
       ABS(gini_coefficient(v) - 0.75) < 1e-9
  FROM (SELECT 0 AS v UNION ALL SELECT 0 UNION ALL SELECT 0 UNION ALL SELECT 10) t
UNION ALL
SELECT 'gini 1,2,3,4 = 0.25',
       ABS(gini_coefficient(v) - 0.25) < 1e-9
  FROM (SELECT 1 AS v UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) t
UNION ALL
SELECT 'gini 1,2,3 = 2/9 to full double precision',
       ABS(gini_coefficient(v) - 2e0 / 9) < 1e-15
  FROM (SELECT 1 AS v UNION ALL SELECT 2 UNION ALL SELECT 3) t
UNION ALL
SELECT 'gini negative -> NULL',
       gini_coefficient(v) IS NULL
  FROM (SELECT -1 AS v UNION ALL SELECT 4) t
UNION ALL
SELECT 'slope y=2x+1 -> 2',
       ABS(trend_slope(x, 2 * x + 1) - 2) < 1e-9
  FROM (SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) t
UNION ALL
SELECT 'slope stays exact at x ~ 740000 (day numbers)',
       ABS(trend_slope(x, 0.5 * x - 370000) - 0.5) < 1e-9
  FROM (SELECT 740000 AS x UNION ALL SELECT 740001 UNION ALL SELECT 740002
        UNION ALL SELECT 740003 UNION ALL SELECT 740004) t
UNION ALL
SELECT 'slope constant y -> 0',
       ABS(trend_slope(x, 7)) < 1e-9
  FROM (SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3) t
UNION ALL
SELECT 'slope single point -> NULL',
       trend_slope(x, y) IS NULL
  FROM (SELECT 1 AS x, 2 AS y) t
UNION ALL
SELECT 'slope all x equal -> NULL',
       trend_slope(x, y) IS NULL
  FROM (SELECT 3 AS x, 1 AS y UNION ALL SELECT 3, 9) t;