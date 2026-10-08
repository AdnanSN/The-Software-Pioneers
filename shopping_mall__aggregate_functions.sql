-- shopping_mall__aggregate_functions.sql
-- First version of the Indian mall example: discounts stacked in three columns, one GST slab
-- (the pre-22.09.2025 one), and the welford_stddev aggregate. 02_india_mall.sql is the reworked
-- version. This file is standalone and uses its own database so the two never share tables.

CREATE DATABASE IF NOT EXISTS mall_retail_v1;
USE mall_retail_v1;

DROP VIEW IF EXISTS sales_final;
DROP VIEW IF EXISTS sales_taxed;
DROP VIEW IF EXISTS sales_priced;
DROP TABLE IF EXISTS sales_lines;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS categories;

CREATE TABLE categories (
    category_id   INT PRIMARY KEY AUTO_INCREMENT,
    name          VARCHAR(50) NOT NULL,
    mrp_required  BOOLEAN NOT NULL,          -- legal packaging rule
    gst_low_rate  DECIMAL(5,2),              -- e.g. 0.05 for apparel < 1000
    gst_high_rate DECIMAL(5,2),              -- e.g. 0.12 for apparel >= 1000
    gst_threshold DECIMAL(10,2),             -- price point where rate changes; NULL = flat rate
    flat_gst_rate DECIMAL(5,2)               -- used when there's no threshold (e.g. makeup)
);

INSERT INTO categories (name, mrp_required, gst_low_rate, gst_high_rate, gst_threshold, flat_gst_rate) VALUES
('Kids Wear',           TRUE,  0.05, 0.12, 1000, NULL),
('Mens Wear',           TRUE,  0.05, 0.12, 1000, NULL),
('Womens Wear',         TRUE,  0.05, 0.12, 1000, NULL),
('Makeup',              TRUE,  NULL, NULL, NULL, 0.18),
('Accessories (loose)', FALSE, NULL, NULL, NULL, 0.18);

CREATE TABLE products (
    product_id   INT PRIMARY KEY AUTO_INCREMENT,
    category_id  INT NOT NULL,
    name         VARCHAR(100) NOT NULL,
    mrp          DECIMAL(10,2),              -- NULL where not legally required
    cost_price   DECIMAL(10,2) NOT NULL,
    FOREIGN KEY (category_id) REFERENCES categories(category_id)
);

INSERT INTO products (category_id, name, mrp, cost_price) VALUES
(1, 'Kids T-Shirt',            699.00, 320.00),
(1, 'Kids Jacket',             1499.00, 780.00),
(2, 'Mens Formal Shirt',       1199.00, 650.00),
(2, 'Mens Belt (loose)',       NULL,    180.00),    -- no MRP: unpackaged accessory
(3, 'Womens Kurti',            899.00, 410.00),
(3, 'Womens Handbag (loose)',  NULL,    900.00),
(4, 'Lipstick - Matte Red',    599.00, 180.00),
(4, 'Eyelash Extension Kit',   349.00, 110.00),
(5, 'Boys Cap (loose)',        NULL,    60.00);

CREATE TABLE sales_lines (
    line_id        INT PRIMARY KEY AUTO_INCREMENT,
    product_id     INT NOT NULL,
    sale_date      DATE NOT NULL,
    quantity       INT NOT NULL,
    unit_mrp_used  DECIMAL(10,2),       -- price actually billed on, before discount (loose items: entered manually)
    discount_pct_1 DECIMAL(5,2) DEFAULT 0,  -- e.g. festival sale
    discount_pct_2 DECIMAL(5,2) DEFAULT 0,  -- e.g. clearance, stacked on top
    discount_pct_3 DECIMAL(5,2) DEFAULT 0,  -- e.g. loyalty, stacked on top
    is_sample      BOOLEAN DEFAULT FALSE,   -- free tester, zero revenue
    FOREIGN KEY (product_id) REFERENCES products(product_id)
);

INSERT INTO sales_lines (product_id, sale_date, quantity, unit_mrp_used, discount_pct_1, discount_pct_2, discount_pct_3, is_sample) VALUES
(1, '2026-09-20', 3, 699.00, 10, 0, 0, FALSE),
(2, '2026-09-20', 1, 1499.00, 20, 10, 0, FALSE),   -- stacked discount, crosses GST threshold
(3, '2026-09-21', 2, 1199.00, 20, 0, 5, FALSE),    -- stacked discount, crosses GST threshold
(4, '2026-09-21', 5, 180.00, 0, 0, 0, FALSE),
(5, '2026-09-22', 1, 899.00, 15, 0, 0, FALSE),
(6, '2026-09-22', 1, 950.00, 0, 0, 0, FALSE),
(7, '2026-09-23', 4, 599.00, 30, 0, 0, FALSE),
(7, '2026-09-23', 1, 599.00, 0, 0, 0, TRUE),       -- free tester given away
(8, '2026-09-23', 2, 349.00, 10, 10, 0, FALSE),
(9, '2026-09-24', 3, 70.00, 0, 0, 0, FALSE);
-- Effective selling price after stacked multiplicative discounts, floored at cost
CREATE OR REPLACE VIEW sales_priced AS
SELECT
    sl.line_id,
    sl.product_id,
    p.name AS product_name,
    c.category_id,
    c.name AS category_name,
    sl.sale_date,
    sl.quantity,
    sl.unit_mrp_used,
    p.cost_price,
    sl.is_sample,
    -- multiplicative stacking, not additive
    ROUND(
        GREATEST(
            sl.unit_mrp_used
              * (1 - sl.discount_pct_1/100)
              * (1 - sl.discount_pct_2/100)
              * (1 - sl.discount_pct_3/100),
            p.cost_price            -- floor rule: never sell below cost
        ), 2
    ) AS effective_unit_price,
    c.gst_threshold,
    c.gst_low_rate,
    c.gst_high_rate,
    c.flat_gst_rate
FROM sales_lines sl
JOIN products p ON p.product_id = sl.product_id
JOIN categories c ON c.category_id = p.category_id;

-- Correct GST: based on POST-discount price, not MRP (the key complication)
CREATE OR REPLACE VIEW sales_taxed AS
SELECT
    sp.*,
    CASE
        WHEN sp.is_sample THEN 0  -- samples are free, no tax on zero revenue
        WHEN sp.flat_gst_rate IS NOT NULL THEN sp.flat_gst_rate
        WHEN sp.effective_unit_price >= sp.gst_threshold THEN sp.gst_high_rate
        ELSE sp.gst_low_rate
    END AS applied_gst_rate,
    IF(sp.is_sample, 0, sp.quantity * sp.effective_unit_price) AS taxable_revenue
FROM sales_priced sp;

CREATE OR REPLACE VIEW sales_final AS
SELECT
    *,
    ROUND(taxable_revenue * applied_gst_rate, 2) AS gst_amount,
    ROUND(taxable_revenue * (1 + applied_gst_rate), 2) AS total_billed
FROM sales_taxed;

-- The finding: show where discounting moved an item across the GST slab
SELECT product_name, unit_mrp_used, effective_unit_price,
       IF(unit_mrp_used >= gst_threshold, gst_high_rate, gst_low_rate) AS rate_if_taxed_on_mrp,
       applied_gst_rate AS rate_actually_applied,
       (unit_mrp_used >= gst_threshold) <> (effective_unit_price >= COALESCE(gst_threshold, 999999)) AS slab_crossed
FROM sales_final
WHERE gst_threshold IS NOT NULL;

-- welford_stddev(x): sample standard deviation in one pass (Welford's update), NULL below 2 values.
-- It gives the same answer as the built-in STDDEV_SAMP(), shown side by side below, so in real
-- code use the built-in: this one is here to show how a running-state aggregate is written.
DROP FUNCTION IF EXISTS welford_stddev;
DELIMITER //
CREATE AGGREGATE FUNCTION welford_stddev(x DOUBLE) RETURNS DOUBLE DETERMINISTIC
BEGIN
  DECLARE n BIGINT DEFAULT 0;
  DECLARE mean DOUBLE DEFAULT 0;
  DECLARE m2 DOUBLE DEFAULT 0;
  DECLARE delta DOUBLE;
  DECLARE delta2 DOUBLE;
  DECLARE CONTINUE HANDLER FOR NOT FOUND
    RETURN IF(n < 2, NULL, SQRT(m2 / (n - 1)));
  LOOP
    FETCH GROUP NEXT ROW;
    IF x IS NOT NULL THEN
      SET n = n + 1;
      SET delta = x - mean;
      SET mean = mean + delta / n;
      SET delta2 = x - mean;
      SET m2 = m2 + (delta * delta2);
    END IF;
  END LOOP;
END //
DELIMITER ;

-- Discount consistency per category: high stddev = erratic/uncontrolled markdowns
SELECT category_name,
       ROUND(AVG(effective_discount_pct), 2) AS avg_discount_pct,
       ROUND(welford_stddev(effective_discount_pct), 2) AS discount_stddev,
       ROUND(STDDEV_SAMP(effective_discount_pct), 2) AS builtin_stddev_samp
FROM (
    SELECT category_name,
           ROUND(100 * (1 - effective_unit_price / unit_mrp_used), 2) AS effective_discount_pct
    FROM sales_final
    WHERE is_sample = FALSE
) t
GROUP BY category_name;
