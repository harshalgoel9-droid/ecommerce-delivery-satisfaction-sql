/* =============================================================================
   02 -- LOAD THE CSV FILES INTO STAGING                 Microsoft SQL Server
   -----------------------------------------------------------------------------
   Pure T-SQL load, for running from SSMS. scripts\run_mssql.ps1 does the same
   job client-side and needs no server file access -- it is the easier route.

   BULK INSERT reads files as the SQL Server service account, which cannot see
   your user folders. Copy the dataset's CSV files (Kaggle names) to:

       C:\Users\Public\OlistAnalytics\data\          <- default below

   FORMAT = 'CSV' honours quoted fields, including review comments that contain
   commas or line breaks. The geolocation file is not needed and not loaded.
   ============================================================================= */
USE OlistAnalytics;
GO
SET NOCOUNT ON;
GO

DECLARE @data_path NVARCHAR(260) = N'C:\Users\Public\OlistAnalytics\data\';   -- <- edit if needed

DECLARE @files TABLE (load_order INT, target_table NVARCHAR(128), file_name NVARCHAR(200));
INSERT INTO @files VALUES
    (1, N'stg.customers',            N'olist_customers_dataset.csv'),
    (2, N'stg.sellers',              N'olist_sellers_dataset.csv'),
    (3, N'stg.category_translation', N'product_category_name_translation.csv'),
    (4, N'stg.products',             N'olist_products_dataset.csv'),
    (5, N'stg.orders',               N'olist_orders_dataset.csv'),
    (6, N'stg.order_items',          N'olist_order_items_dataset.csv'),
    (7, N'stg.payments',             N'olist_order_payments_dataset.csv'),
    (8, N'stg.reviews',              N'olist_order_reviews_dataset.csv');

DECLARE @table NVARCHAR(128), @file NVARCHAR(200), @sql NVARCHAR(MAX), @msg NVARCHAR(2048);

DECLARE load_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT target_table, file_name FROM @files ORDER BY load_order;
OPEN load_cursor;
FETCH NEXT FROM load_cursor INTO @table, @file;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- BULK INSERT takes only a literal path, so the statement is built dynamically.
    -- ROWTERMINATOR 0x0a accepts both LF and CRLF files; 03 strips any stray CR.
    SET @sql = N'TRUNCATE TABLE ' + @table + N';
BULK INSERT ' + @table + N'
FROM ''' + REPLACE(@data_path + @file, N'''', N'''''') + N'''
WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'',
      CODEPAGE = ''65001'', ROWTERMINATOR = ''0x0a'', TABLOCK);';

    BEGIN TRY
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        SET @msg = CONCAT(N'Loading ', @file, N' failed: ', ERROR_MESSAGE(),
                          N' -- copy the CSV files to ', @data_path,
                          N' (or edit @data_path), or load with scripts\run_mssql.ps1.');
        THROW 50001, @msg, 1;
    END CATCH;

    FETCH NEXT FROM load_cursor INTO @table, @file;
END

CLOSE load_cursor;
DEALLOCATE load_cursor;

PRINT '';
PRINT '=== LOAD CHECK -- rows now in staging ===';
SELECT  f.file_name, f.target_table, c.loaded_rows
FROM @files AS f
JOIN (
    SELECT N'stg.customers'            AS target_table, COUNT(*) AS loaded_rows FROM stg.customers            UNION ALL
    SELECT N'stg.sellers',                              COUNT(*)                FROM stg.sellers              UNION ALL
    SELECT N'stg.category_translation',                 COUNT(*)                FROM stg.category_translation UNION ALL
    SELECT N'stg.products',                             COUNT(*)                FROM stg.products             UNION ALL
    SELECT N'stg.orders',                               COUNT(*)                FROM stg.orders               UNION ALL
    SELECT N'stg.order_items',                          COUNT(*)                FROM stg.order_items          UNION ALL
    SELECT N'stg.payments',                             COUNT(*)                FROM stg.payments             UNION ALL
    SELECT N'stg.reviews',                              COUNT(*)                FROM stg.reviews
) AS c ON c.target_table = f.target_table
ORDER BY f.load_order;
GO
