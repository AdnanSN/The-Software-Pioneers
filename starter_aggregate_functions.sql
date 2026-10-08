-- starter_aggregate_functions.sql
-- Tested on MariaDB 12.3.3, database: capstone_test, table: sales

CREATE DATABASE IF NOT EXISTS capstone_test;
USE capstone_test;

-- 0. Sample data. Only filled when the table is new or empty, so an existing sales table is kept.
--    One amount is NULL to show how agg_sum_squares and SUM() differ on missing values.
CREATE TABLE IF NOT EXISTS sales (
  id      INT PRIMARY KEY AUTO_INCREMENT,
  product VARCHAR(50) NOT NULL,
  amount  DECIMAL(10,2) NULL
);

INSERT INTO sales (product, amount)
SELECT product, amount
FROM (SELECT 'pen' AS product, 2.50 AS amount UNION ALL SELECT 'pen', 3.00
      UNION ALL SELECT 'pen', 2.50       UNION ALL SELECT 'notebook', 6.00
      UNION ALL SELECT 'notebook', 7.50  UNION ALL SELECT 'notebook', NULL
      UNION ALL SELECT 'backpack', 35.00 UNION ALL SELECT 'backpack', 29.99) AS sample_rows
WHERE NOT EXISTS (SELECT 1 FROM sales);

-- 1. Built-in aggregates with filtering on groups
SELECT product,
       COUNT(*)    AS num_sales,
       SUM(amount) AS total_sales,
       AVG(amount) AS avg_sale,
       MAX(amount) AS biggest_sale
FROM sales
GROUP BY product
HAVING SUM(amount) > 10;

-- 2. Window functions: running total and rank inside each product
SELECT id, product, amount,
       SUM(amount) OVER (PARTITION BY product ORDER BY id) AS running_total,
       RANK()      OVER (PARTITION BY product ORDER BY amount DESC) AS rank_in_product
FROM sales;

-- 3. Custom aggregate function: sum of squares
DROP FUNCTION IF EXISTS agg_sum_squares;

DELIMITER //
CREATE AGGREGATE FUNCTION agg_sum_squares(x DECIMAL(10,2)) RETURNS DECIMAL(20,2)
BEGIN
  DECLARE total DECIMAL(20,2) DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND RETURN total;
  LOOP
    FETCH GROUP NEXT ROW;
    SET total = total + (x * x);
  END LOOP;
END //
DELIMITER ;

-- 4. Use the custom function like any built-in aggregate, next to the built-in way to write it.
--    They agree (agg_sum_squares returns DECIMAL(20,2), so the built-in is rounded to match)
--    except for 'notebook': its NULL amount makes agg_sum_squares NULL, while SUM() skips it.
SELECT product,
       agg_sum_squares(amount)        AS sum_of_squares,
       ROUND(SUM(amount * amount), 2) AS builtin_sum_of_squares
FROM sales
GROUP BY product;
