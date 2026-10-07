-- 03_germany_mall.sql
-- German mall: UVP instead of MRP, flat 19% VAT, mandatory unit price (Grundpreis),
-- and the 30-day reference price rule for advertised discounts.
-- Needs 01_retail_aggregates.sql to be run first (uses retail_agg.trend_slope, harmonic_mean, gini_coefficient).
--
-- Rules modelled (see README for sources and what is simplified):
--  1. UVP (unverbindliche Preisempfehlung) is only a recommendation. A shop may sell above or
--     below it. There is no legal price ceiling like the Indian MRP.
--  2. Consumer prices are gross (include VAT). VAT is 19% for clothing and cosmetics, flat:
--     there is no price slab, so a discount can never move an item into another tax rate.
--  3. Goods sold by weight or volume must show a unit price (Grundpreis), here per 100 g / 100 ml.
--  4. When a shop advertises "was X, now Y", X must be the lowest price charged in the 30 days
--     before the reduction (EU Omnibus rules, implemented in PAngV section 11). An inflated
--     "was" price is called a Mondpreis ("moon price").
--  5. Free testers are tracked as units and cost, but carry no revenue and no VAT.

SET NAMES utf8mb4;
CREATE DATABASE IF NOT EXISTS mall_retail_de CHARACTER SET utf8mb4;
USE mall_retail_de;

DROP VIEW  IF EXISTS v_de_price_claims;
DROP VIEW  IF EXISTS v_de_lines;
DROP TABLE IF EXISTS price_history;
DROP TABLE IF EXISTS sales_lines_de;
DROP TABLE IF EXISTS products_de;
DROP TABLE IF EXISTS categories_de;

CREATE TABLE categories_de (
  category_id         INT PRIMARY KEY AUTO_INCREMENT,
  name                VARCHAR(50) NOT NULL UNIQUE,
  vat_rate            DECIMAL(5,4) NOT NULL DEFAULT 0.1900,   -- flat 19%
  requires_grundpreis BOOLEAN NOT NULL DEFAULT FALSE          -- unit price must be shown
);

CREATE TABLE products_de (
  product_id  INT PRIMARY KEY AUTO_INCREMENT,
  category_id INT NOT NULL,
  name        VARCHAR(100) NOT NULL,
  uvp         DECIMAL(10,2) NULL,         -- recommendation only; NULL = none given
  cost_price  DECIMAL(10,2) NOT NULL,
  net_content DECIMAL(10,2) NULL,         -- declared content, e.g. 3.5 (g)
  unit_type   ENUM('g','ml') NULL,
  FOREIGN KEY (category_id) REFERENCES categories_de(category_id),
  CHECK (cost_price > 0),
  CHECK ((net_content IS NULL) = (unit_type IS NULL))
);

-- One gross price per product and day. Needed to answer "what was the lowest price in the last 30 days?"
CREATE TABLE price_history (
  product_id    INT NOT NULL,
  price_date    DATE NOT NULL,
  price_charged DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (product_id, price_date),
  FOREIGN KEY (product_id) REFERENCES products_de(product_id)
);

CREATE TABLE sales_lines_de (
  line_id       INT PRIMARY KEY AUTO_INCREMENT,
  product_id    INT NOT NULL,
  sale_date     DATE NOT NULL,
  quantity      INT NOT NULL,
  price_charged DECIMAL(10,2) NOT NULL,   -- gross price per unit actually charged
  was_price     DECIMAL(10,2) NULL,       -- crossed-out reference price shown on the tag, if any
  is_sample     BOOLEAN NOT NULL DEFAULT FALSE,
  FOREIGN KEY (product_id) REFERENCES products_de(product_id),
  CHECK (quantity > 0)
);

INSERT INTO categories_de (name, vat_rate, requires_grundpreis) VALUES
  ('Kinderbekleidung',        0.19, FALSE),   -- kids wear
  ('Herrenbekleidung',        0.19, FALSE),   -- men's wear
  ('Damenbekleidung',         0.19, FALSE),   -- women's wear
  ('Make-up',                 0.19, TRUE),    -- sold by weight/volume -> Grundpreis
  ('Accessoires (lose Ware)', 0.19, FALSE);   -- loose accessories

INSERT INTO products_de (category_id, name, uvp, cost_price, net_content, unit_type) VALUES
  (1, 'Kinder T-Shirt',            24.99, 11.00, NULL, NULL),   -- 1
  (1, 'Kinder Jacke',              54.99, 28.00, NULL, NULL),   -- 2
  (2, 'Herren Hemd',               49.99, 22.00, NULL, NULL),   -- 3
  (5, 'Herren Gürtel (lose)',       NULL,  7.50, NULL, NULL),   -- 4
  (3, 'Damen Kleid',               69.99, 31.00, NULL, NULL),   -- 5
  (5, 'Damen Handtasche (lose)',    NULL, 35.00, NULL, NULL),   -- 6
  (4, 'Lippenstift Matt Rot',      18.99,  6.50,  3.5, 'g'),    -- 7
  (4, 'Lippenstift Nude',          16.99,  6.00,  3.5, 'g'),    -- 8
  (4, 'Lippenbalsam',               5.49,  1.80,  4.8, 'g'),    -- 9
  (4, 'Wimpernverlängerung-Set',   14.99,  4.80, 12.0, 'ml'),   -- 10
  (4, 'Foundation',                24.99,  8.50, 30.0, 'ml'),   -- 11
  (4, 'Mascara',                   12.99,  4.00, 10.0, 'ml'),   -- 12
  (5, 'Jungen Kappe (lose)',        NULL,  2.20, NULL, NULL);   -- 13

-- Daily price history 15.07.2026 - 26.09.2026 for three products:
--   3 Herren Hemd : genuine markdowns (49.99 -> 44.99 -> 39.99), steady since 25.08.
--   5 Damen Kleid : 59.99, then raised to 79.99 on 08.09. (above its UVP, which is legal)
--   7 Lippenstift : constant 18.99
INSERT INTO price_history (product_id, price_date, price_charged)
WITH RECURSIVE days (d) AS (
  SELECT DATE '2026-07-15'
  UNION ALL
  SELECT d + INTERVAL 1 DAY FROM days WHERE d < '2026-09-26'
)
SELECT p.product_id, days.d,
       CASE p.product_id
         WHEN 3 THEN CASE WHEN days.d < '2026-08-01' THEN 49.99
                          WHEN days.d < '2026-08-25' THEN 44.99
                          ELSE 39.99 END
         WHEN 5 THEN CASE WHEN days.d < '2026-09-08' THEN 59.99 ELSE 79.99 END
         ELSE 18.99
       END
  FROM days
  JOIN (SELECT 3 AS product_id UNION ALL SELECT 5 UNION ALL SELECT 7) p;

INSERT INTO sales_lines_de (product_id, sale_date, quantity, price_charged, was_price, is_sample) VALUES
  (1,  '2026-09-20', 3, 22.49, NULL,  FALSE),  -- 1  t-shirt, slightly under UVP
  (3,  '2026-09-27', 2, 34.99, 39.99, FALSE),  -- 2  shirt: honest "was 39.99, now 34.99"
  (5,  '2026-09-27', 1, 49.99, 79.99, FALSE),  -- 3  dress: "was 79.99" is inflated
  (7,  '2026-09-23', 4, 18.99, NULL,  FALSE),  -- 4  lipstick
  (7,  '2026-09-23', 1, 18.99, NULL,  TRUE),   -- 5  free tester
  (8,  '2026-09-23', 2, 16.99, NULL,  FALSE),  -- 6  lipstick nude
  (9,  '2026-09-23', 6,  5.49, NULL,  FALSE),  -- 7  lip balm
  (10, '2026-09-23', 2, 12.99, NULL,  FALSE),  -- 8  lash set, under UVP
  (11, '2026-09-24', 1, 24.99, NULL,  FALSE),  -- 9  foundation
  (12, '2026-09-24', 3, 12.99, NULL,  FALSE),  -- 10 mascara
  (13, '2026-09-24', 3,  4.99, NULL,  FALSE),  -- 11 loose cap
  (4,  '2026-09-24', 2, 14.99, NULL,  FALSE),  -- 12 loose belt, no UVP exists
  (6,  '2026-09-25', 1, 39.99, NULL,  FALSE),  -- 13 loose handbag
  (5,  '2026-09-15', 1, 79.99, NULL,  FALSE);  -- 14 dress sold ABOVE its UVP of 69.99: legal in Germany

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- VAT is carved out of the gross price. net is rounded first so net + VAT = gross exactly.
CREATE VIEW v_de_lines AS
SELECT sl.line_id, sl.sale_date, sl.quantity, sl.is_sample,
       p.product_id, p.name AS product_name, c.name AS category_name,
       p.uvp, p.cost_price, p.net_content, p.unit_type,
       sl.price_charged, sl.was_price, c.vat_rate,
       IF(sl.is_sample, 0, ROUND(sl.quantity * sl.price_charged, 2))                  AS gross_total,
       IF(sl.is_sample, 0, ROUND(sl.quantity * sl.price_charged / (1 + c.vat_rate), 2)) AS net_revenue,
       IF(sl.is_sample, 0, ROUND(sl.quantity * sl.price_charged, 2)
                         - ROUND(sl.quantity * sl.price_charged / (1 + c.vat_rate), 2)) AS vat_amount,
       IF(c.requires_grundpreis, ROUND(sl.price_charged / p.net_content * 100, 2), NULL) AS grundpreis_per_100,
       IF(p.uvp IS NULL, NULL, ROUND((sl.price_charged / p.uvp - 1) * 100, 1))          AS vs_uvp_pct
  FROM sales_lines_de sl
  JOIN products_de p    ON p.product_id  = sl.product_id
  JOIN categories_de c  ON c.category_id = p.category_id;

-- Every line that advertises a "was" price, checked against the 30 days before the sale.
-- (Simplified: the sale date stands in for the date the reduction started.)
CREATE VIEW v_de_price_claims AS
SELECT x.*,
       (x.was_price > x.lowest_30d)                           AS inflated,
       ROUND((1 - x.price_charged / x.was_price) * 100, 1)    AS claimed_discount_pct,
       ROUND((1 - x.price_charged / x.lowest_30d) * 100, 1)   AS true_discount_pct
  FROM (
    SELECT sl.line_id, p.product_id, p.name AS product_name, sl.sale_date,
           sl.price_charged, sl.was_price,
           (SELECT MIN(ph.price_charged) FROM price_history ph
             WHERE ph.product_id = sl.product_id
               AND ph.price_date >= sl.sale_date - INTERVAL 30 DAY
               AND ph.price_date <  sl.sale_date)              AS lowest_30d,
           -- price trend in EUR per day over the same 30 days (custom aggregate)
           (SELECT retail_agg.trend_slope(TO_DAYS(ph.price_date), ph.price_charged)
              FROM price_history ph
             WHERE ph.product_id = sl.product_id
               AND ph.price_date >= sl.sale_date - INTERVAL 30 DAY
               AND ph.price_date <  sl.sale_date)              AS eur_per_day_30d
      FROM sales_lines_de sl
      JOIN products_de p ON p.product_id = sl.product_id
     WHERE sl.was_price IS NOT NULL
  ) x;

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- 1. Every line: VAT carved out of the gross price, unit price (Grundpreis), position vs UVP.
SELECT line_id, product_name, sale_date, quantity, price_charged, vs_uvp_pct,
       gross_total, net_revenue, vat_amount, grundpreis_per_100, unit_type
  FROM v_de_lines
 ORDER BY line_id;

-- 2. FINDING A: advertised discounts against the legal reference price.
SELECT line_id, product_name, sale_date, price_charged,
       was_price AS advertised_was, lowest_30d AS legal_reference,
       claimed_discount_pct, true_discount_pct,
       eur_per_day_30d,
       IF(inflated, 'INFLATED - Mondpreis risk', 'ok') AS verdict
  FROM v_de_price_claims;

-- 3. FINDING B: how far apart are the arithmetic and the harmonic average unit price?
--    Harmonic = the unit price you really pay per 100 g / 100 ml if you spend the same
--    money on every product.
SELECT unit_type,
       COUNT(*)                                       AS products,
       ROUND(AVG(gp), 2)                              AS arithmetic_avg_per_100,
       ROUND(retail_agg.harmonic_mean(gp), 2)         AS harmonic_avg_per_100
  FROM (SELECT unit_type, uvp / net_content * 100 AS gp
          FROM products_de WHERE net_content IS NOT NULL AND uvp IS NOT NULL) t
 GROUP BY unit_type;

-- 4. FINDING C: price direction before each sale. A positive slope right before a
--    "reduction" is the fingerprint of a price raised to fake a discount.
SELECT p.name AS product_name,
       MIN(ph.price_charged) AS low, MAX(ph.price_charged) AS high,
       ROUND(retail_agg.trend_slope(TO_DAYS(ph.price_date), ph.price_charged), 4) AS eur_per_day
  FROM price_history ph JOIN products_de p USING (product_id)
 WHERE ph.price_date >= '2026-08-28'
 GROUP BY p.product_id, p.name;

-- 5. Lines sold above UVP (legal here; it would be illegal above an Indian MRP).
SELECT line_id, product_name, uvp, price_charged, vs_uvp_pct
  FROM v_de_lines
 WHERE uvp IS NOT NULL AND price_charged > uvp;

-- 6. Category summary. Testers count as cost but not as revenue.
SELECT category_name,
       SUM(quantity)                                           AS units_out,
       SUM(net_revenue)                                        AS net_revenue,
       SUM(vat_amount)                                         AS vat_collected,
       ROUND(SUM(IF(is_sample, quantity * cost_price, 0)), 2)  AS tester_cost,
       ROUND(SUM(net_revenue) - SUM(quantity * cost_price), 2) AS margin_after_testers
  FROM v_de_lines
 GROUP BY category_name
 ORDER BY net_revenue DESC;

-- 7. Revenue concentration across products.
SELECT COUNT(*)                                    AS products_sold,
       ROUND(retail_agg.gini_coefficient(rev), 4)  AS revenue_gini,
       ROUND(MAX(rev) / SUM(rev) * 100, 1)         AS top_product_share_pct
  FROM (SELECT product_id, SUM(net_revenue) AS rev
          FROM v_de_lines GROUP BY product_id) t;

-- 8. Self-checks: every row must show pass = 1 (expected values worked out by hand).
SELECT 'lipstick 4 x 18.99 gross: net 63.83 + VAT 12.13' AS test,
       net_revenue = 63.83 AND vat_amount = 12.13 AS pass
  FROM v_de_lines WHERE line_id = 4
UNION ALL
SELECT 'net + VAT = gross on every line',
       MAX(ABS(net_revenue + vat_amount - gross_total)) < 0.001
  FROM v_de_lines
UNION ALL
SELECT 'Grundpreis of lipstick at 18.99 for 3.5 g = 542.57 per 100 g',
       grundpreis_per_100 = 542.57
  FROM v_de_lines WHERE line_id = 4
UNION ALL
SELECT 'free tester: no revenue, no VAT',
       gross_total = 0 AND net_revenue = 0 AND vat_amount = 0
  FROM v_de_lines WHERE line_id = 5
UNION ALL
SELECT 'shirt "was 39.99" matches the 30-day low: not inflated',
       lowest_30d = 39.99 AND inflated = 0
  FROM v_de_price_claims WHERE line_id = 2
UNION ALL
SELECT 'dress "was 79.99" vs 30-day low 59.99: inflated, true discount 16.7%',
       lowest_30d = 59.99 AND inflated = 1 AND true_discount_pct = 16.7
  FROM v_de_price_claims WHERE line_id = 3
UNION ALL
SELECT 'dress price is rising before the sale, shirt price is flat',
       (SELECT eur_per_day_30d FROM v_de_price_claims WHERE line_id = 3) > 0
   AND ABS((SELECT eur_per_day_30d FROM v_de_price_claims WHERE line_id = 2)) < 1e-9
UNION ALL
SELECT 'harmonic average never exceeds arithmetic average',
       MIN(arith >= harm) = 1
  FROM (SELECT AVG(gp) AS arith, retail_agg.harmonic_mean(gp) AS harm
          FROM (SELECT unit_type, uvp / net_content * 100 AS gp
                  FROM products_de WHERE net_content IS NOT NULL) t
         GROUP BY unit_type) u
UNION ALL
SELECT 'dress sold above its UVP is allowed (line 14 is 14.3% over)',
       vs_uvp_pct = 14.3
  FROM v_de_lines WHERE line_id = 14;