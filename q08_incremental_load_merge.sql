USE Voltkart;
GO

-- Reset (destructive — snapshot must exist first):
--   SELECT * INTO fact_orders_backup FROM fact_orders;
--   TRUNCATE TABLE fact_orders;
--   INSERT INTO fact_orders SELECT * FROM fact_orders_backup;


-- Pre-flight
SELECT COUNT(*) AS duplicate_order_ids_in_source
FROM (SELECT order_id FROM stg_orders_incr GROUP BY order_id HAVING COUNT(*) > 1) d;

SELECT COUNT(*) AS total_initial_orders FROM fact_orders;
SELECT COUNT(*) AS incr_rows            FROM stg_orders_incr;

SELECT COUNT(*) AS orders_to_be_updated
FROM stg_orders_incr inc
WHERE EXISTS (SELECT 1 FROM fact_orders fo WHERE fo.order_id = inc.order_id);

SELECT COUNT(*) AS new_orders
FROM stg_orders_incr inc
WHERE NOT EXISTS (SELECT 1 FROM fact_orders fo WHERE fo.order_id = inc.order_id);


-- Incremental load
DROP TABLE IF EXISTS #merge_log;
CREATE TABLE #merge_log (
    action_taken  NVARCHAR(10),
    order_id      BIGINT,
    old_status    NVARCHAR(255),
    new_status    NVARCHAR(255),
    old_total     DECIMAL(18,2),
    new_total     DECIMAL(18,2)
);

MERGE fact_orders AS target
USING stg_orders_incr AS source
    ON target.order_id = source.order_id

WHEN MATCHED AND (   target.order_status <> source.order_status
                  OR target.order_total  <> source.order_total
                  OR target.order_date   <> source.order_date
                  OR target.customer_id  <> source.customer_id
                  OR target.sales_rep_id <> source.sales_rep_id )
    THEN UPDATE SET
        target.order_date   = source.order_date,
        target.customer_id  = source.customer_id,
        target.sales_rep_id = source.sales_rep_id,
        target.order_status = source.order_status,
        target.order_total  = source.order_total

WHEN NOT MATCHED THEN
    INSERT (order_id, order_date, customer_id, sales_rep_id, order_status, order_total)
    VALUES (source.order_id, source.order_date, source.customer_id,
            source.sales_rep_id, source.order_status, source.order_total)

OUTPUT $action,
       ISNULL(inserted.order_id, deleted.order_id),
       deleted.order_status,  inserted.order_status,
       deleted.order_total,   inserted.order_total
INTO #merge_log;


-- Verification
SELECT COUNT(*) AS count_after_merge FROM fact_orders;

SELECT action_taken, COUNT(*) AS rows_affected
FROM #merge_log
GROUP BY action_taken;

SELECT TOP 10 order_id, old_status, new_status, old_total, new_total
FROM #merge_log
WHERE action_taken = 'UPDATE'
ORDER BY order_id;

SELECT TOP 5 order_id, new_status, new_total
FROM #merge_log
WHERE action_taken = 'INSERT'
ORDER BY order_id;


-- Was 0 before the load: the batch revises header totals but ships no line items.
SELECT COUNT(*) AS orders_where_header_total_disagrees_with_lines
FROM fact_orders o
JOIN (SELECT order_id, SUM(line_amount) AS line_sum
      FROM fact_order_items GROUP BY order_id) i
  ON i.order_id = o.order_id
WHERE ABS(o.order_total - i.line_sum) > 0.01;
GO
