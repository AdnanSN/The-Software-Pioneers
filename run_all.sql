-- run_all.sql: installs every function and runs every demo and test, in the right order.
-- Run it from the repository folder:  mariadb -u root -p < run_all.sql
-- The benchmark is separate because it takes about three minutes:
--                                      mariadb -u root -p < with_vs_without.sql

-- The four core aggregates, the portfolio_returns demo, and the 28 tests
source adnanaggregatefn.sql
source test.sql

-- Team functions: positive_avg (needs capstone_agg) and agg_sum_squares
source aggregate_function.sql
source starter_aggregate_functions.sql

-- Retail aggregates with self-checks, then the two mall examples that use them
source 01_retail_aggregates.sql
source 02_india_mall.sql
source 03_germany_mall.sql

-- First version of the Indian mall example, with welford_stddev
source shopping_mall__aggregate_functions.sql
