-- Custom aggregate functions for MariaDB (stored aggregates need 10.3.3+, JSON_TABLE needs 10.6+)
--
--   geo_mean(x)              geometric mean
--   weighted_geo_mean(x, w)  geometric mean where each value counts w times
--   percentile(x, p)         continuous percentile with linear interpolation (p in [0, 1])
--   mode_value(x)            most frequent value (ties -> smallest value)
--
-- All of them ignore NULLs and return NULL for an empty group, like AVG().

CREATE DATABASE IF NOT EXISTS capstone_agg;
USE capstone_agg;

DROP FUNCTION IF EXISTS geo_mean;
DROP FUNCTION IF EXISTS weighted_geo_mean;
DROP FUNCTION IF EXISTS percentile;
DROP FUNCTION IF EXISTS mode_value;

DELIMITER //

-- geo_mean(x): returns NULL if any value is <= 0
CREATE AGGREGATE FUNCTION geo_mean(x DOUBLE) RETURNS DOUBLE
  DETERMINISTIC
BEGIN
  DECLARE log_sum DOUBLE DEFAULT 0;
  DECLARE n BIGINT DEFAULT 0;
  DECLARE non_positive BOOLEAN DEFAULT FALSE;

  -- runs after the last row of the group
  DECLARE CONTINUE HANDLER FOR NOT FOUND
    RETURN IF(n = 0 OR non_positive, NULL, EXP(log_sum / n));

  LOOP
    FETCH GROUP NEXT ROW;
    IF x IS NOT NULL THEN
      IF x <= 0 THEN
        SET non_positive = TRUE;
      ELSE
        SET log_sum = log_sum + LN(x);  -- sum logs to avoid overflow
        SET n = n + 1;
      END IF;
    END IF;
  END LOOP;
END //

-- weighted_geo_mean(x, w) = EXP(SUM(w * LN(x)) / SUM(w))
-- Rows with a NULL x or w, or w = 0, are skipped.
-- Returns NULL if any used x is <= 0, any w is negative, or no row is used.
CREATE AGGREGATE FUNCTION weighted_geo_mean(x DOUBLE, w DOUBLE) RETURNS DOUBLE
  DETERMINISTIC
BEGIN
  DECLARE weighted_log_sum DOUBLE DEFAULT 0;
  DECLARE weight_sum DOUBLE DEFAULT 0;
  DECLARE invalid BOOLEAN DEFAULT FALSE;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
    RETURN IF(weight_sum = 0 OR invalid, NULL, EXP(weighted_log_sum / weight_sum));

  LOOP
    FETCH GROUP NEXT ROW;
    IF x IS NOT NULL AND w IS NOT NULL AND w <> 0 THEN
      IF w < 0 OR x <= 0 THEN
        SET invalid = TRUE;
      ELSE
        SET weighted_log_sum = weighted_log_sum + w * LN(x);
        SET weight_sum = weight_sum + w;
      END IF;
    END IF;
  END LOOP;
END //

-- percentile(x, p): same result as PERCENTILE_CONT(p) WITHIN GROUP (ORDER BY x),
-- but usable with GROUP BY. p must be the same for every row and between 0 and 1,
-- otherwise the result is NULL.
--
-- A stored aggregate only sees one row at a time, so the values are collected
-- into a JSON array and sorted with JSON_TABLE at the end. CAST(x AS CHAR) keeps
-- full double precision (JSON_ARRAY_APPEND would round to 9 digits).
CREATE AGGREGATE FUNCTION percentile(x DOUBLE, p DOUBLE) RETURNS DOUBLE
  DETERMINISTIC
BEGIN
  DECLARE vals LONGTEXT DEFAULT NULL;
  DECLARE n BIGINT DEFAULT 0;
  DECLARE fraction DOUBLE DEFAULT NULL;
  DECLARE bad_p BOOLEAN DEFAULT FALSE;
  DECLARE pos DOUBLE;
  DECLARE lo_val, hi_val DOUBLE;

  DECLARE CONTINUE HANDLER FOR NOT FOUND
  BEGIN
    IF n = 0 OR bad_p OR fraction IS NULL THEN
      RETURN NULL;
    END IF;

    -- 0-based position in the sorted list; interpolate between its neighbours
    SET pos = fraction * (n - 1);

    SELECT MIN(CASE WHEN rn = FLOOR(pos) + 1 THEN v END),
           MIN(CASE WHEN rn = CEIL(pos) + 1 THEN v END)
      INTO lo_val, hi_val
      FROM (SELECT v, ROW_NUMBER() OVER (ORDER BY v) AS rn
              FROM JSON_TABLE(CONCAT('[', vals, ']'), '$[*]'
                              COLUMNS (v DOUBLE PATH '$')) AS jt) AS sorted;

    RETURN lo_val + (pos - FLOOR(pos)) * (hi_val - lo_val);
  END;

  LOOP
    FETCH GROUP NEXT ROW;
    IF p IS NULL OR p < 0 OR p > 1 OR (fraction IS NOT NULL AND p <> fraction) THEN
      SET bad_p = TRUE;
    ELSE
      SET fraction = p;
    END IF;
    IF x IS NOT NULL THEN
      SET vals = CONCAT_WS(',', vals, CAST(x AS CHAR));
      SET n = n + 1;
    END IF;
  END LOOP;
END //

-- mode_value(x): most frequent non-NULL value. Ties go to the smallest value
-- (string order, so pass numbers through a numeric column if that matters).
CREATE AGGREGATE FUNCTION mode_value(x VARCHAR(255)) RETURNS VARCHAR(255)
  DETERMINISTIC
BEGIN
  DECLARE vals LONGTEXT DEFAULT NULL;
  DECLARE result VARCHAR(255);

  DECLARE CONTINUE HANDLER FOR NOT FOUND
  BEGIN
    IF vals IS NULL THEN
      RETURN NULL;
    END IF;

    SELECT v INTO result
      FROM JSON_TABLE(CONCAT('[', vals, ']'), '$[*]'
                      COLUMNS (v VARCHAR(255) PATH '$')) AS jt
     GROUP BY v
     ORDER BY COUNT(*) DESC, v
     LIMIT 1;

    RETURN result;
  END;

  LOOP
    FETCH GROUP NEXT ROW;
    IF x IS NOT NULL THEN
      SET vals = CONCAT_WS(',', vals, JSON_QUOTE(x));  -- JSON_QUOTE escapes quotes/commas
    END IF;
  END LOOP;
END //

DELIMITER ;

-- Demo: yearly growth factor, money invested and risk rating per portfolio
DROP TABLE IF EXISTS portfolio_returns;
CREATE TABLE portfolio_returns (
  portfolio VARCHAR(20) NOT NULL,
  year      INT         NOT NULL,
  growth    DOUBLE      NULL,
  capital   DOUBLE      NOT NULL,
  risk      VARCHAR(10) NOT NULL,
  PRIMARY KEY (portfolio, year)
);

INSERT INTO portfolio_returns VALUES
  ('alpha', 2020, 1.10, 100, 'medium'), ('alpha', 2021, 0.80, 120, 'high'),
  ('alpha', 2022, 1.25,  90, 'high'),   ('alpha', 2023, 1.05, 150, 'medium'),
  ('alpha', 2024, 0.95, 110, 'high'),
  ('beta',  2020, 1.05, 200, 'low'),    ('beta',  2021, 1.05, 200, 'low'),
  ('beta',  2022, NULL, 200, 'low'),    ('beta',  2023, 1.04, 210, 'medium'),
  ('beta',  2024, 1.06, 220, 'low'),
  ('gamma', 2020, 1.50,  50, 'high'),   ('gamma', 2021, 0.00,  60, 'high'),
  ('gamma', 2022, 1.20,  40, 'medium'), ('gamma', 2023, 1.10,  45, 'high'),
  ('gamma', 2024, 1.30,  55, 'medium');

-- 1. Summary per portfolio
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

-- 2. Custom aggregates in HAVING and a CTE:
--    what 1000 invested at the start would be worth at the end
WITH yearly AS (
  SELECT portfolio, geo_mean(growth) AS g, COUNT(growth) AS years
  FROM portfolio_returns
  GROUP BY portfolio
  HAVING g > 1  -- MariaDB rejects a stored aggregate written out in HAVING; use its alias
)
SELECT portfolio,
       ROUND((g - 1) * 100, 2)        AS avg_growth_pct,
       ROUND(1000 * POW(g, years), 2) AS value_of_1000
FROM yearly
ORDER BY portfolio;

-- 3. Most common risk rating per year across all portfolios
SELECT year, mode_value(risk) AS usual_risk
FROM portfolio_returns
GROUP BY year
ORDER BY year;
