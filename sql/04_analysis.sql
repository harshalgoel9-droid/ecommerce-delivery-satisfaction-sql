/* =============================================================================
   04 -- DELIVERY PERFORMANCE AND CUSTOMER SATISFACTION  Microsoft SQL Server
   -----------------------------------------------------------------------------
   Questions a marketplace operations team would ask -- beyond the standard
   case-study brief:
     Q1  Does a late delivery destroy the review score?
     Q2  Where does freight eat the margin?
     Q3  How many customers ever come back?  (and the customer_id trap)
     Q4  Who are the valuable customers, when almost nobody buys twice?
     Q5  Which categories earn well but disappoint?
     Q6  Is the delivery promise getting better or worse?
     Q7  When an order is late, is it the seller or the carrier?
     Q8  Are late deliveries concentrated in a few sellers?

   "Late" means delivered after the estimated delivery DATE the customer was
   shown at checkout. Delivered on that day counts as on time.
   ============================================================================= */
USE OlistAnalytics;
GO
SET NOCOUNT ON;
GO

-- One row per delivered order: timing against the promise, plus its review.
CREATE OR ALTER VIEW dw.v_order_delivery AS
SELECT  o.order_id,
        c.customer_unique_id,
        c.customer_state,
        o.purchase_ts,
        o.carrier_ts,
        o.delivered_ts,
        o.estimated_date,
        DATEDIFF(DAY, CAST(o.purchase_ts AS DATE), CAST(o.delivered_ts AS DATE))     AS delivery_days,
        DATEDIFF(DAY, o.estimated_date, CAST(o.delivered_ts AS DATE))                AS days_vs_promise,
        CASE WHEN CAST(o.delivered_ts AS DATE) > o.estimated_date THEN 1 ELSE 0 END AS is_late,
        r.review_score
FROM dw.orders         AS o
JOIN dw.customers      AS c ON c.customer_id = o.customer_id
LEFT JOIN dw.reviews   AS r ON r.order_id    = o.order_id
WHERE o.order_status   = 'delivered'
  AND o.delivered_ts   IS NOT NULL
  AND o.estimated_date IS NOT NULL
  AND o.delivered_ts  >= o.purchase_ts;
GO

/* -----------------------------------------------------------------------------
   Q0. The dataset at a glance
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q0. The dataset at a glance ===';
SELECT (SELECT COUNT(*)                            FROM dw.orders)            AS orders,
       (SELECT COUNT(*)                            FROM dw.v_order_delivery)  AS delivered_orders_analysed,
       (SELECT COUNT(DISTINCT customer_unique_id)  FROM dw.customers)         AS customers,
       (SELECT COUNT(*)                            FROM dw.sellers)           AS sellers,
       (SELECT CAST(MIN(purchase_ts) AS DATE)      FROM dw.orders)            AS first_order,
       (SELECT CAST(MAX(purchase_ts) AS DATE)      FROM dw.orders)            AS last_order,
       (SELECT SUM(price)                          FROM dw.order_items)       AS product_revenue,
       (SELECT CAST(AVG(100.0 * is_late) AS DECIMAL(5,1)) FROM dw.v_order_delivery) AS pct_delivered_late;
GO

/* -----------------------------------------------------------------------------
   Q1. Does a late delivery destroy the review score?
   The brief looks at delivery speed. What customers react to is delivery
   against the PROMISE -- the date they were shown at checkout.
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q1. Does a late delivery destroy the review score? ===';
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
    FROM dw.v_order_delivery
    WHERE review_score IS NOT NULL
)
SELECT delivery_bucket,
       COUNT(*)                                                                             AS orders,
       CAST(AVG(1.0 * review_score) AS DECIMAL(4,2))                                        AS avg_review_score,
       CAST(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS pct_1_or_2_stars,
       CAST(100.0 * SUM(CASE WHEN review_score  = 5 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS pct_5_stars
FROM r
GROUP BY delivery_bucket
ORDER BY delivery_bucket;

SELECT CASE WHEN is_late = 1 THEN 'Late' ELSE 'On time or early' END                        AS delivery,
       COUNT(*)                                                                             AS orders,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))                        AS pct_of_orders,
       CAST(AVG(1.0 * review_score) AS DECIMAL(4,2))                                        AS avg_review_score,
       CAST(100.0 * SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,1)) AS pct_1_or_2_stars
FROM dw.v_order_delivery
WHERE review_score IS NOT NULL
GROUP BY CASE WHEN is_late = 1 THEN 'Late' ELSE 'On time or early' END;
GO

/* -----------------------------------------------------------------------------
   Q2. Where does freight eat the margin?
   Average freight per state is the obvious cut. Freight as a SHARE of product
   value is what decides whether a region is worth serving.
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q2. Where does freight eat the margin? (states with 100+ orders) ===';
WITH money AS (
    SELECT  c.customer_state,
            COUNT(DISTINCT o.order_id) AS orders,
            SUM(i.price)               AS product_value,
            SUM(i.freight)             AS freight
    FROM dw.orders      AS o
    JOIN dw.customers   AS c ON c.customer_id = o.customer_id
    JOIN dw.order_items AS i ON i.order_id    = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_state
),
speed AS (
    SELECT  customer_state,
            AVG(1.0 * delivery_days) AS avg_delivery_days,
            AVG(100.0 * is_late)     AS pct_late
    FROM dw.v_order_delivery
    GROUP BY customer_state
)
SELECT  m.customer_state,
        m.orders,
        m.product_value,
        m.freight,
        CAST(100.0 * m.freight / NULLIF(m.product_value, 0) AS DECIMAL(5,1)) AS freight_pct_of_value,
        CAST(s.avg_delivery_days AS DECIMAL(5,1))                            AS avg_delivery_days,
        CAST(s.pct_late AS DECIMAL(5,1))                                     AS pct_late
FROM money      AS m
JOIN speed      AS s ON s.customer_state = m.customer_state
WHERE m.orders >= 100
ORDER BY freight_pct_of_value DESC;
GO

/* -----------------------------------------------------------------------------
   Q3. How many customers ever come back?
   customer_id is issued per ORDER, so counting by it says nobody ever returns.
   The person is customer_unique_id. Both are shown, so the trap is visible.
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q3. Repeat purchase rate -- and the customer_id trap ===';
WITH per_person AS (
    SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS orders
    FROM dw.orders    AS o
    JOIN dw.customers AS c ON c.customer_id = o.customer_id
    GROUP BY c.customer_unique_id
),
per_id AS (
    SELECT customer_id, COUNT(*) AS orders
    FROM dw.orders
    GROUP BY customer_id
)
SELECT 'customer_unique_id (a real person)'  AS counted_by,
       COUNT(*)                                                                         AS customers,
       SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END)                                      AS repeat_customers,
       CAST(100.0 * SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS repeat_rate_pct,
       CAST(AVG(1.0 * orders) AS DECIMAL(6,3))                                          AS avg_orders_per_customer
FROM per_person
UNION ALL
SELECT 'customer_id (one per order -- wrong)',
       COUNT(*),
       SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END),
       CAST(100.0 * SUM(CASE WHEN orders > 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)),
       CAST(AVG(1.0 * orders) AS DECIMAL(6,3))
FROM per_id;
GO

/* -----------------------------------------------------------------------------
   Q4. Who are the valuable customers, when almost nobody buys twice?
   With repeat purchase this rare, Frequency separates almost no one, so the
   segments use Recency and Monetary value -- and repeat buyers get their own.
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q4. Customer segments (recency x spend) ===';
WITH base AS (
    SELECT  c.customer_unique_id,
            MAX(CAST(o.purchase_ts AS DATE)) AS last_order,
            COUNT(DISTINCT o.order_id)       AS frequency,
            SUM(p.payment_value)             AS monetary
    FROM dw.orders    AS o
    JOIN dw.customers AS c ON c.customer_id = o.customer_id
    JOIN dw.payments  AS p ON p.order_id    = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
snap AS (SELECT MAX(last_order) AS as_of FROM base),
scored AS (
    SELECT  b.*,
            DATEDIFF(DAY, b.last_order, s.as_of)                                 AS recency_days,
            NTILE(5) OVER (ORDER BY DATEDIFF(DAY, b.last_order, s.as_of) DESC)   AS r_score,
            NTILE(5) OVER (ORDER BY b.monetary)                                  AS m_score
    FROM base AS b CROSS JOIN snap AS s
),
seg AS (
    SELECT  *,
            CASE WHEN frequency > 1                   THEN '1. Repeat buyers'
                 WHEN r_score >= 4 AND m_score >= 4   THEN '2. Recent high spenders'
                 WHEN r_score <= 2 AND m_score >= 4   THEN '3. Lapsed high spenders'
                 WHEN r_score >= 4                    THEN '4. Recent low spenders'
                 ELSE                                      '5. Other one-time buyers'
            END AS segment
    FROM scored
)
SELECT  segment,
        COUNT(*)                                                                    AS customers,
        CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))              AS pct_customers,
        SUM(monetary)                                                               AS revenue,
        CAST(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER () AS DECIMAL(5,1))    AS pct_revenue,
        CAST(AVG(monetary) AS DECIMAL(10,2))                                        AS avg_spend,
        CAST(AVG(1.0 * recency_days) AS DECIMAL(6,0))                               AS avg_recency_days
FROM seg
GROUP BY segment
ORDER BY segment;
GO

/* -----------------------------------------------------------------------------
   Q5. Which categories earn well but disappoint?
   Revenue and satisfaction side by side. Reviews are counted once per order
   (an order with three items of one category is still one review).
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q5. Top 20 categories by revenue: satisfaction and delivery ===';
WITH delivered_items AS (
    SELECT  i.order_id, i.price, p.category_en
    FROM dw.order_items AS i
    JOIN dw.products    AS p ON p.product_id = i.product_id
    JOIN dw.orders      AS o ON o.order_id   = i.order_id
    WHERE o.order_status = 'delivered' AND p.category_en IS NOT NULL
),
rev AS (
    SELECT category_en, SUM(price) AS revenue
    FROM delivered_items
    GROUP BY category_en
),
sat AS (
    SELECT  co.category_en,
            COUNT(*)                   AS orders,
            AVG(1.0 * d.review_score)  AS avg_review,
            AVG(1.0 * d.delivery_days) AS avg_days,
            AVG(100.0 * d.is_late)     AS pct_late
    FROM (SELECT DISTINCT order_id, category_en FROM delivered_items) AS co
    JOIN dw.v_order_delivery AS d ON d.order_id = co.order_id
    GROUP BY co.category_en
),
overall AS (SELECT AVG(1.0 * review_score) AS avg_all FROM dw.v_order_delivery)
SELECT TOP (20)
        r.category_en,
        s.orders,
        r.revenue,
        CAST(s.avg_review AS DECIMAL(4,2)) AS avg_review_score,
        CAST(s.avg_days   AS DECIMAL(5,1)) AS avg_delivery_days,
        CAST(s.pct_late   AS DECIMAL(5,1)) AS pct_late,
        CASE WHEN s.avg_review < ov.avg_all - 0.10
             THEN 'Watch: earns well, rated below average' ELSE '' END AS flag
FROM rev        AS r
JOIN sat        AS s ON s.category_en = r.category_en
CROSS JOIN overall AS ov
WHERE s.orders >= 200
ORDER BY r.revenue DESC;
GO

/* -----------------------------------------------------------------------------
   Q6. Is the delivery promise getting better or worse?
   A trend on the operational metric, not only on order volume. Months with
   fewer than 100 delivered orders (the thin start and end) are left out.
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q6. Delivery performance by month of purchase ===';
SELECT  CAST(DATETRUNC(MONTH, purchase_ts) AS DATE)                   AS order_month,
        COUNT(*)                                         AS delivered_orders,
        CAST(AVG(1.0 * delivery_days)   AS DECIMAL(5,1)) AS avg_delivery_days,
        CAST(AVG(1.0 * days_vs_promise) AS DECIMAL(5,1)) AS avg_days_vs_promise,
        CAST(AVG(100.0 * is_late)       AS DECIMAL(5,1)) AS pct_late,
        CAST(AVG(1.0 * review_score)    AS DECIMAL(4,2)) AS avg_review_score
FROM dw.v_order_delivery
GROUP BY DATETRUNC(MONTH, purchase_ts)
HAVING COUNT(*) >= 100
ORDER BY order_month;
GO

/* -----------------------------------------------------------------------------
   Q7. When an order is late, is it the seller or the carrier?
   Each item has a deadline for the seller to hand it to the carrier
   (shipping_limit_date). Compare the actual hand-over with that deadline.
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q7. Late orders: seller hand-over vs transit ===';
WITH deadline AS (
    SELECT order_id, MAX(shipping_limit_ts) AS ship_by
    FROM dw.order_items
    GROUP BY order_id
),
late AS (
    SELECT  d.order_id,
            d.days_vs_promise,
            CASE WHEN d.carrier_ts IS NULL OR dl.ship_by IS NULL THEN '3. Unknown -- no hand-over date'
                 WHEN d.carrier_ts > dl.ship_by                   THEN '1. Seller handed over late'
                 ELSE                                                   '2. Seller on time -- delay in transit'
            END AS cause
    FROM dw.v_order_delivery AS d
    JOIN deadline            AS dl ON dl.order_id = d.order_id
    WHERE d.is_late = 1
)
SELECT  cause,
        COUNT(*)                                                        AS late_orders,
        CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))  AS pct_of_late_orders,
        CAST(AVG(1.0 * days_vs_promise) AS DECIMAL(5,1))                AS avg_days_late
FROM late
GROUP BY cause
ORDER BY cause;
GO

/* -----------------------------------------------------------------------------
   Q8. Are late deliveries concentrated in a few sellers?
   Only single-seller orders, so every late order has one clear owner.
   ----------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Q8. Late deliveries by seller ===';
WITH single_seller AS (
    SELECT order_id, MIN(seller_id) AS seller_id
    FROM dw.order_items
    GROUP BY order_id
    HAVING COUNT(DISTINCT seller_id) = 1
)
SELECT  s.seller_id,
        COUNT(*)       AS orders,
        SUM(d.is_late) AS late_orders
INTO #per_seller
FROM single_seller       AS s
JOIN dw.v_order_delivery AS d ON d.order_id = s.order_id
GROUP BY s.seller_id;

WITH ranked AS (
    SELECT  *,
            SUM(late_orders) OVER (ORDER BY late_orders DESC, seller_id ROWS UNBOUNDED PRECEDING) AS cum_late,
            SUM(late_orders) OVER ()                                                             AS total_late,
            COUNT(*)         OVER ()                                                             AS sellers
    FROM #per_seller
)
SELECT  MAX(sellers)                                                              AS sellers_with_delivered_orders,
        MAX(total_late)                                                           AS late_orders,
        SUM(CASE WHEN late_orders > 0 THEN 1 ELSE 0 END)                          AS sellers_with_any_late_order,
        SUM(CASE WHEN cum_late - late_orders < 0.5 * total_late THEN 1 ELSE 0 END) AS sellers_causing_half_of_late_orders,
        CAST(100.0 * SUM(CASE WHEN cum_late - late_orders < 0.5 * total_late THEN 1 ELSE 0 END)
             / MAX(sellers) AS DECIMAL(5,1))                                      AS pct_of_sellers
FROM ranked;

SELECT TOP (10)
        seller_id,
        orders,
        late_orders,
        CAST(100.0 * late_orders / orders AS DECIMAL(5,1)) AS pct_late
FROM #per_seller
WHERE orders >= 50
ORDER BY pct_late DESC, orders DESC;

DROP TABLE #per_seller;
GO
