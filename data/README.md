# Data

The CSV files are not committed to this repository. Download them from Kaggle:

**Brazilian E-Commerce Public Dataset by Olist**. Search for that name on
[kaggle.com](https://www.kaggle.com), sign in, and click **Download**
(a zip of about 45 MB).

Unzip it and keep these eight files in this folder. Then copy them into the
MySQL upload folder, where [`sql/02_load.sql`](../sql/02_load.sql) reads them
from (see the comments at the top of that file). The row counts below are what
its check at the end should show.

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

The scripts were tested on the Kaggle files. Copies from elsewhere, such as the
Scaler *Target Brazil* case study, may use different file names or formats.

Please check the dataset's licence on its Kaggle page before redistributing it.
