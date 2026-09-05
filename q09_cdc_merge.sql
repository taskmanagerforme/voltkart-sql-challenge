USE Voltkart;
GO

-- Reset (destructive — snapshot must exist first):
--   SELECT * INTO dim_product_backup FROM dim_product;
--   TRUNCATE TABLE dim_product;
--   INSERT INTO dim_product SELECT * FROM dim_product_backup;


-- Pre-flight
SELECT COUNT(*) AS duplicate_product_ids_in_feed
FROM (SELECT product_id FROM cdc_product_changes GROUP BY product_id HAVING COUNT(*) > 1) d;

SELECT COUNT(*) AS products_before FROM dim_product;

SELECT operation, COUNT(*) AS n
FROM cdc_product_changes
GROUP BY operation ORDER BY operation;


-- Apply the change feed
DROP TABLE IF EXISTS #cdc_log;
CREATE TABLE #cdc_log (
    action_taken NVARCHAR(10),
    product_id   BIGINT,
    old_name     NVARCHAR(255),
    new_name     NVARCHAR(255),
    old_price    DECIMAL(18,2),
    new_price    DECIMAL(18,2)
);

MERGE dim_product AS target
USING cdc_product_changes AS source
    ON target.product_id = source.product_id

WHEN MATCHED AND source.operation = 'U'
    THEN UPDATE SET
        target.product_name = source.product_name,
        target.category_id  = source.category_id,
        target.unit_price   = source.unit_price,
        target.unit_cost    = source.unit_cost,
        target.launch_date  = source.launch_date

WHEN MATCHED AND source.operation = 'D'
    THEN DELETE

WHEN NOT MATCHED BY TARGET AND source.operation = 'I'
    THEN INSERT (product_id, product_name, category_id, unit_price, unit_cost, launch_date)
         VALUES (source.product_id, source.product_name, source.category_id,
                 source.unit_price, source.unit_cost, source.launch_date)

OUTPUT $action,
       ISNULL(inserted.product_id, deleted.product_id),
       deleted.product_name, inserted.product_name,
       deleted.unit_price,   inserted.unit_price
INTO #cdc_log;


-- Verification
SELECT COUNT(*) AS products_after FROM dim_product;

SELECT action_taken, COUNT(*) AS rows_affected
FROM #cdc_log
GROUP BY action_taken;

SELECT product_id, new_name, new_price
FROM #cdc_log WHERE action_taken = 'INSERT' ORDER BY product_id;

SELECT product_id, old_name, new_name, old_price, new_price
FROM #cdc_log WHERE action_taken = 'UPDATE' ORDER BY product_id;

SELECT product_id, old_name, old_price
FROM #cdc_log WHERE action_taken = 'DELETE' ORDER BY product_id;


-- No FKs exist, so the deletes succeed and orphan their line items.
SELECT COUNT(DISTINCT i.product_id) AS deleted_products_still_referenced,
       COUNT(*)                     AS orphaned_order_item_rows
FROM fact_order_items i
WHERE NOT EXISTS (SELECT 1 FROM dim_product p WHERE p.product_id = i.product_id);
GO
