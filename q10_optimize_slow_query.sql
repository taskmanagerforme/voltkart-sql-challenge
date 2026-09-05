USE Voltkart;
GO

-- ============================ BEFORE ============================
DROP INDEX IF EXISTS IX_fact_orders_order_date ON fact_orders;
DROP INDEX IF EXISTS IX_fact_order_items_order_id ON fact_order_items;
GO

SET STATISTICS IO, TIME ON;
GO

SELECT o.customer_id, COUNT(*) AS orders_2024,
       (SELECT SUM(oi.line_amount)
          FROM fact_order_items oi
          JOIN fact_orders o2 ON o2.order_id = oi.order_id
         WHERE o2.customer_id = o.customer_id) AS lifetime_value
FROM fact_orders o
WHERE YEAR(o.order_date) = 2024
GROUP BY o.customer_id;
GO

SET STATISTICS IO, TIME OFF;
GO


-- ============================ THE FIX ============================
CREATE INDEX IX_fact_orders_order_date
    ON fact_orders (order_date)
    INCLUDE (customer_id, order_id);

CREATE INDEX IX_fact_order_items_order_id
    ON fact_order_items (order_id)
    INCLUDE (line_amount);
GO


-- ============================ AFTER ============================
SET STATISTICS IO, TIME ON;
GO

SELECT o.customer_id, COUNT(*) AS orders_2024,
       (SELECT SUM(oi.line_amount)
          FROM fact_order_items oi
          JOIN fact_orders o2 ON o2.order_id = oi.order_id
         WHERE o2.customer_id = o.customer_id) AS lifetime_value
FROM fact_orders o
WHERE order_date >= '2024-01-01'
  AND order_date <  '2025-01-01'
GROUP BY o.customer_id;
GO

SET STATISTICS IO, TIME OFF;
GO


/* ---------------------------------------------------------------------------
RESULT

  variant                              fact_orders   fact_order_items   TOTAL
  YEAR(), no indexes   (original)          498             415           913
  date range, no indexes                   498             415           913
  YEAR(), with indexes                     250             226           476
  date range, with indexes (final)         184             226           410

  913 -> 410 logical reads, a 55% reduction.

WHY THE PLAN CHANGED

1. The indexes did most of the work: 913 -> 476. Both are covering
   (INCLUDE carries the columns the query needs), so SQL Server reads narrow
   index pages instead of full table pages and never touches the heap.

2. Making the predicate SARGable did the rest: 476 -> 410. YEAR(order_date)
   wraps the column in a function, so the index can only be scanned:

       YEAR(order_date) = 2024              ->  Index Scan
       order_date >= '2024-01-01' AND ...   ->  Index Seek

3. SARGability alone is worth nothing. Without an index the two predicates
   cost the same 913 reads, because the table is scanned either way. The index
   is what makes a seekable predicate pay.

4. The correlated subquery is not the bottleneck. Rewriting it as a set-based
   CTE + join measures 410 as well - identical. SQL Server decorrelates it
   already: Scan count on fact_order_items is 1, not one per customer. Kept as
   written, since the hand rewrite adds nothing but noise.
--------------------------------------------------------------------------- */
