/* =============================================================================
   03 -- PROFILE, CLEAN AND LOAD THE MODEL               Microsoft SQL Server
   -----------------------------------------------------------------------------
   The traps in this dataset, each counted in section 1 and handled in 2:
     - customer_id is one per ORDER; the real person is customer_unique_id
     - some orders have more than one review      -> keep the latest per order
     - some products have no category, and some categories no English name
     - 'delivered' orders with no delivery date    -> left out of delivery metrics
     - numbers exported as text ('1.0'), timestamps with or without 'T' / 'UTC'

   Every id is CAST to CHAR(32) before it is compared with the model. Comparing
   the NVARCHAR staging text with a CHAR(32) key forces a conversion on every row,
   which stops SQL Server using the index -- a first run of this script spent
   ten minutes on the orders load for exactly that reason.

   Re-runnable on its own: the model tables are emptied first.
   ============================================================================= */
USE OlistAnalytics;
GO
SET NOCOUNT ON;
GO

/* ---- 0. strip stray carriage returns from each file's last column ---------- */
-- A CRLF file loaded with an LF row terminator leaves CHAR(13) on the last field.
UPDATE stg.customers            SET customer_state                = TRIM(CHAR(13) + CHAR(10) + ' ' FROM customer_state);
UPDATE stg.sellers              SET seller_state                  = TRIM(CHAR(13) + CHAR(10) + ' ' FROM seller_state);
UPDATE stg.category_translation SET product_category_name_english = TRIM(CHAR(13) + CHAR(10) + ' ' FROM product_category_name_english);
UPDATE stg.products             SET product_width_cm              = TRIM(CHAR(13) + CHAR(10) + ' ' FROM product_width_cm);
UPDATE stg.orders               SET order_estimated_delivery_date = TRIM(CHAR(13) + CHAR(10) + ' ' FROM order_estimated_delivery_date);
UPDATE stg.order_items          SET freight_value                 = TRIM(CHAR(13) + CHAR(10) + ' ' FROM freight_value);
UPDATE stg.payments             SET payment_value                 = TRIM(CHAR(13) + CHAR(10) + ' ' FROM payment_value);
UPDATE stg.reviews              SET review_answer_timestamp       = TRIM(CHAR(13) + CHAR(10) + ' ' FROM review_answer_timestamp);
GO

/* ---- 1. Profile the raw data before touching it ----------------------------- */
PRINT '';
PRINT '=== 1. DATA-QUALITY PROFILE (raw files) ===';

SELECT 'orders'      AS [file], COUNT(*) AS [rows] FROM stg.orders       UNION ALL
SELECT 'order_items',           COUNT(*)           FROM stg.order_items  UNION ALL
SELECT 'payments',              COUNT(*)           FROM stg.payments     UNION ALL
SELECT 'reviews',               COUNT(*)           FROM stg.reviews      UNION ALL
SELECT 'customers',             COUNT(*)           FROM stg.customers    UNION ALL
SELECT 'products',              COUNT(*)           FROM stg.products     UNION ALL
SELECT 'sellers',               COUNT(*)           FROM stg.sellers      UNION ALL
SELECT 'category_translation',  COUNT(*)           FROM stg.category_translation;

SELECT 'people with more than one customer_id' AS [check], COUNT(*) AS [count]
FROM (SELECT customer_unique_id FROM stg.customers GROUP BY customer_unique_id HAVING COUNT(*) > 1) AS x
UNION ALL
SELECT 'orders with more than one review', COUNT(*)
FROM (SELECT order_id FROM stg.reviews GROUP BY order_id HAVING COUNT(*) > 1) AS x
UNION ALL
SELECT 'review ids reused across orders', COUNT(*)
FROM (SELECT review_id FROM stg.reviews GROUP BY review_id HAVING COUNT(DISTINCT order_id) > 1) AS x
UNION ALL
SELECT 'products with no category', COUNT(*)
FROM stg.products WHERE NULLIF(TRIM(product_category_name), '') IS NULL
UNION ALL
SELECT 'categories with no English name', COUNT(*)
FROM (SELECT DISTINCT TRIM(p.product_category_name) AS c
      FROM stg.products AS p
      WHERE NULLIF(TRIM(p.product_category_name), '') IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM stg.category_translation AS t
                        WHERE TRIM(t.product_category_name) = TRIM(p.product_category_name))) AS x
UNION ALL
SELECT 'delivered orders with no delivery date', COUNT(*)
FROM stg.orders
WHERE LOWER(TRIM(order_status)) = 'delivered'
  AND NULLIF(TRIM(order_delivered_customer_date), '') IS NULL;
GO

/* ---- 2. Load the model: typed, de-duplicated, keys enforced ----------------- */
PRINT '';
PRINT '=== 2. LOAD THE MODEL ===';

-- Empty the model, children before parents (foreign keys rule out TRUNCATE).
DELETE FROM dw.reviews;
DELETE FROM dw.payments;
DELETE FROM dw.order_items;
DELETE FROM dw.orders;
DELETE FROM dw.products;
DELETE FROM dw.category_translation;
DELETE FROM dw.sellers;
DELETE FROM dw.customers;

INSERT INTO dw.customers (customer_id, customer_unique_id, customer_zip_prefix, customer_city, customer_state)
SELECT customer_id, customer_unique_id, zip, city, st
FROM (
    SELECT CAST(TRIM(customer_id)        AS CHAR(32))         AS customer_id,
           CAST(TRIM(customer_unique_id) AS CHAR(32))         AS customer_unique_id,
           RIGHT('00000' + TRIM(customer_zip_code_prefix), 5) AS zip,       -- leading zeros lost in export
           TRIM(customer_city)                                AS city,
           LEFT(TRIM(customer_state), 2)                      AS st,
           ROW_NUMBER() OVER (PARTITION BY TRIM(customer_id) ORDER BY (SELECT NULL)) AS rn
    FROM stg.customers
    WHERE LEN(TRIM(customer_id)) = 32 AND LEN(TRIM(customer_unique_id)) = 32
) AS x
WHERE rn = 1;

INSERT INTO dw.sellers (seller_id, seller_zip_prefix, seller_city, seller_state)
SELECT seller_id, zip, city, st
FROM (
    SELECT CAST(TRIM(seller_id) AS CHAR(32))                AS seller_id,
           RIGHT('00000' + TRIM(seller_zip_code_prefix), 5) AS zip,
           TRIM(seller_city)                                AS city,
           LEFT(TRIM(seller_state), 2)                      AS st,
           ROW_NUMBER() OVER (PARTITION BY TRIM(seller_id) ORDER BY (SELECT NULL)) AS rn
    FROM stg.sellers
    WHERE LEN(TRIM(seller_id)) = 32
) AS x
WHERE rn = 1;

INSERT INTO dw.category_translation (category_pt, category_en)
SELECT pt, en
FROM (
    SELECT TRIM(product_category_name)         AS pt,
           TRIM(product_category_name_english) AS en,
           ROW_NUMBER() OVER (PARTITION BY TRIM(product_category_name) ORDER BY (SELECT NULL)) AS rn
    FROM stg.category_translation
    WHERE NULLIF(TRIM(product_category_name), '') IS NOT NULL
      AND NULLIF(TRIM(product_category_name_english), '') IS NOT NULL
) AS x
WHERE rn = 1;

INSERT INTO dw.products (product_id, category_pt, category_en, photos_qty, weight_g)
SELECT p.product_id, p.category_pt, COALESCE(t.category_en, p.category_pt), p.photos_qty, p.weight_g
FROM (
    SELECT CAST(TRIM(product_id) AS CHAR(32))                                    AS product_id,
           CAST(NULLIF(TRIM(product_category_name), '') AS NVARCHAR(100))        AS category_pt,
           -- exported as '1.0': go through FLOAT, then INT
           CAST(TRY_CAST(NULLIF(TRIM(product_photos_qty), '') AS FLOAT) AS INT)  AS photos_qty,
           CAST(TRY_CAST(NULLIF(TRIM(product_weight_g),   '') AS FLOAT) AS INT)  AS weight_g,
           ROW_NUMBER() OVER (PARTITION BY TRIM(product_id) ORDER BY (SELECT NULL)) AS rn
    FROM stg.products
    WHERE LEN(TRIM(product_id)) = 32
) AS p
LEFT JOIN dw.category_translation AS t ON t.category_pt = p.category_pt
WHERE p.rn = 1;

-- Timestamps: NULLIF first (an empty string would convert to 1900-01-01),
-- 'T' -> ' ' and LEFT(19) cope with ISO and 'UTC'-suffixed exports.
INSERT INTO dw.orders (order_id, customer_id, order_status, purchase_ts, approved_ts,
                       carrier_ts, delivered_ts, estimated_date)
SELECT o.order_id, o.customer_id, o.order_status, o.purchase_ts, o.approved_ts,
       o.carrier_ts, o.delivered_ts, o.estimated_date
FROM (
    SELECT CAST(TRIM(order_id)    AS CHAR(32)) AS order_id,
           CAST(TRIM(customer_id) AS CHAR(32)) AS customer_id,
           LOWER(TRIM(order_status))           AS order_status,
           TRY_CONVERT(DATETIME2(0), LEFT(REPLACE(NULLIF(TRIM(order_purchase_timestamp),      ''), 'T', ' '), 19), 120) AS purchase_ts,
           TRY_CONVERT(DATETIME2(0), LEFT(REPLACE(NULLIF(TRIM(order_approved_at),             ''), 'T', ' '), 19), 120) AS approved_ts,
           TRY_CONVERT(DATETIME2(0), LEFT(REPLACE(NULLIF(TRIM(order_delivered_carrier_date),  ''), 'T', ' '), 19), 120) AS carrier_ts,
           TRY_CONVERT(DATETIME2(0), LEFT(REPLACE(NULLIF(TRIM(order_delivered_customer_date), ''), 'T', ' '), 19), 120) AS delivered_ts,
           TRY_CONVERT(DATE, LEFT(NULLIF(TRIM(order_estimated_delivery_date), ''), 10), 23)                           AS estimated_date,
           ROW_NUMBER() OVER (PARTITION BY TRIM(order_id) ORDER BY (SELECT NULL)) AS rn
    FROM stg.orders
    WHERE LEN(TRIM(order_id)) = 32 AND LEN(TRIM(customer_id)) = 32
) AS o
WHERE o.rn = 1
  AND o.purchase_ts IS NOT NULL
  AND EXISTS (SELECT 1 FROM dw.customers AS c WHERE c.customer_id = o.customer_id);

INSERT INTO dw.order_items (order_id, order_item_id, product_id, seller_id, shipping_limit_ts, price, freight)
SELECT i.order_id, i.order_item_id, i.product_id, i.seller_id, i.shipping_limit_ts, i.price, i.freight
FROM (
    SELECT CAST(TRIM(order_id)   AS CHAR(32))                         AS order_id,
           TRY_CAST(NULLIF(TRIM(order_item_id), '') AS INT)           AS order_item_id,
           CAST(TRIM(product_id) AS CHAR(32))                         AS product_id,
           CAST(TRIM(seller_id)  AS CHAR(32))                         AS seller_id,
           TRY_CONVERT(DATETIME2(0), LEFT(REPLACE(NULLIF(TRIM(shipping_limit_date), ''), 'T', ' '), 19), 120) AS shipping_limit_ts,
           TRY_CAST(NULLIF(TRIM(price), '')         AS DECIMAL(10,2)) AS price,
           TRY_CAST(NULLIF(TRIM(freight_value), '') AS DECIMAL(10,2)) AS freight,
           ROW_NUMBER() OVER (PARTITION BY TRIM(order_id), TRIM(order_item_id) ORDER BY (SELECT NULL)) AS rn
    FROM stg.order_items
    WHERE LEN(TRIM(order_id)) = 32 AND LEN(TRIM(product_id)) = 32 AND LEN(TRIM(seller_id)) = 32
) AS i
WHERE i.rn = 1
  AND i.order_item_id IS NOT NULL AND i.price IS NOT NULL AND i.freight IS NOT NULL
  AND EXISTS (SELECT 1 FROM dw.orders   AS o WHERE o.order_id   = i.order_id)
  AND EXISTS (SELECT 1 FROM dw.products AS p WHERE p.product_id = i.product_id)
  AND EXISTS (SELECT 1 FROM dw.sellers  AS s WHERE s.seller_id  = i.seller_id);

INSERT INTO dw.payments (order_id, payment_sequential, payment_type, installments, payment_value)
SELECT p.order_id, p.seq, p.ptype, p.inst, p.val
FROM (
    SELECT CAST(TRIM(order_id) AS CHAR(32))                           AS order_id,
           TRY_CAST(NULLIF(TRIM(payment_sequential), '')   AS INT)    AS seq,
           CAST(TRIM(payment_type) AS NVARCHAR(20))                   AS ptype,
           TRY_CAST(NULLIF(TRIM(payment_installments), '') AS INT)    AS inst,
           TRY_CAST(NULLIF(TRIM(payment_value), '') AS DECIMAL(10,2)) AS val,
           ROW_NUMBER() OVER (PARTITION BY TRIM(order_id), TRIM(payment_sequential) ORDER BY (SELECT NULL)) AS rn
    FROM stg.payments
    WHERE LEN(TRIM(order_id)) = 32
) AS p
WHERE p.rn = 1 AND p.seq IS NOT NULL AND p.val IS NOT NULL
  AND EXISTS (SELECT 1 FROM dw.orders AS o WHERE o.order_id = p.order_id);

-- One review per order: the most recently answered one wins.
INSERT INTO dw.reviews (order_id, review_id, review_score, has_comment, review_created,
                        review_answered_ts, reviews_for_order)
SELECT x.order_id, x.review_id, x.score, x.has_comment, x.created, x.answered, x.n
FROM (
    SELECT CAST(TRIM(r.order_id)  AS CHAR(32))                      AS order_id,
           CAST(TRIM(r.review_id) AS CHAR(32))                      AS review_id,
           TRY_CAST(NULLIF(TRIM(r.review_score), '') AS TINYINT)    AS score,
           CASE WHEN NULLIF(TRIM(r.review_comment_message), '') IS NULL THEN 0 ELSE 1 END AS has_comment,
           TRY_CONVERT(DATE, LEFT(NULLIF(TRIM(r.review_creation_date), ''), 10), 23)       AS created,
           TRY_CONVERT(DATETIME2(0), LEFT(REPLACE(NULLIF(TRIM(r.review_answer_timestamp), ''), 'T', ' '), 19), 120) AS answered,
           COUNT(*) OVER (PARTITION BY TRIM(r.order_id))            AS n,
           ROW_NUMBER() OVER (PARTITION BY TRIM(r.order_id)
                              ORDER BY TRY_CONVERT(DATETIME2(0), LEFT(REPLACE(NULLIF(TRIM(r.review_answer_timestamp), ''), 'T', ' '), 19), 120) DESC,
                                       TRIM(r.review_id)) AS rn
    FROM stg.reviews AS r
    WHERE LEN(TRIM(r.order_id)) = 32 AND LEN(TRIM(r.review_id)) = 32
) AS x
WHERE x.rn = 1
  AND x.score BETWEEN 1 AND 5
  AND EXISTS (SELECT 1 FROM dw.orders AS o WHERE o.order_id = x.order_id);

SELECT t.[table], t.raw_rows, t.loaded_rows, t.raw_rows - t.loaded_rows AS not_loaded, t.note
FROM (VALUES
    ('customers',   (SELECT COUNT(*) FROM stg.customers),   (SELECT COUNT(*) FROM dw.customers),   ''),
    ('sellers',     (SELECT COUNT(*) FROM stg.sellers),     (SELECT COUNT(*) FROM dw.sellers),     ''),
    ('products',    (SELECT COUNT(*) FROM stg.products),    (SELECT COUNT(*) FROM dw.products),    ''),
    ('orders',      (SELECT COUNT(*) FROM stg.orders),      (SELECT COUNT(*) FROM dw.orders),      ''),
    ('order_items', (SELECT COUNT(*) FROM stg.order_items), (SELECT COUNT(*) FROM dw.order_items), ''),
    ('payments',    (SELECT COUNT(*) FROM stg.payments),    (SELECT COUNT(*) FROM dw.payments),    ''),
    ('reviews',     (SELECT COUNT(*) FROM stg.reviews),     (SELECT COUNT(*) FROM dw.reviews),     'one per order by design')
) AS t ([table], raw_rows, loaded_rows, note);
GO

/* ---- 3. Checks on the model ------------------------------------------------- */
PRINT '';
PRINT '=== 3. CHECKS ON THE MODEL ===';

SELECT 'delivered orders with no delivery date (left out of delivery metrics)' AS [check], COUNT(*) AS [orders]
FROM dw.orders WHERE order_status = 'delivered' AND delivered_ts IS NULL
UNION ALL
SELECT 'delivered before purchase (bad timestamps, left out)', COUNT(*)
FROM dw.orders WHERE delivered_ts < purchase_ts
UNION ALL
SELECT 'orders with no items', COUNT(*)
FROM dw.orders AS o WHERE NOT EXISTS (SELECT 1 FROM dw.order_items AS i WHERE i.order_id = o.order_id)
UNION ALL
SELECT 'orders with no payment record', COUNT(*)
FROM dw.orders AS o WHERE NOT EXISTS (SELECT 1 FROM dw.payments AS p WHERE p.order_id = o.order_id)
UNION ALL
SELECT 'orders where payments differ from items + freight by more than 1', COUNT(*)
FROM (SELECT order_id, SUM(price + freight) AS billed FROM dw.order_items GROUP BY order_id) AS b
JOIN (SELECT order_id, SUM(payment_value) AS paid FROM dw.payments GROUP BY order_id) AS p
  ON p.order_id = b.order_id
WHERE ABS(b.billed - p.paid) > 1;

-- Overall, do payments cover what was billed?
WITH b AS (SELECT SUM(price + freight) AS billed FROM dw.order_items),
     p AS (SELECT SUM(payment_value)   AS paid   FROM dw.payments)
SELECT b.billed AS items_plus_freight,
       p.paid   AS payments,
       CAST(100.0 * (p.paid - b.billed) / b.billed AS DECIMAL(6,2)) AS difference_pct
FROM b CROSS JOIN p;
GO
