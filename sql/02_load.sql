-- =====================================================================
-- Load the eight CSV files into the staging tables
-- MySQL 8.0
-- =====================================================================
-- Run this after 01_schema.sql.
--
-- The MySQL server reads the files itself, and only from its upload
-- folder (the secure_file_priv setting). On a standard Windows install
-- that folder is:
--     C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/
--
-- Before running, copy the eight CSV files from data/ into that folder.
-- To check where it is on your machine:
--     SHOW VARIABLES LIKE 'secure_file_priv';
-- and change the paths below if it is somewhere else.
--
-- The options, and why they are there:
--   CHARACTER SET utf8mb4        Portuguese text (ã, é, ç) loads correctly
--   OPTIONALLY ENCLOSED BY '"'   commas and line breaks inside quoted
--                                review comments stay in one field
--   ESCAPED BY ''                a backslash is just a character: some
--                                review comments contain one
--   LINES TERMINATED BY          the Kaggle files are not consistent. Six
--                                end lines with '\n', while reviews and
--                                category_translation use Windows '\r\n'
--   IGNORE 1 ROWS                skips the header row
--
-- Empty fields load as empty strings (''), not NULL. 03_cleaning.sql
-- turns them into NULL.
-- =====================================================================

USE olist_analytics;


LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_customers_dataset.csv'
INTO TABLE stg_customers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_sellers_dataset.csv'
INTO TABLE stg_sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/product_category_name_translation.csv'
INTO TABLE stg_category_translation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_products_dataset.csv'
INTO TABLE stg_products
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_orders_dataset.csv'
INTO TABLE stg_orders
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_order_items_dataset.csv'
INTO TABLE stg_order_items
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_order_payments_dataset.csv'
INTO TABLE stg_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/olist_order_reviews_dataset.csv'
INTO TABLE stg_reviews
CHARACTER SET utf8mb4
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
