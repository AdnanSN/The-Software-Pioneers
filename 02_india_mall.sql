-- 02_india_mall.sql
-- Indian mall: MRP rules, stacked offers, dated GST slabs.
-- Needs 01_retail_aggregates.sql to be run first (uses retail_agg.compound_discount and gini_coefficient).
--
-- Rules modelled (see README for sources and what is simplified):
--  1. MRP is legally required on pre-packaged goods (garments, make-up) but not on loose goods
--     (belt, handbag, cap sold unpackaged). Loose goods are billed at a manually entered price.
--  2. MRP is TAX-INCLUSIVE. GST is therefore carved out of the billed price, not added on top.
--  3. Apparel GST has a price slab, and the slab test uses the value BEFORE tax:
--       until 21.09.2025: 5% up to 1000 per piece, 12% above
--       from  22.09.2025: 5% up to 2500 per piece, 18% above
--     The slab is judged on the price actually charged, after discounts, not on the MRP.
--  4. Offers stack multiplicatively (20% then 10% = 28% off) and the price never goes below cost.
--  5. Free testers are tracked as units but carry zero revenue and zero GST.

CREATE DATABASE IF NOT EXISTS mall_retail;
USE mall_retail;

DROP VIEW  IF EXISTS v_line_final;
DROP VIEW  IF EXISTS v_line_priced;
DROP VIEW  IF EXISTS v_line_offers;
DROP TABLE IF EXISTS line_offers;
DROP TABLE IF EXISTS sales_lines;
DROP TABLE IF EXISTS offers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS gst_rates;
DROP TABLE IF EXISTS categories;

CREATE TABLE categories (
  category_id  INT PRIMARY KEY AUTO_INCREMENT,
  name         VARCHAR(50) NOT NULL UNIQUE,
  mrp_required BOOLEAN NOT NULL            -- TRUE for pre-packaged goods
);

-- One row per category and validity period, so a rate change does not rewrite history.
-- threshold NULL = flat rate (rate_up_to applies to every price).
CREATE TABLE gst_rates (
  rate_id     INT PRIMARY KEY AUTO_INCREMENT,
  category_id INT NOT NULL,
  valid_from  DATE NOT NULL,
  valid_to    DATE NULL,                   -- NULL = still in force
  threshold   DECIMAL(10,2) NULL,          -- per piece, value before tax
  rate_up_to  DECIMAL(5,4) NOT NULL,       -- 0.0500 = 5%
  rate_above  DECIMAL(5,4) NULL,
  note        VARCHAR(200),
  FOREIGN KEY (category_id) REFERENCES categories(category_id),
  CHECK (threshold IS NULL OR rate_above IS NOT NULL),
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE TABLE products (
  product_id  INT PRIMARY KEY AUTO_INCREMENT,
  category_id INT NOT NULL,
  name        VARCHAR(100) NOT NULL,
  mrp         DECIMAL(10,2) NULL,          -- NULL for loose goods
  cost_price  DECIMAL(10,2) NOT NULL,
  FOREIGN KEY (category_id) REFERENCES categories(category_id),
  CHECK (cost_price > 0),
  CHECK (mrp IS NULL OR mrp >= cost_price)
);

CREATE TABLE offers (
  offer_id INT PRIMARY KEY AUTO_INCREMENT,
  name     VARCHAR(50) NOT NULL,
  pct      DECIMAL(5,2) NOT NULL,
  CHECK (pct BETWEEN 0 AND 100)
);

CREATE TABLE sales_lines (
  line_id    INT PRIMARY KEY AUTO_INCREMENT,
  product_id INT NOT NULL,
  sale_date  DATE NOT NULL,
  quantity   INT NOT NULL,
  list_price DECIMAL(10,2) NOT NULL,       -- price before offers: the MRP, or the entered price for loose goods
  is_sample  BOOLEAN NOT NULL DEFAULT FALSE,
  FOREIGN KEY (product_id) REFERENCES products(product_id),
  CHECK (quantity > 0)
);

-- Which offers were stacked on which bill line (many offers per line).
CREATE TABLE line_offers (
  line_id  INT NOT NULL,
  offer_id INT NOT NULL,
  PRIMARY KEY (line_id, offer_id),
  FOREIGN KEY (line_id)  REFERENCES sales_lines(line_id),
  FOREIGN KEY (offer_id) REFERENCES offers(offer_id)
);

INSERT INTO categories (name, mrp_required) VALUES
  ('Kids Wear', TRUE), ('Mens Wear', TRUE), ('Womens Wear', TRUE),
  ('Makeup', TRUE), ('Accessories (loose)', FALSE);

-- Apparel categories 1-3: old and new slab. Makeup and loose accessories: flat 18% (simplified).
INSERT INTO gst_rates (category_id, valid_from, valid_to, threshold, rate_up_to, rate_above, note)
SELECT c.category_id, '2017-07-01', '2025-09-21', 1000, 0.05, 0.12, 'apparel slab before GST reform'
  FROM categories c WHERE c.category_id IN (1, 2, 3)
UNION ALL
SELECT c.category_id, '2025-09-22', NULL, 2500, 0.05, 0.18, 'apparel slab after 56th GST Council'
  FROM categories c WHERE c.category_id IN (1, 2, 3);
INSERT INTO gst_rates (category_id, valid_from, valid_to, threshold, rate_up_to, rate_above, note) VALUES
  (4, '2017-07-01', NULL, NULL, 0.18, NULL, 'make-up (HSN 3304) - verify exact HSN rate'),
  (5, '2017-07-01', NULL, NULL, 0.18, NULL, 'simplified flat rate; real rate depends on the item HSN');

INSERT INTO products (category_id, name, mrp, cost_price) VALUES
  (1, 'Kids T-Shirt',            699.00,  320.00),   -- 1
  (1, 'Kids Jacket',            1499.00,  780.00),   -- 2
  (2, 'Mens Formal Shirt',      1799.00,  900.00),   -- 3
  (2, 'Mens Blazer',            3499.00, 1800.00),   -- 4
  (3, 'Womens Kurti',            899.00,  410.00),   -- 5
  (3, 'Womens Designer Dress',  2999.00, 1500.00),   -- 6
  (4, 'Lipstick Matte Red',      599.00,  180.00),   -- 7
  (4, 'Eyelash Extension Kit',   349.00,  110.00),   -- 8
  (5, 'Mens Leather Belt',        NULL,   180.00),   -- 9  loose, no MRP
  (5, 'Womens Handbag',           NULL,   900.00),   -- 10 loose, no MRP
  (5, 'Boys Cap',                 NULL,    60.00);   -- 11 loose, no MRP

INSERT INTO offers (name, pct) VALUES
  ('Festival sale', 20), ('Clearance', 10), ('Loyalty card', 5),
  ('Bundle deal', 15), ('Mega clearance', 40), ('Flash sale', 30);

INSERT INTO sales_lines (product_id, sale_date, quantity, list_price, is_sample) VALUES
  (3,  '2025-09-20', 1, 1799.00, FALSE),  -- 1  same shirt, day BEFORE the GST reform
  (3,  '2025-09-25', 1, 1799.00, FALSE),  -- 2  same shirt, days AFTER the reform
  (4,  '2026-09-21', 1, 3499.00, FALSE),  -- 3  blazer: offers push it under the 2500 slab
  (6,  '2026-09-21', 1, 2999.00, FALSE),  -- 4  dress: three stacked offers cross the slab
  (1,  '2026-09-22', 3,  699.00, FALSE),  -- 5  t-shirt: stack would sell below cost
  (2,  '2026-09-22', 1, 1499.00, FALSE),  -- 6  jacket
  (5,  '2026-09-22', 2,  899.00, FALSE),  -- 7  kurti with bundle deal
  (7,  '2026-09-23', 4,  599.00, FALSE),  -- 8  lipstick on flash sale
  (7,  '2026-09-23', 1,  599.00, TRUE),   -- 9  free lipstick tester
  (8,  '2026-09-23', 2,  349.00, FALSE),  -- 10 eyelash kit
  (9,  '2026-09-23', 5,  249.00, FALSE),  -- 11 loose belt, entered price
  (10, '2026-09-24', 1, 1199.00, FALSE),  -- 12 loose handbag with loyalty card
  (11, '2026-09-24', 3,   99.00, FALSE),  -- 13 loose cap
  (4,  '2026-09-24', 1, 3499.00, FALSE),  -- 14 blazer with no offers: stays in the 18% slab
  (6,  '2026-09-25', 2, 2999.00, FALSE);  -- 15 dress with no offers

INSERT INTO line_offers (line_id, offer_id) VALUES
  (3, 1), (3, 2),            -- blazer: festival + clearance
  (4, 1), (4, 2), (4, 3),    -- dress: festival + clearance + loyalty
  (5, 5), (5, 6), (5, 2),    -- t-shirt: mega clearance + flash + clearance
  (6, 1), (6, 2),            -- jacket
  (7, 4),                    -- kurti: bundle
  (8, 6),                    -- lipstick: flash
  (10, 1), (10, 2),          -- eyelash kit
  (12, 3);                   -- handbag: loyalty

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- Offers per bill line: the additive total is the common mistake, the compound one is correct.
CREATE VIEW v_line_offers AS
SELECT sl.line_id,
       COUNT(o.offer_id)                                  AS offers_applied,
       COALESCE(SUM(o.pct), 0)                            AS additive_discount_pct,
       COALESCE(retail_agg.compound_discount(o.pct), 0)   AS compound_discount_pct
  FROM sales_lines sl
  LEFT JOIN line_offers lo ON lo.line_id = sl.line_id
  LEFT JOIN offers o       ON o.offer_id = lo.offer_id
 GROUP BY sl.line_id;

-- Price after offers, floored at cost, plus the GST rule in force on the sale date.
CREATE VIEW v_line_priced AS
SELECT sl.line_id, sl.sale_date, sl.quantity, sl.is_sample,
       p.product_id, p.name AS product_name,
       c.category_id, c.name AS category_name,
       sl.list_price, p.cost_price,
       lo.offers_applied, lo.additive_discount_pct, lo.compound_discount_pct,
       ROUND(sl.list_price * (1 - lo.compound_discount_pct / 100), 2) AS price_after_offers,
       IF(sl.is_sample, 0,
          ROUND(GREATEST(sl.list_price * (1 - lo.compound_discount_pct / 100), p.cost_price), 2)
       ) AS billed_unit_price,
       r.threshold, r.rate_up_to, r.rate_above
  FROM sales_lines sl
  JOIN products p        ON p.product_id  = sl.product_id
  JOIN categories c      ON c.category_id = p.category_id
  JOIN v_line_offers lo  ON lo.line_id    = sl.line_id
  JOIN gst_rates r       ON r.category_id = c.category_id
                        AND sl.sale_date >= r.valid_from
                        AND (r.valid_to IS NULL OR sl.sale_date <= r.valid_to);

-- GST carved out of the tax-inclusive price.
-- Slab test: the pre-tax value at the LOWER rate must be within the threshold.
CREATE VIEW v_line_final AS
SELECT q.*,
       (q.price_after_offers < q.cost_price AND NOT q.is_sample)     AS floor_applied,
       q.g_rate                                                      AS gst_rate,
       ROUND(q.quantity * q.billed_unit_price, 2)                    AS line_total,
       ROUND(q.quantity * q.billed_unit_price * q.g_rate / (1 + q.g_rate), 2) AS gst_amount,
       ROUND(q.quantity * q.billed_unit_price / (1 + q.g_rate), 2)   AS net_revenue,
       -- what a system that decides the slab from the LIST price would have used
       q.g_rate_on_list                                              AS gst_rate_if_taxed_on_list
  FROM (
    SELECT p.*,
           CASE WHEN p.threshold IS NULL THEN p.rate_up_to
                WHEN p.billed_unit_price / (1 + p.rate_up_to) <= p.threshold THEN p.rate_up_to
                ELSE p.rate_above END AS g_rate,
           CASE WHEN p.threshold IS NULL THEN p.rate_up_to
                WHEN p.list_price / (1 + p.rate_up_to) <= p.threshold THEN p.rate_up_to
                ELSE p.rate_above END AS g_rate_on_list
      FROM v_line_priced p
  ) q;

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- 1. Every bill line: stacked offers, price floor, GST, totals.
SELECT line_id, product_name, sale_date, quantity, list_price,
       additive_discount_pct AS if_added, ROUND(compound_discount_pct, 2) AS compound_pct,
       billed_unit_price, floor_applied, gst_rate, line_total, gst_amount, net_revenue
  FROM v_line_final
 ORDER BY line_id;

-- 2. FINDING A: offers move items across the GST slab. Deciding the slab from the MRP
--    instead of the billed price over-states the tax on these lines.
SELECT line_id, product_name, list_price, billed_unit_price,
       gst_rate_if_taxed_on_list AS rate_from_mrp, gst_rate AS rate_correct,
       ROUND(quantity * billed_unit_price * gst_rate_if_taxed_on_list / (1 + gst_rate_if_taxed_on_list), 2) AS gst_if_wrong,
       gst_amount AS gst_correct,
       ROUND(quantity * billed_unit_price * gst_rate_if_taxed_on_list / (1 + gst_rate_if_taxed_on_list), 2) - gst_amount AS over_stated
  FROM v_line_final
 WHERE threshold IS NOT NULL
   AND gst_rate_if_taxed_on_list <> gst_rate;

-- 3. FINDING B: the same shirt at the same MRP before and after 22.09.2025.
SELECT line_id, product_name, sale_date, list_price, gst_rate, gst_amount, net_revenue
  FROM v_line_final
 WHERE product_id = 3
 ORDER BY sale_date;

-- 4. FINDING C: adding stacked percentages overstates the discount, and some stacks
--    would sell below cost.
SELECT line_id, product_name, offers_applied,
       additive_discount_pct AS added_pct,
       ROUND(compound_discount_pct, 2) AS compound_pct,
       ROUND(additive_discount_pct - compound_discount_pct, 2) AS overstated_by,
       price_after_offers, cost_price, billed_unit_price,
       IF(price_after_offers < cost_price, 'FLOOR APPLIED', '') AS note
  FROM v_line_final
 WHERE offers_applied >= 2 AND NOT is_sample
 ORDER BY line_id;

-- 5. Category summary. Free testers count as units out and as cost, but not as revenue.
SELECT category_name,
       SUM(quantity)                                        AS units_out,
       SUM(IF(is_sample, 0, quantity))                      AS units_sold,
       SUM(net_revenue)                                     AS net_revenue,
       SUM(gst_amount)                                      AS gst_collected,
       ROUND(SUM(IF(is_sample, quantity * cost_price, 0)), 2) AS tester_cost,
       ROUND(SUM(net_revenue) - SUM(quantity * cost_price), 2) AS margin_after_testers
  FROM v_line_final
 GROUP BY category_name
 ORDER BY net_revenue DESC;

-- 6. How concentrated is revenue across products? (0 = even, near 1 = one product dominates)
SELECT COUNT(*)                                         AS products_sold,
       ROUND(retail_agg.gini_coefficient(rev), 4)       AS revenue_gini,
       ROUND(MAX(rev) / SUM(rev) * 100, 1)              AS top_product_share_pct
  FROM (SELECT product_id, SUM(net_revenue) AS rev
          FROM v_line_final GROUP BY product_id) t;

-- 7. Data-quality checks (each query should return no rows).
--    7a. packaged categories must have an MRP, loose categories must not
SELECT p.product_id, p.name, c.mrp_required, p.mrp
  FROM products p JOIN categories c USING (category_id)
 WHERE (c.mrp_required AND p.mrp IS NULL) OR (NOT c.mrp_required AND p.mrp IS NOT NULL);
--    7b. a category must not have two GST rules valid on the same day
SELECT a.category_id, a.rate_id AS rule_a, b.rate_id AS rule_b
  FROM gst_rates a JOIN gst_rates b
    ON a.category_id = b.category_id AND a.rate_id < b.rate_id
   AND a.valid_from <= COALESCE(b.valid_to, '9999-12-31')
   AND b.valid_from <= COALESCE(a.valid_to, '9999-12-31');
--    7c. a bill line sold at an MRP different from the product MRP
SELECT sl.line_id, p.name, sl.list_price, p.mrp
  FROM sales_lines sl JOIN products p USING (product_id)
 WHERE p.mrp IS NOT NULL AND sl.list_price <> p.mrp;

-- 8. Self-checks: every row must show pass = 1 (expected values worked out by hand).
SELECT 'blazer: 20% then 10% = 28% off' AS test,
       ABS(compound_discount_pct - 28) < 1e-9 AS pass
  FROM v_line_final WHERE line_id = 3
UNION ALL
SELECT 'blazer: offers move it from the 18% slab into 5%',
       gst_rate = 0.05 AND gst_rate_if_taxed_on_list = 0.18
  FROM v_line_final WHERE line_id = 3
UNION ALL
SELECT 'dress: three offers = 31.6%, billed 2051.32',
       ABS(compound_discount_pct - 31.6) < 1e-9 AND billed_unit_price = 2051.32
  FROM v_line_final WHERE line_id = 4
UNION ALL
SELECT 't-shirt: stack would go below cost, so the floor applies',
       floor_applied = 1 AND billed_unit_price = cost_price
  FROM v_line_final WHERE line_id = 5
UNION ALL
SELECT 'same shirt: 12% before 22.09.2025, 5% after',
       (SELECT gst_rate FROM v_line_final WHERE line_id = 1) = 0.12
   AND (SELECT gst_rate FROM v_line_final WHERE line_id = 2) = 0.05
UNION ALL
SELECT 'free tester: zero revenue and zero GST',
       line_total = 0 AND gst_amount = 0 AND net_revenue = 0
  FROM v_line_final WHERE line_id = 9
UNION ALL
SELECT 'net + GST = total on every line (within 1 paisa)',
       MAX(ABS(net_revenue + gst_amount - line_total)) <= 0.011
  FROM v_line_final
UNION ALL
SELECT 'tax over-stated by the MRP-based rule = 479.56 on the two crossing lines',
       ABS(SUM(ROUND(quantity * billed_unit_price * gst_rate_if_taxed_on_list / (1 + gst_rate_if_taxed_on_list), 2) - gst_amount) - 479.56) < 0.005
  FROM v_line_final WHERE threshold IS NOT NULL AND gst_rate_if_taxed_on_list <> gst_rate;test