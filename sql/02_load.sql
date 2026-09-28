-- =====================================================================
-- Load the eight CSV files into the staging tables
-- MySQL 8.0
-- =====================================================================
-- Run this after 01_schema.sql.
--
-- MySQL only reads files from its upload folder, so copy the eight CSV
-- files there first. To find the folder:
--     SHOW VARIABLES LIKE 'secure_file_priv';
-- On Windows it is usually C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/
-- =====================================================================

USE olist_analytics;


LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_customers_dataset.csv'
INTO TABLE stg_customers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_sellers_dataset.csv'
INTO TABLE stg_sellers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- This file has Windows line endings (\r\n).
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/product_category_name_translation.csv'
INTO TABLE stg_category_translation
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_products_dataset.csv'
INTO TABLE stg_products
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_orders_dataset.csv'
INTO TABLE stg_orders
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_order_items_dataset.csv'
INTO TABLE stg_order_items
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_order_payments_dataset.csv'
INTO TABLE stg_payments
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- Windows line endings too. Some review comments contain a backslash,
-- which MySQL would read as an escape character, so escaping is off.
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_order_reviews_dataset.csv'
INTO TABLE stg_reviews
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS;


-- ---------------------------------------------------------------------
-- Check the load before going any further. Every row should match.
-- ---------------------------------------------------------------------
SELECT 'customers'            AS table_name, COUNT(*) AS rows_loaded, 99441  AS expected FROM stg_customers
UNION ALL
SELECT 'sellers',              COUNT(*), 3095   FROM stg_sellers
UNION ALL
SELECT 'category_translation', COUNT(*), 71     FROM stg_category_translation
UNION ALL
SELECT 'products',             COUNT(*), 32951  FROM stg_products
UNION ALL
SELECT 'orders',               COUNT(*), 99441  FROM stg_orders
UNION ALL
SELECT 'order_items',          COUNT(*), 112650 FROM stg_order_items
UNION ALL
SELECT 'payments',             COUNT(*), 103886 FROM stg_payments
UNION ALL
SELECT 'reviews',              COUNT(*), 99224  FROM stg_reviews;
