-- starter_aggregate_functions.sql
-- Tested on MariaDB 12.3.3, database: capstone_test, table: sales

USE capstone_test;

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

-- 4. Use the custom function like any built-in aggregate
SELECT product, agg_sum_squares(amount) AS sum_of_squares
FROM sales
GROUP BY product;