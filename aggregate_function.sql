-- ============================================================
-- MariaDB Custom Aggregate Function
-- Project: Custom Aggregate Functions
-- Author: Siddhartha Adepu
--
-- positive_avg(value): average of the positive values in the group,
-- or 0 when there are none. Run adnanaggregatefn.sql first: the
-- function goes into capstone_agg and the demo uses portfolio_returns.
-- ============================================================

USE capstone_agg;

DROP FUNCTION IF EXISTS positive_avg;

DELIMITER //

CREATE AGGREGATE FUNCTION positive_avg(value DECIMAL(10,2))
RETURNS DECIMAL(10,2)
BEGIN
    DECLARE total DECIMAL(20,2) DEFAULT 0;
    DECLARE count_values INT DEFAULT 0;

    -- Runs after the last row of the group: return average of positive values
    DECLARE CONTINUE HANDLER FOR NOT FOUND
    BEGIN
        IF count_values > 0 THEN
            RETURN total / count_values;
        ELSE
            RETURN 0;
        END IF;
    END;

    LOOP
        FETCH GROUP NEXT ROW;
        -- Add only positive values
        IF value > 0 THEN
            SET total = total + value;
            SET count_values = count_values + 1;
        END IF;
    END LOOP;
END //

DELIMITER ;

-- Average gain in the years that gained, next to the built-in way to write it.
-- Both columns agree (the built-in one is rounded to positive_avg's DECIMAL(10,2) result type),
-- so positive_avg is a teaching example: the built-in version is one line.
SELECT portfolio,
       positive_avg(growth - 1)                                     AS avg_gain_custom,
       ROUND(COALESCE(AVG(IF(growth - 1 > 0, growth - 1, NULL)), 0), 2) AS avg_gain_builtin
FROM portfolio_returns
GROUP BY portfolio
ORDER BY portfolio;
