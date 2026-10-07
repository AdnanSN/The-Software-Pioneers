A project for area 2, "Custom aggregate functions in SQL" for the [MariaDB student database projects, 2026-09](https://mariadb.org/bachelor_hackathon_2026-09/).

# The Software Pioneers: custom aggregate functions

## Functions

Six custom aggregate functions written with MariaDB's `CREATE AGGREGATE FUNCTION`. They work with `GROUP BY` just like `AVG()` or `SUM()`. MySQL has no way to write an aggregate in SQL (you would need a C UDF). PostgreSQL's `CREATE AGGREGATE` ties together separately written functions: one that updates a running state for each row, and optionally one that turns the state into the result. In MariaDB each aggregate is a single routine that loops over the rows of its group.

| Function | Returns | Written by | File |
|----------|---------|------------|------|
| `geo_mean(x)` | Geometric mean | Adnan S | [adnanaggregatefn.sql](adnanaggregatefn.sql) |
| `weighted_geo_mean(x, w)` | Geometric mean where each value counts `w` times | Adnan S | [adnanaggregatefn.sql](adnanaggregatefn.sql) |
| `percentile(x, p)` | The `p`-th percentile (0 to 1) with linear interpolation, so `percentile(x, 0.5)` is the median | Adnan S | [adnanaggregatefn.sql](adnanaggregatefn.sql) |
| `mode_value(x)` | The most frequent value | Adnan S | [adnanaggregatefn.sql](adnanaggregatefn.sql) |
| `agg_sum_squares(x)` | Sum of the squares of `x` | Rahmath Shareef | [starter_aggregate_functions.sql](starter_aggregate_functions.sql) |
| `positive_avg(value)` | Average of the positive values (draft, see [below](#positive_avgvalue)) | Siddhartha Adepu | [aggregate_function.sql](aggregate_function.sql) |

The four in `adnanaggregatefn.sql` ignore NULLs and return NULL for an empty group, and are covered by [test.sql](test.sql). `agg_sum_squares` and `positive_avg` are described under [More functions from the team](#more-functions-from-the-team).

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
- A stored aggregate only sees one row at a time, so the values are collected into a JSON array and sorted with `JSON_TABLE` at the end
- Values are stored with `CAST(x AS CHAR)` to keep full double precision (`JSON_ARRAY_APPEND` rounds to 9 digits)

### mode_value(x)

- Ties go to the smallest value
- Takes text, so it works on categories like `'low'`/`'high'` as well as numbers. Numbers are compared as text when breaking a tie (`'10'` sorts before `'9'`)
- Values are escaped with `JSON_QUOTE`, so commas and quotes inside values are safe

### Requirements

- MariaDB 10.6 or newer, for `JSON_TABLE` (tested on MariaDB 12.3)

### How to run

Start your MariaDB server, then run the two scripts:

```bash
mariadb -u root -p < adnanaggregatefn.sql
```

```bash
mariadb -u root -p < test.sql
```

The first script creates a `capstone_agg` database, the four functions and a `portfolio_returns` demo table (yearly growth, money invested and risk rating for three portfolios), then runs the demo queries. The second runs the tests.

To use the functions afterwards:

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

### Expected output

Summary per portfolio:

| portfolio | arithmetic_mean | geometric_mean | capital_weighted | median   | p90      | usual_risk |
|-----------|-----------------|----------------|------------------|----------|----------|------------|
| alpha     | 1.030000        | 1.018735       | 1.007949         | 1.050000 | 1.190000 | high       |
| beta      | 1.050000        | 1.049976       | 1.050096         | 1.050000 | 1.057000 | low        |
| gamma     | 1.020000        | NULL           | NULL             | 1.200000 | 1.420000 | high       |

- Alpha's plain average says 3% growth per year, but the real average growth is about 1.9%. Weighting by capital drops it to 0.8%, because the bad years had more money in them.
- Gamma had a year with growth 0 (lost everything), so the geometric means are NULL.

What 1000 invested at the start would be worth at the end (only portfolios with average growth above 1):

| portfolio | avg_growth_pct | value_of_1000 |
|-----------|----------------|---------------|
| alpha     | 1.87           | 1097.25       |
| beta      | 5.00           | 1215.40       |

The test script prints each test and ends with `28 / 28 passed`. One test checks `percentile` against the built-in `PERCENTILE_CONT` for every portfolio at five different percentiles.

### Limitations

- MariaDB doesn't allow a stored aggregate to be written out inside `HAVING`. Give it an alias in the `SELECT` and use the alias in `HAVING` instead (see demo query 2).
- Stored aggregates can't be used as window functions (`OVER (...)`).
- `percentile` and `mode_value` keep every value of the group in memory as text, so they are slower than the built-ins on very large groups.

## More functions from the team

`agg_sum_squares` (Rahmath Shareef) and `positive_avg` (Siddhartha Adepu) are in their own files and are not installed by `adnanaggregatefn.sql`.

### agg_sum_squares(x)

- Adds up `x * x` over the group and returns a `DECIMAL(20,2)`
- Unlike `SUM()`, it doesn't skip NULLs: one NULL in the group makes the result NULL. With no rows it returns 0 rather than NULL
- The same file also shows built-in aggregates filtered with `HAVING` and two window functions (a running total and a rank inside each product), then calls `agg_sum_squares` per product
- Tested on MariaDB 12.3.3 against a `capstone_test.sales` table with `id`, `product` and `amount` columns. That table isn't in this repository yet, so the file can't be run from here

### positive_avg(value)

- Meant to return the average of the positive values in the group as a `DECIMAL(10,2)`, or 0 when there are none
- Still a draft: it has no `FETCH GROUP NEXT ROW` loop or `NOT FOUND` handler yet, which every stored aggregate needs, so MariaDB won't create it as written

## Files

| File | What it is |
|------|------------|
| [adnanaggregatefn.sql](adnanaggregatefn.sql) | The four aggregates, the `portfolio_returns` demo table and the demo queries |
| [test.sql](test.sql) | The 28 tests. Run it after `adnanaggregatefn.sql` |
| [starter_aggregate_functions.sql](starter_aggregate_functions.sql) | `agg_sum_squares`, plus examples of built-in aggregates and window functions |
| [aggregate_function.sql](aggregate_function.sql) | The `positive_avg` draft |

## Team

The Software Pioneers:

- Adnan S: `geo_mean`, `weighted_geo_mean`, `percentile` and `mode_value`, with the demo and the tests
- Rahmath Shareef: `agg_sum_squares` and the examples of built-in aggregates and window functions
- Siddhartha Adepu: `positive_avg`
