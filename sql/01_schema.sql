-- =====================================================================
-- Olist e-commerce - database and tables
-- MySQL 8.0
-- =====================================================================
-- Run this first, in MySQL Workbench.
-- Run order:  01_schema -> 02_load -> 03_cleaning -> 04_analysis
--
-- Brazilian e-commerce orders, 2016-2018: the public Olist dataset.
--
-- Two sets of tables:
--   stg_*   staging - one table per CSV file, every column plain text,
--           so no row can fail to load because of a bad value
--   the rest        - the model: proper data types, primary and foreign
--           keys. 03_cleaning.sql fills it from staging.
--
-- Re-runnable: the whole database is dropped and recreated.
-- =====================================================================

DROP DATABASE IF EXISTS olist_analytics;
CREATE DATABASE olist_analytics
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_unicode_ci;

USE olist_analytics;


-- =====================================================================
-- STAGING - columns in file order, all text
-- =====================================================================
CREATE TABLE stg_customers (
    customer_id              VARCHAR(64),
    customer_unique_id       VARCHAR(64),
    customer_zip_code_prefix VARCHAR(20),
    customer_city            VARCHAR(200),
    customer_state           VARCHAR(20)
);

CREATE TABLE stg_sellers (
    seller_id              VARCHAR(64),
    seller_zip_code_prefix VARCHAR(20),
    seller_city            VARCHAR(200),
    seller_state           VARCHAR(20)
);

CREATE TABLE stg_category_translation (
    product_category_name         VARCHAR(200),
    product_category_name_english VARCHAR(200)
);

CREATE TABLE stg_products (
    product_id                 VARCHAR(64),
    product_category_name      VARCHAR(200),
    product_name_length        VARCHAR(20),
    product_description_length VARCHAR(20),
    product_photos_qty         VARCHAR(20),
    product_weight_g           VARCHAR(20),
    product_length_cm          VARCHAR(20),
    product_height_cm          VARCHAR(20),
    product_width_cm           VARCHAR(20)
);

CREATE TABLE stg_orders (
    order_id                      VARCHAR(64),
    customer_id                   VARCHAR(64),
    order_status                  VARCHAR(40),
    order_purchase_timestamp      VARCHAR(40),
    order_approved_at             VARCHAR(40),
    order_delivered_carrier_date  VARCHAR(40),
    order_delivered_customer_date VARCHAR(40),
    order_estimated_delivery_date VARCHAR(40)
);

CREATE TABLE stg_order_items (
    order_id            VARCHAR(64),
    order_item_id       VARCHAR(20),
    product_id          VARCHAR(64),
    seller_id           VARCHAR(64),
    shipping_limit_date VARCHAR(40),
    price               VARCHAR(40),
    freight_value       VARCHAR(40)
);

CREATE TABLE stg_payments (
    order_id             VARCHAR(64),
    payment_sequential   VARCHAR(20),
    payment_type         VARCHAR(40),
    payment_installments VARCHAR(20),
    payment_value        VARCHAR(40)
);

CREATE TABLE stg_reviews (
    review_id               VARCHAR(64),
    order_id                VARCHAR(64),
    review_score            VARCHAR(20),
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    VARCHAR(40),
    review_answer_timestamp VARCHAR(40)
);


-- =====================================================================
-- MODEL - typed, keyed, one row per real-world thing
-- =====================================================================
-- Parents are created before the tables whose foreign keys point at them.

-- customer_id is issued per ORDER. The person is customer_unique_id.
CREATE TABLE customers (
    customer_id         CHAR(32)     NOT NULL,
    customer_unique_id  CHAR(32)     NOT NULL,
    customer_zip_prefix CHAR(5)      NULL,
    customer_city       VARCHAR(100) NULL,
    customer_state      CHAR(2)      NULL,
    PRIMARY KEY (customer_id)
);

CREATE TABLE sellers (
    seller_id         CHAR(32)     NOT NULL,
    seller_zip_prefix CHAR(5)      NULL,
    seller_city       VARCHAR(100) NULL,
    seller_state      CHAR(2)      NULL,
    PRIMARY KEY (seller_id)
);

CREATE TABLE category_translation (
    category_pt VARCHAR(100) NOT NULL,
    category_en VARCHAR(100) NOT NULL,
    PRIMARY KEY (category_pt)
);

CREATE TABLE products (
    product_id  CHAR(32)     NOT NULL,
    category_pt VARCHAR(100) NULL,
    category_en VARCHAR(100) NULL,      -- falls back to the Portuguese name
    photos_qty  INT          NULL,
    weight_g    INT          NULL,
    PRIMARY KEY (product_id)
);

CREATE TABLE orders (
    order_id       CHAR(32)    NOT NULL,
    customer_id    CHAR(32)    NOT NULL,
    order_status   VARCHAR(20) NOT NULL,
    purchase_ts    DATETIME    NOT NULL,
    approved_ts    DATETIME    NULL,
    carrier_ts     DATETIME    NULL,    -- handed to the carrier by the seller
    delivered_ts   DATETIME    NULL,    -- received by the customer
    estimated_date DATE        NULL,    -- the date promised at checkout
    PRIMARY KEY (order_id),
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
);

CREATE TABLE order_items (
    order_id          CHAR(32)      NOT NULL,
    order_item_id     INT           NOT NULL,
    product_id        CHAR(32)      NOT NULL,
    seller_id         CHAR(32)      NOT NULL,
    shipping_limit_ts DATETIME      NULL,   -- deadline for the seller to hand over
    price             DECIMAL(10,2) NOT NULL,
    freight           DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id),
    FOREIGN KEY (order_id)   REFERENCES orders (order_id),
    FOREIGN KEY (product_id) REFERENCES products (product_id),
    FOREIGN KEY (seller_id)  REFERENCES sellers (seller_id)
);

CREATE TABLE payments (
    order_id           CHAR(32)      NOT NULL,
    payment_sequential INT           NOT NULL,
    payment_type       VARCHAR(20)   NULL,
    installments       INT           NULL,
    payment_value      DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (order_id, payment_sequential),
    FOREIGN KEY (order_id) REFERENCES orders (order_id)
);

-- One review per order: some orders carry several, 03 keeps the latest.
CREATE TABLE reviews (
    order_id           CHAR(32) NOT NULL,
    review_id          CHAR(32) NOT NULL,
    review_score       TINYINT  NOT NULL,
    has_comment        TINYINT  NOT NULL,   -- 1 if the customer wrote a comment
    review_created     DATE     NULL,
    review_answered_ts DATETIME NULL,
    reviews_for_order  INT      NOT NULL,
    PRIMARY KEY (order_id),
    FOREIGN KEY (order_id) REFERENCES orders (order_id)
);

-- MySQL indexes every foreign key column automatically, so the joins on
-- customer_id, product_id and seller_id need no extra indexes.
