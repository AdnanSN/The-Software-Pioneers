The software pioneers - Capstone 
Starter- Custom aggregate functions

## geo_mean

`geo_mean(x)` is a custom aggregate function that returns the geometric mean of a column. It is written with MariaDB's `CREATE AGGREGATE FUNCTION`, which MySQL and PostgreSQL don't support.

- NULLs are ignored, like `AVG()`
- Returns NULL for an empty group or if any value is <= 0
- Uses a sum of logs so large values don't overflow

Source: [adnanaggregatefn.sql](adnanaggregatefn.sql)

### Requirements

- MariaDB 10.3.3 or newer (tested on MariaDB 12.3)

### How to run

Start your MariaDB server, then run the script:

```bash
mariadb -u root -p < adnanaggregatefn.sql
```

The script creates a `capstone_agg` database, the `geo_mean` function and a small `portfolio_returns` demo table, then runs the demo queries and the tests.

To use it afterwards:

```sql
USE capstone_agg;

SELECT portfolio, AVG(growth), geo_mean(growth)
FROM portfolio_returns
GROUP BY portfolio;
```

### Expected output

| portfolio | arithmetic_mean | geometric_mean |
|-----------|-----------------|----------------|
| alpha     | 1.050000        | 1.032280       |
| beta      | 1.050000        | 1.050000       |
| gamma     | 0.900000        | NULL           |

Alpha shows why the geometric mean matters: the plain average says 5% growth per year, but the real average growth is about 3.2%. Gamma has a 0 value, so it returns NULL.

All five tests at the end of the script should return `pass = 1`.
