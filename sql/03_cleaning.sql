-- =====================================================================
-- Profile, clean and load the model
-- MySQL 8.0
-- =====================================================================
-- Run this after 02_load.sql.
--
-- The traps in this dataset, each counted in section 1 and handled in 2:
--   - customer_id is one per ORDER; the real person is customer_unique_id
--   - some orders have more than one review    -> keep the latest per order
--   - some products have no category, and some categories no English name
--   - 'delivered' orders with no delivery date  -> left out of delivery metrics
--
-- LOAD DATA stores an empty field as '' rather than NULL, so NULLIF(x, '')
-- turns those back into NULL before a value is converted.
--
-- Re-runnable on its own: the model tables are emptied first.
-- =====================================================================

USE olist_analytics;


-- ---------------------------------------------------------------------
-- 1. Profile the raw data before touching it
-- ---------------------------------------------------------------------
SELECT 'orders'      AS file_name, COUNT(*) AS row_count FROM stg_orders       UNION ALL
SELECT 'order_items',              COUNT(*)              FROM stg_order_items  UNION ALL
SELECT 'payments',                 COUNT(*)              FROM stg_payments     UNION ALL
SELECT 'reviews',                  COUNT(*)              FROM stg_reviews      UNION ALL
SELECT 'customers',                COUNT(*)              FROM stg_customers    UNION ALL
SELECT 'products',                 COUNT(*)              FROM stg_products     UNION ALL
SELECT 'sellers',                  COUNT(*)              FROM stg_sellers      UNION ALL
SELECT 'category_translation',     COUNT(*)              FROM stg_category_translation;

SELECT 'people with more than one customer_id' AS check_name, COUNT(*) AS found
FROM (SELECT customer_unique_id FROM stg_customers GROUP BY customer_unique_id HAVING COUNT(*) > 1) AS x
UNION ALL
SELECT 'orders with more than one review', COUNT(*)
FROM (SELECT order_id FROM stg_reviews GROUP BY order_id HAVING COUNT(*) > 1) AS x
UNION ALL
SELECT 'review ids reused across orders', COUNT(*)
FROM (SELECT review_id FROM stg_reviews GROUP BY review_id HAVING COUNT(DISTINCT order_id) > 1) AS x
UNION ALL
SELECT 'products with no category', COUNT(*)
FROM stg_products WHERE product_category_name = ''
UNION ALL
SELECT 'categories with no English name', COUNT(DISTINCT p.product_category_name)
FROM stg_products AS p
LEFT JOIN stg_category_translation AS t ON t.product_category_name = p.product_category_name
WHERE p.product_category_name <> '' AND t.product_category_name IS NULL
UNION ALL
SELECT 'delivered orders with no delivery date', COUNT(*)
FROM stg_orders
WHERE order_status = 'delivered' AND order_delivered_customer_date = '';


-- ---------------------------------------------------------------------
-- 2. Load the model: typed, de-duplicated, keys enforced
-- ---------------------------------------------------------------------
-- Empty the model, children before parents (foreign keys rule out TRUNCATE).
-- Workbench's Safe Updates mode blocks DELETE without a WHERE clause, so
-- switch it off for this session.
SET SQL_SAFE_UPDATES = 0;
DELETE FROM reviews;
DELETE FROM payments;
DELETE FROM order_items;
DELETE FROM orders;
DELETE FROM products;
DELETE FROM category_translation;
DELETE FROM sellers;
DELETE FROM customers;

INSERT INTO customers (customer_id, customer_unique_id, customer_zip_prefix, customer_city, customer_state)
SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state
FROM stg_customers;

INSERT INTO sellers (seller_id, seller_zip_prefix, seller_city, seller_state)
SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state
FROM stg_sellers;

INSERT INTO category_translation (category_pt, category_en)
SELECT product_category_name, product_category_name_english
FROM stg_category_translation;

-- Two categories have no English name: fall back to the Portuguese one.
INSERT INTO products (product_id, category_pt, category_en, photos_qty, weight_g)
SELECT p.product_id,
       NULLIF(p.product_category_name, ''),
       COALESCE(t.category_en, NULLIF(p.product_category_name, '')),
       CAST(NULLIF(p.product_photos_qty, '') AS UNSIGNED),
       CAST(NULLIF(p.product_weight_g, '')   AS UNSIGNED)
FROM stg_products AS p
LEFT JOIN category_translation AS t ON t.category_pt = p.product_category_name;

-- Three timestamps can be empty. CAST(NULLIF(x, '') AS DATETIME) trips a
-- MySQL quirk (it reads the text as a number), so those use STR_TO_DATE.
INSERT INTO orders (order_id, customer_id, order_status, purchase_ts, approved_ts,
                    carrier_ts, delivered_ts, estimated_date)
SELECT order_id,
       customer_id,
       order_status,
       CAST(order_purchase_timestamp AS DATETIME),
       STR_TO_DATE(NULLIF(order_approved_at, ''),             '%Y-%m-%d %H:%i:%s'),
       STR_TO_DATE(NULLIF(order_delivered_carrier_date, ''),  '%Y-%m-%d %H:%i:%s'),
       STR_TO_DATE(NULLIF(order_delivered_customer_date, ''), '%Y-%m-%d %H:%i:%s'),
       CAST(order_estimated_delivery_date AS DATE)
FROM stg_orders;

INSERT INTO order_items (order_id, order_item_id, product_id, seller_id, shipping_limit_ts, price, freight)
SELECT order_id,
       CAST(order_item_id AS UNSIGNED),
       product_id,
       seller_id,
       CAST(shipping_limit_date AS DATETIME),
       CAST(price AS DECIMAL(10,2)),
       CAST(freight_value AS DECIMAL(10,2))
FROM stg_order_items;

INSERT INTO payments (order_id, payment_sequential, payment_type, installments, payment_value)
SELECT order_id,
       CAST(payment_sequential AS UNSIGNED),
       payment_type,
       CAST(payment_installments AS UNSIGNED),
       CAST(payment_value AS DECIMAL(10,2))
FROM stg_payments;

-- One review per order: the most recently answered one wins.
INSERT INTO reviews (order_id, review_id, review_score, has_comment, review_created,
                     review_answered_ts, reviews_for_order)
SELECT order_id, review_id, review_score, has_comment, review_created, review_answered_ts, reviews_for_order
FROM (
    SELECT order_id,
           review_id,
           CAST(review_score AS UNSIGNED)                AS review_score,
           CASE WHEN review_comment_message = '' THEN 0 ELSE 1 END AS has_comment,
           CAST(review_creation_date    AS DATE)         AS review_created,
           CAST(review_answer_timestamp AS DATETIME)     AS review_answered_ts,
           COUNT(*) OVER (PARTITION BY order_id)         AS reviews_for_order,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY CAST(review_answer_timestamp AS DATETIME) DESC, review_id) AS rn
    FROM stg_reviews
) AS r
WHERE rn = 1;

-- Raw rows against loaded rows. Only reviews should differ.
SELECT 'customers' AS table_name, (SELECT COUNT(*) FROM stg_customers) AS raw_rows, (SELECT COUNT(*) FROM customers) AS loaded_rows, '' AS note
UNION ALL
SELECT 'sellers',     (SELECT COUNT(*) FROM stg_sellers),     (SELECT COUNT(*) FROM sellers),     ''
UNION ALL
SELECT 'products',    (SELECT COUNT(*) FROM stg_products),    (SELECT COUNT(*) FROM products),    ''
UNION ALL
SELECT 'orders',      (SELECT COUNT(*) FROM stg_orders),      (SELECT COUNT(*) FROM orders),      ''
UNION ALL
SELECT 'order_items', (SELECT COUNT(*) FROM stg_order_items), (SELECT COUNT(*) FROM order_items), ''
UNION ALL
SELECT 'payments',    (SELECT COUNT(*) FROM stg_payments),    (SELECT COUNT(*) FROM payments),    ''
UNION ALL
SELECT 'reviews',     (SELECT COUNT(*) FROM stg_reviews),     (SELECT COUNT(*) FROM reviews),     'one per order by design';


-- ---------------------------------------------------------------------
-- 3. Checks on the model
-- ---------------------------------------------------------------------
SELECT 'delivered orders with no delivery date (left out of delivery metrics)' AS check_name, COUNT(*) AS orders_found
FROM orders WHERE order_status = 'delivered' AND delivered_ts IS NULL
UNION ALL
SELECT 'delivered before purchase (bad timestamps, left out)', COUNT(*)
FROM orders WHERE delivered_ts < purchase_ts
UNION ALL
SELECT 'orders with no items', COUNT(*)
FROM orders AS o WHERE NOT EXISTS (SELECT 1 FROM order_items AS i WHERE i.order_id = o.order_id)
UNION ALL
SELECT 'orders with no payment record', COUNT(*)
FROM orders AS o WHERE NOT EXISTS (SELECT 1 FROM payments AS p WHERE p.order_id = o.order_id)
UNION ALL
SELECT 'orders where payments differ from items + freight by more than 1', COUNT(*)
FROM (SELECT order_id, SUM(price + freight) AS billed FROM order_items GROUP BY order_id) AS b
JOIN (SELECT order_id, SUM(payment_value) AS paid FROM payments GROUP BY order_id) AS p
  ON p.order_id = b.order_id
WHERE ABS(b.billed - p.paid) > 1;

-- Overall, do payments cover what was billed?
WITH b AS (SELECT SUM(price + freight) AS billed FROM order_items),
     p AS (SELECT SUM(payment_value)   AS paid   FROM payments)
SELECT b.billed AS items_plus_freight,
       p.paid   AS payments,
       ROUND(100 * (p.paid - b.billed) / b.billed, 2) AS difference_pct
FROM b CROSS JOIN p;
