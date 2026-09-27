-- =====================================================================
-- Delivery performance and customer satisfaction
-- MySQL 8.0
-- =====================================================================
-- Run this after 03_cleaning.sql.
--
-- Eight questions about delivery and customer satisfaction:
--   Q1  Does a late delivery hurt the review score?
--   Q2  Where does freight eat the margin?
--   Q3  How many customers ever come back?  (and the customer_id trap)
--   Q4  Who are the valuable customers, when almost nobody buys twice?
--   Q5  Which categories earn well but get poor ratings?
--   Q6  Is delivery against the promise getting better or worse?
--   Q7  When an order is late, is it the seller or the carrier?
--   Q8  Are late deliveries concentrated in a few sellers?
--
-- "Late" means delivered after the estimated delivery DATE the customer
-- was shown at checkout. Delivered on that day counts as on time.
-- =====================================================================

USE olist_analytics;


-- One row per delivered order: timing against the promise, plus its review.
CREATE OR REPLACE VIEW v_order_delivery AS
SELECT  o.order_id,
        c.customer_unique_id,
        c.customer_state,
        o.purchase_ts,
        o.carrier_ts,
        o.delivered_ts,
        o.estimated_date,
        DATEDIFF(o.delivered_ts, o.purchase_ts)                           AS delivery_days,
        DATEDIFF(o.delivered_ts, o.estimated_date)                        AS days_vs_promise,
        CASE WHEN DATE(o.delivered_ts) > o.estimated_date THEN 1 ELSE 0 END AS is_late,
        r.review_score
FROM orders         AS o
JOIN customers      AS c ON c.customer_id = o.customer_id
LEFT JOIN reviews   AS r ON r.order_id    = o.order_id
WHERE o.order_status   = 'delivered'
  AND o.delivered_ts   IS NOT NULL
  AND o.estimated_date IS NOT NULL
  AND o.delivered_ts  >= o.purchase_ts;


-- ---------------------------------------------------------------------
-- Q0. The dataset at a glance
-- ---------------------------------------------------------------------
SELECT (SELECT COUNT(*)                           FROM orders)           AS orders,
       (SELECT COUNT(*)                           FROM v_order_delivery) AS delivered_orders_analysed,
       (SELECT COUNT(DISTINCT customer_unique_id) FROM customers)        AS customers,
       (SELECT COUNT(*)                           FROM sellers)          AS sellers,
       (SELECT DATE(MIN(purchase_ts))             FROM orders)           AS first_order,
       (SELECT DATE(MAX(purchase_ts))             FROM orders)           AS last_order,
       (SELECT SUM(price)                         FROM order_items)      AS product_revenue,
       (SELECT ROUND(AVG(100 * is_late), 1)       FROM v_order_delivery) AS pct_delivered_late;


-- ---------------------------------------------------------------------
-- Q1. Does a late delivery hurt the review score?
-- Measured against the promised delivery date shown at checkout, not
-- against delivery speed.
-- ---------------------------------------------------------------------
WITH r AS (
    SELECT CASE
               WHEN days_vs_promise <= -11 THEN 'A. Early by 11+ days'
               WHEN days_vs_promise <=  -4 THEN 'B. Early by 4-10 days'
               WHEN days_vs_promise <    0 THEN 'C. Early by 1-3 days'
               WHEN days_vs_promise =    0 THEN 'D. On the promised day'
               WHEN days_vs_promise <=   5 THEN 'E. Late by 1-5 days'
               WHEN days_vs_promise <=  15 THEN 'F. Late by 6-15 days'
               ELSE                              'G. Late by 16+ days'
           END AS delivery_bucket,
           review_score
    FROM v_order_delivery
    WHERE review_score IS NOT NULL
)
SELECT delivery_bucket,
       COUNT(*)                                                               AS orders,
       ROUND(AVG(review_score), 2)                                            AS avg_review_score,
       ROUND(100 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_1_or_2_stars,
       ROUND(100 * SUM(CASE WHEN review_score  = 5 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_5_stars
FROM r
GROUP BY delivery_bucket
ORDER BY delivery_bucket;

SELECT CASE WHEN is_late = 1 THEN 'Late' ELSE 'On time or early' END          AS delivery,
       COUNT(*)                                                               AS orders,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                       AS pct_of_orders,
       ROUND(AVG(review_score), 2)                                            AS avg_review_score,
       ROUND(100 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_1_or_2_stars
FROM v_order_delivery
WHERE review_score IS NOT NULL
GROUP BY delivery;


-- ---------------------------------------------------------------------
-- Q2. Where does freight eat the margin?
-- Average freight per state is the obvious cut. Freight as a SHARE of
-- product value is what decides whether a region is worth serving.
-- ---------------------------------------------------------------------
WITH money AS (
    SELECT  c.customer_state,
            COUNT(DISTINCT o.order_id) AS orders,
            SUM(i.price)               AS product_value,
            SUM(i.freight)             AS freight
    FROM orders      AS o
    JOIN customers   AS c ON c.customer_id = o.customer_id
    JOIN order_items AS i ON i.order_id    = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_state
),
speed AS (
    SELECT  customer_state,
            AVG(delivery_days) AS avg_delivery_days,
            AVG(100 * is_late) AS pct_late
    FROM v_order_delivery
    GROUP BY customer_state
)
SELECT  m.customer_state,
        m.orders,
        m.product_value,
        m.freight,
        ROUND(100 * m.freight / NULLIF(m.product_value, 0), 1) AS freight_pct_of_value,
        ROUND(s.avg_delivery_days, 1)                          AS avg_delivery_days,
        ROUND(s.pct_late, 1)                                   AS pct_late
FROM money AS m
JOIN speed AS s ON s.customer_state = m.customer_state
WHERE m.orders >= 100
ORDER BY freight_pct_of_value DESC;


-- ---------------------------------------------------------------------
-- Q3. How many customers ever come back?
-- customer_id is issued per ORDER, so counting by it says nobody ever
-- returns. The person is customer_unique_id. Both are shown, so the trap
-- is visible.
-- ---------------------------------------------------------------------
WITH per_person AS (
    SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS orders
    FROM orders    AS o
    JOIN customers AS c ON c.customer_id = o.customer_id
    GROUP BY c.customer_unique_id
),
per_id AS (
    SELECT customer_id, COUNT(*) AS orders
    FROM orders
    GROUP BY customer_id
)
SELECT 'customer_unique_id (a real person)'                                   AS counted_by,
       COUNT(*)                                                               AS customers,
       SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END)                            AS repeat_customers,
       ROUND(100 * SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END) / COUNT(*), 2) AS repeat_rate_pct,
       ROUND(AVG(orders), 3)                                                  AS avg_orders_per_customer
FROM per_person
UNION ALL
SELECT 'customer_id (one per order - wrong)',
       COUNT(*),
       SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END),
       ROUND(100 * SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END) / COUNT(*), 2),
       ROUND(AVG(orders), 3)
FROM per_id;


-- ---------------------------------------------------------------------
-- Q4. Who are the valuable customers, when almost nobody buys twice?
-- With repeat purchase this rare, Frequency separates almost no one, so
-- the segments use Recency and Monetary value - and repeat buyers get
-- their own.
-- ---------------------------------------------------------------------
WITH base AS (
    SELECT  c.customer_unique_id,
            MAX(DATE(o.purchase_ts))   AS last_order,
            COUNT(DISTINCT o.order_id) AS frequency,
            SUM(p.payment_value)       AS monetary
    FROM orders    AS o
    JOIN customers AS c ON c.customer_id = o.customer_id
    JOIN payments  AS p ON p.order_id    = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
snap AS (SELECT MAX(last_order) AS as_of FROM base),
-- NTILE splits customers into five equal groups. customer_unique_id breaks
-- ties, so customers with the same value always land in the same group.
scored AS (
    SELECT  b.*,
            DATEDIFF(s.as_of, b.last_order) AS recency_days,
            NTILE(5) OVER (ORDER BY DATEDIFF(s.as_of, b.last_order) DESC, b.customer_unique_id) AS r_score,
            NTILE(5) OVER (ORDER BY b.monetary, b.customer_unique_id)                          AS m_score
    FROM base AS b CROSS JOIN snap AS s
),
seg AS (
    SELECT  *,
            CASE WHEN frequency > 1                 THEN '1. Repeat buyers'
                 WHEN r_score >= 4 AND m_score >= 4 THEN '2. Recent high spenders'
                 WHEN r_score <= 2 AND m_score >= 4 THEN '3. Lapsed high spenders'
                 WHEN r_score >= 4                  THEN '4. Recent low spenders'
                 ELSE                                    '5. Other one-time buyers'
            END AS segment
    FROM scored
)
SELECT  segment,
        COUNT(*)                                                  AS customers,
        ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_customers,
        SUM(monetary)                                             AS revenue,
        ROUND(100 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_revenue,
        ROUND(AVG(monetary), 2)                                   AS avg_spend,
        ROUND(AVG(recency_days), 0)                               AS avg_recency_days
FROM seg
GROUP BY segment
ORDER BY segment;


-- ---------------------------------------------------------------------
-- Q5. Which categories earn well but get poor ratings?
-- Revenue and satisfaction side by side. Reviews are counted once per
-- order (an order with three items of one category is still one review).
-- ---------------------------------------------------------------------
WITH delivered_items AS (
    SELECT  i.order_id, i.price, p.category_en
    FROM order_items AS i
    JOIN products    AS p ON p.product_id = i.product_id
    JOIN orders      AS o ON o.order_id   = i.order_id
    WHERE o.order_status = 'delivered' AND p.category_en IS NOT NULL
),
rev AS (
    SELECT category_en, SUM(price) AS revenue
    FROM delivered_items
    GROUP BY category_en
),
sat AS (
    SELECT  co.category_en,
            COUNT(*)             AS orders,
            AVG(d.review_score)  AS avg_review,
            AVG(d.delivery_days) AS avg_days,
            AVG(100 * d.is_late) AS pct_late
    FROM (SELECT DISTINCT order_id, category_en FROM delivered_items) AS co
    JOIN v_order_delivery AS d ON d.order_id = co.order_id
    GROUP BY co.category_en
),
overall AS (SELECT AVG(review_score) AS avg_all FROM v_order_delivery)
SELECT  r.category_en,
        s.orders,
        r.revenue,
        ROUND(s.avg_review, 2) AS avg_review_score,
        ROUND(s.avg_days, 1)   AS avg_delivery_days,
        ROUND(s.pct_late, 1)   AS pct_late,
        CASE WHEN s.avg_review < ov.avg_all - 0.10
             THEN 'Watch: earns well, rated below average' ELSE '' END AS flag
FROM rev AS r
JOIN sat AS s ON s.category_en = r.category_en
CROSS JOIN overall AS ov
WHERE s.orders >= 200
ORDER BY r.revenue DESC
LIMIT 20;


-- ---------------------------------------------------------------------
-- Q6. Is delivery against the promise getting better or worse?
-- A trend on the operational metric, not only on order volume. Months
-- with fewer than 100 delivered orders (the thin start and end) are
-- left out.
-- ---------------------------------------------------------------------
SELECT  DATE_FORMAT(purchase_ts, '%Y-%m-01') AS order_month,
        COUNT(*)                             AS delivered_orders,
        ROUND(AVG(delivery_days), 1)         AS avg_delivery_days,
        ROUND(AVG(days_vs_promise), 1)       AS avg_days_vs_promise,
        ROUND(AVG(100 * is_late), 1)         AS pct_late,
        ROUND(AVG(review_score), 2)          AS avg_review_score
FROM v_order_delivery
GROUP BY order_month
HAVING COUNT(*) >= 100
ORDER BY order_month;


-- ---------------------------------------------------------------------
-- Q7. When an order is late, is it the seller or the carrier?
-- Each item has a deadline for the seller to hand it to the carrier
-- (shipping_limit_date). Compare the actual hand-over with that deadline.
-- ---------------------------------------------------------------------
WITH deadline AS (
    SELECT order_id, MAX(shipping_limit_ts) AS ship_by
    FROM order_items
    GROUP BY order_id
),
late AS (
    SELECT  d.order_id,
            d.days_vs_promise,
            CASE WHEN d.carrier_ts IS NULL OR dl.ship_by IS NULL THEN '3. Unknown - no hand-over date'
                 WHEN d.carrier_ts > dl.ship_by                   THEN '1. Seller handed over late'
                 ELSE                                                  '2. Seller on time - delay in transit'
            END AS cause
    FROM v_order_delivery AS d
    JOIN deadline         AS dl ON dl.order_id = d.order_id
    WHERE d.is_late = 1
)
SELECT  cause,
        COUNT(*)                                         AS late_orders,
        ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_late_orders,
        ROUND(AVG(days_vs_promise), 1)                   AS avg_days_late
FROM late
GROUP BY cause
ORDER BY cause;


-- ---------------------------------------------------------------------
-- Q8. Are late deliveries concentrated in a few sellers?
-- Only single-seller orders, so every late order has one clear owner.
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS per_seller;

CREATE TEMPORARY TABLE per_seller AS
SELECT  s.seller_id,
        COUNT(*)       AS orders,
        SUM(d.is_late) AS late_orders
FROM (
    SELECT order_id, MIN(seller_id) AS seller_id
    FROM order_items
    GROUP BY order_id
    HAVING COUNT(DISTINCT seller_id) = 1
) AS s
JOIN v_order_delivery AS d ON d.order_id = s.order_id
GROUP BY s.seller_id;

-- Sellers ranked by late orders, with a running total: how many sellers
-- does it take to account for half of all late orders?
WITH ranked AS (
    SELECT  *,
            SUM(late_orders) OVER (ORDER BY late_orders DESC, seller_id ROWS UNBOUNDED PRECEDING) AS cum_late,
            SUM(late_orders) OVER ()                                                             AS total_late,
            COUNT(*)         OVER ()                                                             AS sellers
    FROM per_seller
)
SELECT  MAX(sellers)                                                               AS sellers_with_delivered_orders,
        MAX(total_late)                                                            AS late_orders,
        SUM(CASE WHEN late_orders > 0 THEN 1 ELSE 0 END)                           AS sellers_with_any_late_order,
        SUM(CASE WHEN cum_late - late_orders < 0.5 * total_late THEN 1 ELSE 0 END) AS sellers_causing_half_of_late_orders,
        ROUND(100 * SUM(CASE WHEN cum_late - late_orders < 0.5 * total_late THEN 1 ELSE 0 END)
              / MAX(sellers), 1)                                                   AS pct_of_sellers
FROM ranked;

SELECT  seller_id,
        orders,
        late_orders,
        ROUND(100 * late_orders / orders, 1) AS pct_late
FROM per_seller
WHERE orders >= 50
ORDER BY pct_late DESC, orders DESC
LIMIT 10;

DROP TEMPORARY TABLE per_seller;
