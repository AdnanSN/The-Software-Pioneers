-- geo_mean(x): geometric mean as a stored aggregate function (MariaDB 10.3.3+)
-- NULLs are ignored; returns NULL for an empty group or any value <= 0.

CREATE DATABASE IF NOT EXISTS capstone_agg;
USE capstone_agg;

DROP FUNCTION IF EXISTS geo_mean;

DELIMITER //

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

DELIMITER ;

-- Demo: yearly growth factors per portfolio
DROP TABLE IF EXISTS portfolio_returns;
CREATE TABLE portfolio_returns (
  portfolio VARCHAR(20) NOT NULL,
  year      INT         NOT NULL,
  growth    DOUBLE      NULL,
  PRIMARY KEY (portfolio, year)
);

INSERT INTO portfolio_returns VALUES
  ('alpha', 2021, 1.10), ('alpha', 2022, 0.80), ('alpha', 2023, 1.25),
  ('beta',  2021, 1.05), ('beta',  2022, 1.05), ('beta',  2023, NULL),
  ('gamma', 2021, 1.50), ('gamma', 2022, 0.00), ('gamma', 2023, 1.20);

SELECT portfolio,
       ROUND(AVG(growth), 6)      AS arithmetic_mean,
       ROUND(geo_mean(growth), 6) AS geometric_mean
FROM portfolio_returns
GROUP BY portfolio
ORDER BY portfolio;

SELECT ROUND(geo_mean(growth), 6) AS overall_geo_mean
FROM portfolio_returns
WHERE growth > 0;

-- Tests: every row should return pass = 1
SELECT 'known value 2,8 -> 4' AS test,
       ABS(geo_mean(v) - 4) < 1e-9 AS pass
FROM (SELECT 2 AS v UNION ALL SELECT 8) t
UNION ALL
SELECT 'NULLs ignored', ABS(geo_mean(v) - 3) < 1e-9
FROM (SELECT 3 AS v UNION ALL SELECT NULL UNION ALL SELECT 3) t
UNION ALL
SELECT 'empty group -> NULL', geo_mean(v) IS NULL
FROM (SELECT 1 AS v) t WHERE v > 1
UNION ALL
SELECT 'non-positive -> NULL', geo_mean(v) IS NULL
FROM (SELECT 5 AS v UNION ALL SELECT -1) t
UNION ALL
SELECT 'no overflow on large product', ABS(geo_mean(v) - 1e200) / 1e200 < 1e-9
FROM (SELECT 1e200 AS v UNION ALL SELECT 1e200 UNION ALL SELECT 1e200) t;
