/* =============================================================================
   01 -- DATABASE, STAGING AND MODEL                     Microsoft SQL Server
   -----------------------------------------------------------------------------
   Brazilian e-commerce orders, 2016-2018: the public Olist dataset, which is
   also the data behind the Scaler "Target Brazil" SQL case study.
   Requires SQL Server 2022 or later (DATETRUNC, TRIM ... FROM).

   Re-runnable: every object is dropped and recreated.
   Run order:  01_schema -> 02_load -> 03_cleaning -> 04_analysis
   ============================================================================= */

IF DB_ID(N'OlistAnalytics') IS NULL
    CREATE DATABASE OlistAnalytics;
GO

IF (SELECT compatibility_level FROM sys.databases WHERE name = N'OlistAnalytics') < 160
    ALTER DATABASE OlistAnalytics SET COMPATIBILITY_LEVEL = 160;
GO

-- A rebuildable analysis database needs no point-in-time restore, so use the
-- SIMPLE recovery model: bulk loads are minimally logged and the log stays small.
ALTER DATABASE OlistAnalytics SET RECOVERY SIMPLE;
GO

USE OlistAnalytics;
GO
SET NOCOUNT ON;
GO

/* ---- tear down, dependants first ------------------------------------------ */
DROP VIEW  IF EXISTS dw.v_order_delivery;
DROP TABLE IF EXISTS dw.order_items, dw.payments, dw.reviews, dw.orders,
                     dw.products, dw.category_translation, dw.sellers, dw.customers;
DROP TABLE IF EXISTS stg.order_items, stg.payments, stg.reviews, stg.orders,
                     stg.products, stg.category_translation, stg.sellers, stg.customers;
GO

IF SCHEMA_ID(N'stg') IS NULL EXEC (N'CREATE SCHEMA stg');
IF SCHEMA_ID(N'dw')  IS NULL EXEC (N'CREATE SCHEMA dw');
GO

/* =============================================================================
   STAGING -- untyped, one table per CSV, columns in file order.
   A bad value must never abort the load; it is typed and counted in 03.
   ============================================================================= */
CREATE TABLE stg.customers (
    customer_id              NVARCHAR(64),
    customer_unique_id       NVARCHAR(64),
    customer_zip_code_prefix NVARCHAR(20),
    customer_city            NVARCHAR(200),
    customer_state           NVARCHAR(20)
);

CREATE TABLE stg.sellers (
    seller_id              NVARCHAR(64),
    seller_zip_code_prefix NVARCHAR(20),
    seller_city            NVARCHAR(200),
    seller_state           NVARCHAR(20)
);

CREATE TABLE stg.category_translation (
    product_category_name         NVARCHAR(200),
    product_category_name_english NVARCHAR(200)
);

CREATE TABLE stg.products (
    product_id                 NVARCHAR(64),
    product_category_name      NVARCHAR(200),
    product_name_length        NVARCHAR(20),
    product_description_length NVARCHAR(20),
    product_photos_qty         NVARCHAR(20),
    product_weight_g           NVARCHAR(20),
    product_length_cm          NVARCHAR(20),
    product_height_cm          NVARCHAR(20),
    product_width_cm           NVARCHAR(20)
);

CREATE TABLE stg.orders (
    order_id                      NVARCHAR(64),
    customer_id                   NVARCHAR(64),
    order_status                  NVARCHAR(40),
    order_purchase_timestamp      NVARCHAR(40),
    order_approved_at             NVARCHAR(40),
    order_delivered_carrier_date  NVARCHAR(40),
    order_delivered_customer_date NVARCHAR(40),
    order_estimated_delivery_date NVARCHAR(40)
);

CREATE TABLE stg.order_items (
    order_id            NVARCHAR(64),
    order_item_id       NVARCHAR(20),
    product_id          NVARCHAR(64),
    seller_id           NVARCHAR(64),
    shipping_limit_date NVARCHAR(40),
    price               NVARCHAR(40),
    freight_value       NVARCHAR(40)
);

CREATE TABLE stg.payments (
    order_id             NVARCHAR(64),
    payment_sequential   NVARCHAR(20),
    payment_type         NVARCHAR(40),
    payment_installments NVARCHAR(20),
    payment_value        NVARCHAR(40)
);

CREATE TABLE stg.reviews (
    review_id               NVARCHAR(64),
    order_id                NVARCHAR(64),
    review_score            NVARCHAR(20),
    review_comment_title    NVARCHAR(MAX),
    review_comment_message  NVARCHAR(MAX),
    review_creation_date    NVARCHAR(40),
    review_answer_timestamp NVARCHAR(40)
);
GO

/* =============================================================================
   MODEL -- typed, keyed, one row per real-world thing
   ============================================================================= */
-- customer_id is issued per ORDER. The person is customer_unique_id.
CREATE TABLE dw.customers (
    customer_id         CHAR(32)      NOT NULL PRIMARY KEY,
    customer_unique_id  CHAR(32)      NOT NULL,
    customer_zip_prefix CHAR(5)       NULL,
    customer_city       NVARCHAR(100) NULL,
    customer_state      CHAR(2)       NULL
);

CREATE TABLE dw.sellers (
    seller_id         CHAR(32)      NOT NULL PRIMARY KEY,
    seller_zip_prefix CHAR(5)       NULL,
    seller_city       NVARCHAR(100) NULL,
    seller_state      CHAR(2)       NULL
);

CREATE TABLE dw.category_translation (
    category_pt NVARCHAR(100) NOT NULL PRIMARY KEY,
    category_en NVARCHAR(100) NOT NULL
);

CREATE TABLE dw.products (
    product_id  CHAR(32)      NOT NULL PRIMARY KEY,
    category_pt NVARCHAR(100) NULL,
    category_en NVARCHAR(100) NULL,     -- falls back to the Portuguese name
    photos_qty  INT           NULL,
    weight_g    INT           NULL
);

CREATE TABLE dw.orders (
    order_id       CHAR(32)     NOT NULL PRIMARY KEY,
    customer_id    CHAR(32)     NOT NULL REFERENCES dw.customers (customer_id),
    order_status   NVARCHAR(20) NOT NULL,
    purchase_ts    DATETIME2(0) NOT NULL,
    approved_ts    DATETIME2(0) NULL,
    carrier_ts     DATETIME2(0) NULL,      -- handed to the carrier by the seller
    delivered_ts   DATETIME2(0) NULL,      -- received by the customer
    estimated_date DATE         NULL       -- the date promised at checkout
);

CREATE TABLE dw.order_items (
    order_id          CHAR(32)      NOT NULL REFERENCES dw.orders (order_id),
    order_item_id     INT           NOT NULL,
    product_id        CHAR(32)      NOT NULL REFERENCES dw.products (product_id),
    seller_id         CHAR(32)      NOT NULL REFERENCES dw.sellers (seller_id),
    shipping_limit_ts DATETIME2(0)  NULL,  -- deadline for the seller to hand over
    price             DECIMAL(10,2) NOT NULL,
    freight           DECIMAL(10,2) NOT NULL,
    CONSTRAINT pk_order_items PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE dw.payments (
    order_id           CHAR(32)      NOT NULL REFERENCES dw.orders (order_id),
    payment_sequential INT           NOT NULL,
    payment_type       NVARCHAR(20)  NULL,
    installments       INT           NULL,
    payment_value      DECIMAL(10,2) NOT NULL,
    CONSTRAINT pk_payments PRIMARY KEY (order_id, payment_sequential)
);

-- One review per order: some orders carry several, 03 keeps the latest.
CREATE TABLE dw.reviews (
    order_id           CHAR(32)     NOT NULL PRIMARY KEY REFERENCES dw.orders (order_id),
    review_id          CHAR(32)     NOT NULL,
    review_score       TINYINT      NOT NULL,
    has_comment        BIT          NOT NULL,
    review_created     DATE         NULL,
    review_answered_ts DATETIME2(0) NULL,
    reviews_for_order  INT          NOT NULL
);

CREATE INDEX ix_orders_customer ON dw.orders (customer_id);
CREATE INDEX ix_items_seller    ON dw.order_items (seller_id);
CREATE INDEX ix_items_product   ON dw.order_items (product_id);
GO

PRINT 'Schema created.';
GO
