-- ============================================================
-- MariaDB Custom Aggregate Function
-- Project: Custom Aggregate Functions
-- Author: Siddhartha Adepu
-- ============================================================

DELIMITER //

CREATE AGGREGATE FUNCTION positive_avg(value DECIMAL(10,2))
RETURNS DECIMAL(10,2)
BEGIN
    DECLARE total DECIMAL(20,2) DEFAULT 0;
    DECLARE count_values INT DEFAULT 0;

    -- Add only positive values
    IF value > 0 THEN
        SET total = total + value;
        SET count_values = count_values + 1;
    END IF;

    -- Return average of positive values
    IF count_values > 0 THEN
        RETURN total / count_values;
    ELSE
        RETURN 0;
    END IF;
END //

DELIMITER ;
