# Data

The CSV files are not committed to this repository. Download them from Kaggle:

**Brazilian E-Commerce Public Dataset by Olist** — search that name on
[kaggle.com](https://www.kaggle.com), sign in, and click **Download**
(a zip of about 45 MB).

Unzip it and copy these eight files into this folder:

| File | Rows |
|---|---:|
| `olist_orders_dataset.csv` | 99,441 |
| `olist_order_items_dataset.csv` | 112,650 |
| `olist_order_payments_dataset.csv` | 103,886 |
| `olist_order_reviews_dataset.csv` | 99,224 |
| `olist_customers_dataset.csv` | 99,441 |
| `olist_products_dataset.csv` | 32,951 |
| `olist_sellers_dataset.csv` | 3,095 |
| `product_category_name_translation.csv` | 71 |

The ninth file, `olist_geolocation_dataset.csv`, is not used.

If you have the same data from the Scaler *Target Brazil* case study under
different file names, that works too: `scripts/run_mssql.ps1` matches files by
the words in their names (orders, items, payments, reviews, customers,
products, sellers, translation).

Please check the dataset's licence on its Kaggle page before redistributing it.
