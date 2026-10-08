A project for area 2, "Custom aggregate functions in SQL" for the [MariaDB student database projects, 2026-09](https://mariadb.org/bachelor_hackathon_2026-09/).

# The Software Pioneers: custom aggregate functions

[![SQL tests](https://github.com/AdnanSN/The-Software-Pioneers/actions/workflows/tests.yml/badge.svg)](https://github.com/AdnanSN/The-Software-Pioneers/actions/workflows/tests.yml)

MariaDB's `CREATE AGGREGATE FUNCTION` lets you write your own aggregate in SQL and use it with `GROUP BY`, just like `AVG()` or `SUM()`. This repository is a small library of them (geometric mean, percentile, mode, Gini coefficient, compounded discounts and more) and a measured answer to the question every tutorial skips: **when is a custom aggregate worth it, and when should you write plain SQL instead?**

What we found:

- **Custom aggregates win on readability.** A per-portfolio summary of five statistics is 9 lines and one `SELECT` with them, and 25 lines, five `SELECT`s and two joins without them, because the built-in `PERCENTILE_CONT` and `ROW_NUMBER` are window functions that cannot share a `GROUP BY` with the rest.
- **They are also safer than the one-liners they replace.** The textbook geometric mean `EXP(AVG(LN(x)))` silently reports a 27% yearly gain for a portfolio that lost everything, because `LN(0)` is NULL and `AVG()` skips it.
- **They cost speed.** Every one we wrote is slower than its plain-SQL equivalent: 2 to 9 times slower when it keeps a running total, and up to about 60 times slower when it has to remember every value of the group, because that cost grows with the square of the group size.
- **Some are the wrong tool.** Where the plain version is one short, correct line (`harmonic_mean`, `agg_sum_squares`, `positive_avg`, `welford_stddev`), the custom aggregate only adds a slower routine to maintain. We kept those as examples of how to write one, and say so.

MySQL has no way to write an aggregate in SQL (you would need a C UDF). PostgreSQL's `CREATE AGGREGATE` ties together separately written functions: one that updates a running state for each row, and optionally one that turns the state into the result. In MariaDB each aggregate is a single routine that loops over the rows of its group.

## Quick start

Requirements: MariaDB 10.6 or newer (for `JSON_TABLE`). Developed on **MariaDB 12.3.3** on Windows 11; [CI](#continuous-integration) runs everything on 10.6, 11.4 and 12.3. Start your server, then from the repository folder:

```bash
mariadb -u root -p < run_all.sql
```

This creates the databases, installs all eleven functions, and runs every demo and test in about a second. Look for `28 / 28 passed` and for `pass = 1` on every self-check row. The data is all in the scripts, so nothing has to be downloaded.

Then run the with/without comparison (about three minutes):

```bash
mariadb -u root -p < with_vs_without.sql
```

To try the functions yourself afterwards:

```sql
USE capstone_agg;

SELECT portfolio,
       geo_mean(growth),
       weighted_geo_mean(growth, capital),
       percentile(growth, 0.5),
       mode_value(risk)
FROM portfolio_returns
GROUP BY portfolio;
```

## The functions

| Function | Returns | Plain-SQL alternative | Written by | File |
|----------|---------|-----------------------|------------|------|
| `geo_mean(x)` | Geometric mean | `EXP(AVG(LN(x)))` plus a guard, or it is silently wrong | Adnan S | [adnanaggregatefn.sql](adnanaggregatefn.sql) |
| `weighted_geo_mean(x, w)` | Geometric mean where each value counts `w` times | Five lines of `SUM(IF(...))` | Adnan S | [adnanaggregatefn.sql](adnanaggregatefn.sql) |
| `percentile(x, p)` | The `p`-th percentile (0 to 1), interpolated, so `percentile(x, 0.5)` is the median | `PERCENTILE_CONT`, window only | Adnan S | [adnanaggregatefn.sql](adnanaggregatefn.sql) |
| `mode_value(x)` | The most frequent value | `ROW_NUMBER()` over counts, in a subquery | Adnan S | [adnanaggregatefn.sql](adnanaggregatefn.sql) |
| `compound_discount(pct)` | Combined % off from stacked offers (20% then 10% = 28%) | `EXP(SUM(LN(...)))` with special cases for 100% | Rahmath Shareef | [01_retail_aggregates.sql](01_retail_aggregates.sql) |
| `harmonic_mean(x)` | Harmonic mean, the right average for unit prices | `COUNT(x) / SUM(1 / x)`: **use this instead** | Rahmath Shareef | [01_retail_aggregates.sql](01_retail_aggregates.sql) |
| `gini_coefficient(x)` | Inequality of the group, 0 = equal, near 1 = one value dominates | `ROW_NUMBER()` in a subquery | Rahmath Shareef | [01_retail_aggregates.sql](01_retail_aggregates.sql) |
| `trend_slope(x, y)` | Least-squares slope of `y` over `x` | Two passes with window `AVG()`, or a one-pass formula that loses precision | Rahmath Shareef | [01_retail_aggregates.sql](01_retail_aggregates.sql) |
| `welford_stddev(x)` | Sample standard deviation | `STDDEV_SAMP(x)`: **use this instead** | Rahmath Shareef | [shopping_mall__aggregate_functions.sql](shopping_mall__aggregate_functions.sql) |
| `agg_sum_squares(x)` | Sum of the squares of `x` | `SUM(x * x)`: **use this instead** | Rahmath Shareef | [starter_aggregate_functions.sql](starter_aggregate_functions.sql) |
| `positive_avg(value)` | Average of the positive values, 0 if none | `COALESCE(AVG(IF(value > 0, value, NULL)), 0)`: **use this instead** | Siddhartha Adepu | [aggregate_function.sql](aggregate_function.sql) |

All of them ignore NULLs and return NULL for an empty group, like `AVG()`, except `agg_sum_squares` (one NULL makes the result NULL, no rows give 0) and `positive_avg` (no positive rows give 0).

## How a stored aggregate works

Here is `geo_mean` from [adnanaggregatefn.sql](adnanaggregatefn.sql), with the four parts every stored aggregate needs:

```sql
DELIMITER //
CREATE AGGREGATE FUNCTION geo_mean(x DOUBLE) RETURNS DOUBLE   -- 1. AGGREGATE keyword
  DETERMINISTIC
BEGIN
  DECLARE log_sum DOUBLE DEFAULT 0;                           -- 2. state for one group
  DECLARE n BIGINT DEFAULT 0;
  DECLARE non_positive BOOLEAN DEFAULT FALSE;

  DECLARE CONTINUE HANDLER FOR NOT FOUND                      -- 3. runs after the last row:
    RETURN IF(n = 0 OR non_positive, NULL, EXP(log_sum / n)); --    turns the state into the result

  LOOP
    FETCH GROUP NEXT ROW;                                     -- 4. x now holds the next row's value
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
```

The server calls the routine once per group. `FETCH GROUP NEXT ROW` hands it the next row's arguments. When the group runs out, the `NOT FOUND` handler fires and its `RETURN` is the group's result.

The functions here come in two kinds, and the kind decides how fast they are:

- **Running state** (`geo_mean`, `weighted_geo_mean`, `compound_discount`, `harmonic_mean`, `trend_slope`, `welford_stddev`): a few variables updated per row. Memory and time per row are constant.
- **Buffering** (`percentile`, `mode_value`, `gini_coefficient`): the answer depends on the order or the counts of all values, but the routine only sees one row at a time. So it appends every value to a text list (`CONCAT_WS`), and at the end turns the list into rows with `JSON_TABLE` and sorts or groups them with ordinary SQL. MariaDB's [documentation example](https://mariadb.com/docs/server/server-usage/stored-routines/stored-functions/stored-aggregate-functions) buffers into a temporary table instead; a text list needs no table to create and drop for every group.

## With and without: the comparison

[with_vs_without.sql](with_vs_without.sql) puts every function next to the plain SQL you would write without it, checks that both give the same answer, and times both.

### The summary, both ways

With the custom aggregates:

```sql
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
```

Without them. `PERCENTILE_CONT` and `ROW_NUMBER` only work as window functions, so each needs its own derived table, joined back on `portfolio`. The geometric means need guards so that a growth of 0 gives NULL instead of being skipped:

```sql
SELECT s.portfolio,
       ROUND(s.arithmetic_mean, 6)  AS arithmetic_mean,
       ROUND(s.geometric_mean, 6)   AS geometric_mean,
       ROUND(s.capital_weighted, 6) AS capital_weighted,
       ROUND(p.median, 6)           AS median,
       ROUND(p.p90, 6)              AS p90,
       m.usual_risk
FROM (SELECT portfolio,
             AVG(growth) AS arithmetic_mean,
             IF(MIN(growth) <= 0, NULL,
                EXP(AVG(LN(IF(growth > 0, growth, NULL))))) AS geometric_mean,
             IF(MIN(growth) <= 0, NULL,
                EXP(SUM(IF(growth > 0, capital * LN(growth), NULL))
                    / SUM(IF(growth > 0, capital, NULL)))) AS capital_weighted
        FROM portfolio_returns
       GROUP BY portfolio) AS s
LEFT JOIN (SELECT DISTINCT portfolio,
                  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY growth)
                    OVER (PARTITION BY portfolio) AS median,
                  PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY growth)
                    OVER (PARTITION BY portfolio) AS p90
             FROM portfolio_returns
            WHERE growth IS NOT NULL) AS p USING (portfolio)
LEFT JOIN (SELECT portfolio, risk AS usual_risk
             FROM (SELECT portfolio, risk,
                          ROW_NUMBER() OVER (PARTITION BY portfolio
                                             ORDER BY COUNT(*) DESC, risk) AS rn
                     FROM portfolio_returns
                    GROUP BY portfolio, risk) AS counted
            WHERE rn = 1) AS m USING (portfolio)
ORDER BY s.portfolio;
```

Both print the same table:

| portfolio | arithmetic_mean | geometric_mean | capital_weighted | median   | p90      | usual_risk |
|-----------|-----------------|----------------|------------------|----------|----------|------------|
| alpha     | 1.030000        | 1.018735       | 1.007949         | 1.050000 | 1.190000 | high       |
| beta      | 1.050000        | 1.049976       | 1.050096         | 1.050000 | 1.057000 | low        |
| gamma     | 1.020000        | NULL           | NULL             | 1.200000 | 1.420000 | high       |

- Alpha's plain average says 3% growth per year, but the real average growth is about 1.9%. Weighting by capital drops it to 0.8%, because the bad years had more money in them.
- Gamma had a year with growth 0 (lost everything), so the geometric means are NULL.

### The one-liners that look right

| portfolio | `EXP(AVG(LN(growth)))` | `geo_mean(growth)` |
|-----------|------------------------|--------------------|
| alpha     | 1.018735               | 1.018735           |
| beta      | 1.049976               | 1.049976           |
| gamma     | **1.266637**           | NULL               |

The textbook formula tells you gamma grew 27% a year. The only sign that something went wrong is a `Division by 0` warning that most clients never show. Worse, the same expression is an **error** as soon as the result is written to a table (`CREATE TABLE ... AS`, `INSERT ... SELECT`), because the default `sql_mode` includes `STRICT_TRANS_TABLES` and `ERROR_FOR_DIVISION_BY_ZERO`. So every plain-SQL version in the comparison wraps its `LN()` or `1 / x` in an `IF`. The custom aggregates decide once, inside the routine, what a bad value means.

Similarly, the one-pass textbook slope `(n·Σxy − Σx·Σy) / (n·Σx² − (Σx)²)` loses precision when `x` is large. With 365 days numbered from 740,000 (as `TO_DAYS()` returns) and `y = 0.5x − 370000`, it returns 0.4999999993; `trend_slope` returns exactly 0.5 because it updates running means instead of summing huge squares (Welford's method).

### Query length

From report 4a of the script. Characters are counted with whitespace collapsed; `SELECT`s counts the query and its subqueries.

| Function | With: chars | Without: chars | Without: `SELECT`s |
|----------|-------------|----------------|--------------------|
| `geo_mean` | 78 | 132 | 1 |
| `weighted_geo_mean` | 96 | 272 | 1 |
| `percentile` | 85 | 158 | 1 |
| `mode_value` | 78 | 228 | 2 |
| `compound_discount` | 99 | 234 | 1 |
| `harmonic_mean` | 94 | 132 | 1 |
| `gini_coefficient` | 98 | 329 | 2 |
| `trend_slope` | 98 | 375 (two passes), 230 (one-pass formula) | 2, 1 |
| **summary of five statistics** | **276** | **968** | **5** |

Every "with" query is one `SELECT` with a `GROUP BY`. The single-function differences are modest; the difference that matters is the summary, where the window functions force a separate derived table per statistic.

### Execution time

The same 50,000 generated rows, cut into 500, 50 and 5 groups. Median of 5 timed runs after one warm-up, in milliseconds, with the custom aggregate / without it:

| Function | 500 groups × 100 rows | 50 groups × 1,000 rows | 5 groups × 10,000 rows |
|----------|----------------------|------------------------|------------------------|
| `geo_mean` | 96 / 18 (5.3×) | 95 / 18 (5.4×) | 99 / 19 (5.4×) |
| `weighted_geo_mean` | 126 / 27 (4.7×) | 132 / 22 (6.1×) | 124 / 23 (5.4×) |
| `compound_discount` | 157 / 21 (7.5×) | 165 / 22 (7.4×) | 151 / 21 (7.3×) |
| `harmonic_mean` | 141 / 18 (7.9×) | 139 / 18 (7.8×) | 158 / 17 (9.2×) |
| `trend_slope` (vs. two passes) | 200 / 91 (2.2×) | 206 / 93 (2.2×) | 197 / 96 (2.1×) |
| `percentile` | 294 / 66 (4.5×) | 589 / 65 (9.1×) | **4,317 / 71 (61.1×)** |
| `mode_value` | 126 / 33 (3.8×) | 245 / 36 (6.8×) | **1,864 / 36 (51.7×)** |
| `gini_coefficient` | 214 / 70 (3.1×) | 262 / 69 (3.8×) | **1,214 / 79 (15.3×)** |
| **summary of five statistics** | 827 / 125 (6.6×) | 1,574 / 129 (12.2×) | **9,849 / 133 (73.9×)** |

The one-pass textbook formula for `trend_slope` is faster still (about 23 ms, 9× faster than `trend_slope`) and agreed on this data, where `x` is a year number below 12,000. It is the version that breaks on day numbers, as shown above.

What the numbers say:

- **Running-state aggregates cost about 2–4 µs per row, whatever the group size.** That is the price of running a stored routine for every row instead of compiled C. On 50,000 rows it is a tenth of a second, so for reports and dashboards it rarely matters.
- **Buffering aggregates grow with the square of the group size.** `percentile` goes from 0.3 s to 4.3 s while the row count stays the same. To find out why, we timed an aggregate that does nothing but the `CONCAT_WS` append: it took 202, 528 and 4,521 ms on the three shapes, about the same as `percentile`. So almost all of the time is spent copying the growing list on every append; `JSON_TABLE` and the sort are cheap. With groups in the thousands of rows, use the window-function version.
- **Results always agreed.** Report 4b compares every group of every function on every shape, plus the 15 demo rows with their NULL and zero values: 0 groups differ (to 1e-9 relative).

How stable the numbers are: the standard deviation of the 5 runs was within 10% of the median for 43 of the 57 timed queries, and within 21% for all of them (report 4c lists min, max and standard deviation for each). A separate earlier run of the whole script gave ratios within about 20% of these, for example 4,505 ms instead of 4,317 ms for `percentile` on 10,000-row groups. So treat differences under about 20% as noise; the large ratios are well outside it.

### When to write a custom aggregate, and when not to

Use one when:

- the statistic needs **order or counts** within the group (median, percentiles, mode, Gini) **and** you want it next to other aggregates in one `GROUP BY`. That is where plain SQL needs a derived table and a join per statistic;
- the plain version needs **guards that are easy to forget**, as with `geo_mean` and `compound_discount`;
- the plain formula is **numerically fragile** and a running update fixes it (`trend_slope`);
- you want **one tested definition** shared by many queries instead of the same expression copied around.

Don't use one when:

- a **built-in or a one-line expression already does it**: `STDDEV_SAMP`, `SUM(x * x)`, `COUNT(x) / SUM(1 / x)`, `AVG(IF(...))`. Our `welford_stddev`, `agg_sum_squares`, `harmonic_mean` and `positive_avg` give the same answers as those through a slower routine (`harmonic_mean` measured 8–9× slower), so read them as examples of how to write a running-state aggregate;
- **groups are large and the function buffers**: the window-function version stays fast, ours slows down with the square of the group size;
- you need it **as a window function** (`OVER (...)`) or **written out inside `HAVING`**: MariaDB supports neither (see [Limitations](#limitations)).

## Data model

**`portfolio_returns`** (`capstone_agg`, in [adnanaggregatefn.sql](adnanaggregatefn.sql)): one row per portfolio and year, with `PRIMARY KEY (portfolio, year)` because a portfolio has exactly one result per year. The 15 rows are small on purpose, so every edge case is visible:

- `growth` is the yearly growth factor (1.05 = +5%). It is a ratio, which is why the geometric mean is the right average. It is nullable, to model a missing year (beta 2022).
- `capital` (money invested that year, `NOT NULL`) is the weight for `weighted_geo_mean`.
- `risk` is text (`'low'`/`'medium'`/`'high'`), to show `mode_value` working on categories, not only numbers.
- Gamma has a growth of 0 in 2021, so every function has to decide what that means.

**`returns_data`** (in [with_vs_without.sql](with_vs_without.sql)) has the same columns plus `fee_pct`, so every query in the comparison can run against both the demo rows and the generated ones. The generated rows come from `seq_0_to_49999`, a table of MariaDB's built-in [Sequence storage engine](https://mariadb.com/docs/server/server-usage/storage-engines/sequence-storage-engine). The values are computed from the row number with modular arithmetic instead of `RAND()`, so every run sees exactly the same data: growth between 0.85 and 1.20, capital 50–1058, risk 40% low, 40% medium, 20% high.

The **mall schemas** are described with the [retail examples](#retail-examples-india-and-germany) below.

## Method

- **Machine:** Intel Core i5-13450HX, 16 GB RAM, Windows 11, MariaDB 12.3.3 with its default configuration. The query cache is off by default, so repeated runs are not served from a cache.
- **Timing:** `run_bench()` in [with_vs_without.sql](with_vs_without.sql) prepares each query once, runs it once as a warm-up, then times `@reps` (default 5) runs with `SYSDATE(6)`. Unlike `NOW()`, `SYSDATE()` returns the time at the moment it is evaluated, so it can measure inside a procedure. Each query is wrapped in `CREATE TEMPORARY TABLE ... AS`, so both approaches materialise their result the same way and nothing is sent to the client.
- **Correctness:** the warm-up result of every query is saved in `bench_results` and compared group by group with the custom aggregate's result.
- **Reports:** medians are computed with our own `percentile(ms, 0.5)`; min, max and standard deviation are reported next to them. All raw timings stay in the `bench_times` table for further queries.
- **Caveats:** one machine, 5 runs each, a laptop with other programs open. The ratios are more trustworthy than the absolute milliseconds. Run the script on your machine to compare.

## Tests

- [test.sql](test.sql): 28 tests for the four core functions, including NULLs, empty groups, non-positive values, overflow, ties, quotes inside values, and a check of `percentile` against the built-in `PERCENTILE_CONT` for every portfolio at five percentiles. Ends with `28 / 28 passed`.
- [01_retail_aggregates.sql](01_retail_aggregates.sql): 19 self-checks for the retail functions, worked out by hand.
- [02_india_mall.sql](02_india_mall.sql) (8) and [03_germany_mall.sql](03_germany_mall.sql) (10): self-checks of the findings below.
- [with_vs_without.sql](with_vs_without.sql): every function against its plain-SQL equivalent, 0 groups differ.

The comparison found one bug, which is now fixed and tested: `gini_coefficient` computed `(n + 1) / n` as integer division, which MariaDB rounds to a fixed number of decimals (`div_precision_increment`). That put gini(1, 2, 3) off by 3·10⁻¹⁰, small enough to pass the old tests with their 1e-9 tolerance.

### Continuous integration

[.github/workflows/tests.yml](.github/workflows/tests.yml) runs on every push and pull request, once each on MariaDB 10.6 (the oldest version with `JSON_TABLE`), 11.4 (long-term support) and 12.3 (the version we developed on), using the official `mariadb` Docker images. Each job:

1. starts a fresh server and runs [run_all.sql](run_all.sql). Any SQL error stops the client with a non-zero exit code and fails the job;
2. runs [with_vs_without.sql](with_vs_without.sql) with one timed run per query instead of five (the timings on a shared CI machine are not meaningful, but the correctness report is);
3. checks both outputs with [.github/scripts/check-results.sh](.github/scripts/check-results.sh): `test.sql` must end with `N / N passed`, every self-check row must show `pass = 1`, and every with/without comparison must show 0 differing groups. A run that produced no checks at all also fails.

Each job takes under a minute and keeps its output as a downloadable artifact.

## Limitations

Both of these were checked on MariaDB 12.3.3:

- A stored aggregate can't be written out inside `HAVING` (`HAVING geo_mean(growth) > 1` fails with `Unknown column 'growth' in 'HAVING'`). Give it an alias in the `SELECT` and use the alias in `HAVING` instead (see demo query 2 in [adnanaggregatefn.sql](adnanaggregatefn.sql)).
- Stored aggregates can't be used as window functions: `geo_mean(growth) OVER (...)` is a syntax error.

Also:

- `percentile`, `mode_value` and `gini_coefficient` keep every value of the group in memory as text, and slow down with the square of the group size (see [Execution time](#execution-time)).
- `mode_value` compares numbers as text when breaking a tie (`'10'` sorts before `'9'`).

## Details of the core functions

### geo_mean(x)

- Returns NULL if any value is <= 0
- Uses a sum of logs so large values don't overflow

### weighted_geo_mean(x, w)

Computes `EXP(SUM(w * LN(x)) / SUM(w))`. Useful when some values matter more than others, for example yearly returns weighted by how much money was invested that year.

- Rows where `x` or `w` is NULL, or `w = 0`, are skipped
- Returns NULL if a used `x` is <= 0, any `w` is negative, or every weight is 0
- With equal weights it gives the same result as `geo_mean(x)`

### percentile(x, p)

Gives the same answer as MariaDB's `PERCENTILE_CONT(p) WITHIN GROUP (ORDER BY x)`, but that built-in only works as a window function (`OVER (...)`). `percentile` works with `GROUP BY`, so you get one row per group.

- `p` must be between 0 and 1 and the same for every row, otherwise the result is NULL
- Values are stored with `CAST(x AS CHAR)` to keep full double precision (`JSON_ARRAY_APPEND` rounds to 9 digits)

### mode_value(x)

- Ties go to the smallest value
- Takes text, so it works on categories like `'low'`/`'high'` as well as numbers
- Values are escaped with `JSON_QUOTE`, so commas and quotes inside values are safe

### Demo query 2

What 1000 invested at the start would be worth at the end (only portfolios with average growth above 1). It uses `geo_mean` inside a CTE and in `HAVING` through its alias:

| portfolio | avg_growth_pct | value_of_1000 |
|-----------|----------------|---------------|
| alpha     | 1.87           | 1097.25       |
| beta      | 5.00           | 1215.40       |

## Retail examples: India and Germany

Rahmath's retail functions put the aggregates to work on two mall databases with real pricing rules. Run [01_retail_aggregates.sql](01_retail_aggregates.sql) first: it installs the functions into a `retail_agg` database, and the mall scripts call them as `retail_agg.compound_discount(...)` and so on. `run_all.sql` does this in the right order.

### India ([02_india_mall.sql](02_india_mall.sql), database `mall_retail`)

Schema: `categories`, `products` (MRP is NULL for loose goods), `offers`, `sales_lines`, and `line_offers` linking each bill line to any number of stacked offers. `gst_rates` keeps one row per category and **validity period** (`valid_from`, `valid_to`), so a rate change adds rows instead of rewriting history, and a sale is always taxed with the rule in force on its date. A data-quality query checks that no two rules overlap.

Findings, each one a self-check in the script:

- **Offers stack multiplicatively.** 20% + 10% + 5% is 31.6% off, not 35%; `compound_discount` computes it in one aggregate over `line_offers`. One stack (40% + 30% + 10% = 62.2%) would sell a T-shirt below cost, so the price floor applies.
- **Discounts move items across the GST slab.** The MRP is tax-inclusive, and the slab is judged on the price actually charged per piece, before tax. A ₹3,499 blazer with two offers bills at ₹2,519.28, or ₹2,399 before tax, so it falls into the 5% slab. Deciding the slab from the MRP (18%) would overstate the tax by ₹264.33; across the two lines that cross, ₹479.56.
- **The same shirt, two tax rates.** A ₹1,799 shirt sold on 20.09.2025 pays 12% GST (₹192.75); sold on 25.09.2025 it pays 5% (₹85.67).
- Revenue concentration across products: `gini_coefficient` = 0.49, with the top product at 30% of revenue.

Sources and simplifications:

- GST on apparel: until 21.09.2025, 5% up to ₹1,000 per piece and 12% above. From 22.09.2025, 5% up to ₹2,500 and 18% above (56th GST Council; Notification 9/2025-Central Tax (Rate)), judged per piece on the value before tax.
- MRP must be printed on pre-packaged goods under the Legal Metrology (Packaged Commodities) Rules, 2011, and includes all taxes. Loose goods have no MRP.
- Simplified: make-up and loose accessories use a flat 18%. Their real rate depends on the exact HSN code.

### Germany ([03_germany_mall.sql](03_germany_mall.sql), database `mall_retail_de`)

Schema: `categories_de` (flat VAT rate, whether a unit price is required), `products_de` (UVP, net content and unit), `sales_lines_de` (price charged and the crossed-out "was" price, if any), and `price_history`, one price per product and day, because the legal reference price can only be answered from history.

Findings:

- **Inflated "was" prices.** A dress advertised "was €79.99, now €49.99" (37.5% off) had cost €59.99 for most of the 30 days before, so the true discount is 16.7%. `trend_slope` over the price history shows the price rising just before the "sale", which is how a raised-then-cut price shows up in the data. A shirt's "was €39.99" matches its 30-day low and is fine.
- **Arithmetic vs. harmonic average unit price** for make-up sold by weight: €3,808/kg vs. €2,372/kg. The harmonic mean is what you actually pay per kg if you spend the same money on each product.
- **Selling above the UVP is legal** (a dress at 14.3% over), unlike selling above an Indian MRP.
- VAT is carved out of the gross price, so net + VAT = gross on every line.

Sources and simplifications:

- VAT 19% for clothing and cosmetics (UStG §12(1)), with no price slab.
- Unit price (Grundpreis) per 1 kg or 1 l, PAngV §4 and §5. The per-100 g option was removed on 28.05.2022. Goods under 10 g or 10 ml are exempt (§4(3) no. 1), which is why the 3.5 g lipsticks have none.
- Price reductions must be advertised against the lowest price of the previous 30 days, PAngV §11, which implements the EU Omnibus Directive (2019/2161).
- Simplified: the sale date stands in for the date the reduction started, and stepwise reductions (§11(2)) are not modelled.

### First version ([shopping_mall__aggregate_functions.sql](shopping_mall__aggregate_functions.sql), database `mall_retail_v1`)

The first draft of the India example, with three discount columns instead of an offers table and only the old GST slab. It also defines `welford_stddev`, shown next to the built-in `STDDEV_SAMP`, which gives the same results. It uses its own database so it never touches the tables of `02_india_mall.sql`.

## More functions from the team

### agg_sum_squares(x) ([starter_aggregate_functions.sql](starter_aggregate_functions.sql))

- Adds up `x * x` over the group and returns a `DECIMAL(20,2)`
- Unlike `SUM()`, it doesn't skip NULLs: one NULL in the group makes the result NULL. With no rows it returns 0 rather than NULL. The demo shows this next to `SUM(amount * amount)`, which skips the NULL
- The file creates a small `capstone_test.sales` table (only filled when it is new or empty) and also shows built-in aggregates filtered with `HAVING` and two window functions: a running total and a rank inside each product

### positive_avg(value) ([aggregate_function.sql](aggregate_function.sql))

- Returns the average of the positive values in the group as a `DECIMAL(10,2)`, or 0 when there are none
- Installed into `capstone_agg`. The demo computes the average gain in the years that gained, next to the built-in one-liner

## Files

| File | What it is |
|------|------------|
| [run_all.sql](run_all.sql) | Runs everything below except the comparison, in the right order |
| [adnanaggregatefn.sql](adnanaggregatefn.sql) | The four core aggregates, the `portfolio_returns` demo table and the demo queries |
| [test.sql](test.sql) | The 28 tests. Run it after `adnanaggregatefn.sql` |
| [with_vs_without.sql](with_vs_without.sql) | Every function next to its plain-SQL equivalent: correctness, length and timing |
| [01_retail_aggregates.sql](01_retail_aggregates.sql) | `compound_discount`, `harmonic_mean`, `gini_coefficient`, `trend_slope`, with self-checks |
| [02_india_mall.sql](02_india_mall.sql) | Indian mall: MRP, stacked offers, dated GST slabs |
| [03_germany_mall.sql](03_germany_mall.sql) | German mall: UVP, flat VAT, unit price, 30-day reference price |
| [shopping_mall__aggregate_functions.sql](shopping_mall__aggregate_functions.sql) | First version of the Indian mall, with `welford_stddev` |
| [starter_aggregate_functions.sql](starter_aggregate_functions.sql) | `agg_sum_squares`, plus examples of built-in aggregates and window functions |
| [aggregate_function.sql](aggregate_function.sql) | `positive_avg` |
| [.github/workflows/tests.yml](.github/workflows/tests.yml) | CI: runs everything on MariaDB 10.6, 11.4 and 12.3 |
| [.github/scripts/check-results.sh](.github/scripts/check-results.sh) | Fails CI if any test, self-check or with/without comparison failed |

## Team

The Software Pioneers:

- Adnan S: `geo_mean`, `weighted_geo_mean`, `percentile` and `mode_value`, the demo, the tests and the with/without comparison
- Rahmath Shareef: `compound_discount`, `harmonic_mean`, `gini_coefficient`, `trend_slope`, `welford_stddev` and `agg_sum_squares`, the India and Germany mall examples, and the examples of built-in aggregates and window functions
- Siddhartha Adepu: `positive_avg`
