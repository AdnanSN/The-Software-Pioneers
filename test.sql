-- Tests for the custom aggregates. Run adnanaggregatefn.sql first.
-- Prints every test, then a summary line that should read "N / N passed".

USE capstone_agg;

CREATE OR REPLACE TEMPORARY TABLE test_results (
  id   INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  pass BOOLEAN      NOT NULL
);

-- each test is a query returning (name, condition); a NULL condition counts as a failure
DELIMITER //
CREATE OR REPLACE PROCEDURE check_that(test_name VARCHAR(100), ok BOOLEAN)
  INSERT INTO test_results (name, pass) VALUES (test_name, IFNULL(ok, FALSE)) //
DELIMITER ;

-- geo_mean
CALL check_that('geo_mean: 2,8 -> 4',
  (SELECT ABS(geo_mean(v) - 4) < 1e-9 FROM (SELECT 2 AS v UNION ALL SELECT 8) t));
CALL check_that('geo_mean: NULLs ignored',
  (SELECT ABS(geo_mean(v) - 3) < 1e-9 FROM (SELECT 3 AS v UNION ALL SELECT NULL UNION ALL SELECT 3) t));
CALL check_that('geo_mean: empty group -> NULL',
  (SELECT geo_mean(v) IS NULL FROM (SELECT 1 AS v) t WHERE v > 1));
CALL check_that('geo_mean: non-positive -> NULL',
  (SELECT geo_mean(v) IS NULL FROM (SELECT 5 AS v UNION ALL SELECT -1) t));
CALL check_that('geo_mean: no overflow on large product',
  (SELECT ABS(geo_mean(v) - 1e200) / 1e200 < 1e-9
     FROM (SELECT 1e200 AS v UNION ALL SELECT 1e200 UNION ALL SELECT 1e200) t));

-- weighted_geo_mean
CALL check_that('weighted_geo_mean: 2^1 * 8^3 -> 2^2.5',
  (SELECT ABS(weighted_geo_mean(v, w) - POW(2, 2.5)) < 1e-9
     FROM (SELECT 2 AS v, 1 AS w UNION ALL SELECT 8, 3) t));
CALL check_that('weighted_geo_mean: equal weights = geo_mean',
  (SELECT ABS(weighted_geo_mean(growth, 7) - geo_mean(growth)) < 1e-12
     FROM portfolio_returns WHERE portfolio = 'alpha'));
CALL check_that('weighted_geo_mean: zero weight row skipped',
  (SELECT ABS(weighted_geo_mean(v, w) - 4) < 1e-9
     FROM (SELECT 4 AS v, 1 AS w UNION ALL SELECT -9, 0) t));
CALL check_that('weighted_geo_mean: NULL weight row skipped',
  (SELECT ABS(weighted_geo_mean(v, w) - 4) < 1e-9
     FROM (SELECT 4 AS v, 2 AS w UNION ALL SELECT 100, NULL) t));
CALL check_that('weighted_geo_mean: negative weight -> NULL',
  (SELECT weighted_geo_mean(v, w) IS NULL FROM (SELECT 4 AS v, 1 AS w UNION ALL SELECT 2, -1) t));
CALL check_that('weighted_geo_mean: all weights zero -> NULL',
  (SELECT weighted_geo_mean(v, w) IS NULL FROM (SELECT 4 AS v, 0 AS w UNION ALL SELECT 2, 0) t));

-- percentile
CALL check_that('percentile: median of 1,3,2 -> 2',
  (SELECT percentile(v, 0.5) = 2 FROM (SELECT 1 AS v UNION ALL SELECT 3 UNION ALL SELECT 2) t));
CALL check_that('percentile: median of 4,1,3,2 -> 2.5',
  (SELECT percentile(v, 0.5) = 2.5
     FROM (SELECT 4 AS v UNION ALL SELECT 1 UNION ALL SELECT 3 UNION ALL SELECT 2) t));
CALL check_that('percentile: p=0 -> MIN, p=1 -> MAX',
  (SELECT percentile(growth, 0) = MIN(growth) FROM portfolio_returns)
  AND (SELECT percentile(growth, 1) = MAX(growth) FROM portfolio_returns));
CALL check_that('percentile: single value',
  (SELECT percentile(v, 0.3) = 7 FROM (SELECT 7 AS v) t));
CALL check_that('percentile: negative values and duplicates',
  (SELECT percentile(v, 0.5) = -1
     FROM (SELECT -5 AS v UNION ALL SELECT -1 UNION ALL SELECT -1 UNION ALL SELECT 10) t));
CALL check_that('percentile: NULLs ignored',
  (SELECT percentile(v, 0.5) = 2
     FROM (SELECT 1 AS v UNION ALL SELECT NULL UNION ALL SELECT 3) t));
CALL check_that('percentile: empty group -> NULL',
  (SELECT percentile(v, 0.5) IS NULL FROM (SELECT 1 AS v) t WHERE v > 1));
CALL check_that('percentile: p outside [0,1] -> NULL',
  (SELECT percentile(v, 1.5) IS NULL FROM (SELECT 1 AS v) t));
CALL check_that('percentile: p changes within group -> NULL',
  (SELECT percentile(v, v / 10) IS NULL FROM (SELECT 1 AS v UNION ALL SELECT 2) t));
CALL check_that('percentile: keeps full double precision',
  (SELECT percentile(v, 0.5) = 1e0 / 3 FROM (SELECT 1e0 / 3 AS v) t));
-- cross-check against MariaDB's built-in PERCENTILE_CONT window function
CALL check_that('percentile: matches PERCENTILE_CONT for every portfolio and p',
  (SELECT COUNT(*) = 15 AND SUM(ABS(expected - actual) > 1e-9) = 0  -- 3 portfolios x 5 p values
     FROM (SELECT DISTINCT portfolio, p,
                  PERCENTILE_CONT(p) WITHIN GROUP (ORDER BY growth)
                    OVER (PARTITION BY portfolio, p) AS expected
             FROM portfolio_returns
             CROSS JOIN (SELECT 0.1 AS p UNION SELECT 0.25 UNION SELECT 0.5
                         UNION SELECT 0.75 UNION SELECT 0.9) ps
            WHERE growth IS NOT NULL) e
     JOIN (SELECT portfolio, p, percentile(growth, p) AS actual
             FROM portfolio_returns
             CROSS JOIN (SELECT 0.1 AS p UNION SELECT 0.25 UNION SELECT 0.5
                         UNION SELECT 0.75 UNION SELECT 0.9) ps
            GROUP BY portfolio, p) a USING (portfolio, p)));

-- mode_value
CALL check_that('mode_value: most frequent',
  (SELECT mode_value(v) = 'b' FROM (SELECT 'a' AS v UNION ALL SELECT 'b' UNION ALL SELECT 'b') t));
CALL check_that('mode_value: tie -> smallest',
  (SELECT mode_value(v) = 'apple'
     FROM (SELECT 'pear' AS v UNION ALL SELECT 'apple' UNION ALL SELECT 'pear' UNION ALL SELECT 'apple') t));
CALL check_that('mode_value: NULLs ignored',
  (SELECT mode_value(v) = 'x'
     FROM (SELECT 'x' AS v UNION ALL SELECT NULL UNION ALL SELECT NULL) t));
CALL check_that('mode_value: empty group -> NULL',
  (SELECT mode_value(v) IS NULL FROM (SELECT 'x' AS v) t WHERE v = 'y'));
CALL check_that('mode_value: quotes, commas and brackets survive',
  (SELECT mode_value(v) = 'a,"b"]' FROM (SELECT 'a,"b"]' AS v UNION ALL SELECT 'c') t));
CALL check_that('mode_value: works on numbers',
  (SELECT mode_value(v) = '42' FROM (SELECT 42 AS v UNION ALL SELECT 42 UNION ALL SELECT 7) t));

-- results
SELECT name AS test, IF(pass, 'pass', 'FAIL') AS result FROM test_results ORDER BY id;
SELECT CONCAT(SUM(pass), ' / ', COUNT(*), ' passed') AS summary FROM test_results;

DROP PROCEDURE check_that;
