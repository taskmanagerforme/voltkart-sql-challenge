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


/* ===========================================================================
   RESULTS

   SET STATISTICS IO, logical reads:

     variant                                fact_orders   fact_order_items   TOTAL
     YEAR(), no indexes      (original)         498             415            913
     date range, no indexes                     498             415            913
     YEAR(), with indexes                       250             226            476
     date range, with indexes  (final)          184             226            410

   913 -> 410 logical reads, a 55% reduction.


   EXECUTION PLAN — BEFORE

     |--Compute Scalar
          |--Hash Match(Left Outer Join, HASH:([o].[customer_id])=([o2].[customer_id]))
               |--Hash Match(Aggregate, HASH:([o].[customer_id]))
               |    |--Table Scan(fact_orders,
               |                  WHERE: datepart(year,[order_date])=(2024))
               |--Hash Match(Aggregate, HASH:([o2].[customer_id]))
                    |--Hash Match(Inner Join, HASH:([o2].[order_id])=([oi].[order_id]))
                         |--Table Scan(fact_orders)
                         |--Table Scan(fact_order_items)


   EXECUTION PLAN — AFTER

     |--Compute Scalar
          |--Hash Match(Left Outer Join, HASH:([o].[customer_id])=([o2].[customer_id]))
               |--Hash Match(Aggregate, HASH:([o].[customer_id]))
               |    |--Index Seek(IX_fact_orders_order_date,
               |                  SEEK: [order_date] >= '2024-01-01'
               |                    AND [order_date] <  '2025-01-01')
               |--Hash Match(Aggregate, HASH:([o2].[customer_id]))
                    |--Hash Match(Inner Join, HASH:([o2].[order_id])=([oi].[order_id]))
                         |--Index Scan(IX_fact_orders_order_date)
                         |--Index Scan(IX_fact_order_items_order_id)


   WHY THE PLAN CHANGED

   1. Table Scan -> Index Seek on the filtered table.
      YEAR(order_date) wraps the column in a function, so the predicate is not
      SARGable: it can only be evaluated as a residual WHERE on a full scan of
      every row. Rewritten as an open-ended range on the bare column, the same
      filter becomes a SEEK that navigates straight to the 2024 rows and stops.

   2. Table Scan -> Index Scan on the subquery's two tables.
      Both indexes are covering — INCLUDE carries the columns the query needs
      (customer_id, order_id on fact_orders; line_amount on fact_order_items) —
      so SQL Server reads narrow index pages and never touches the heap. This is
      where most of the saving comes from: 913 -> 476 before the predicate is
      even fixed.

   3. SARGability alone is worth nothing.
      Rows 1 and 2 of the table are identical at 913 reads. With no index to
      seek, both predicates cost a full table scan, so making a predicate
      seekable only pays once an index exists for it to seek. The index and the
      rewrite are not independent wins; the second depends on the first.

   4. The correlated subquery is not the bottleneck.
      It looks like the obvious villain — a scalar subquery referencing the
      outer row, apparently once per customer. It isn't: the plan shows it as a
      Hash Match (Left Outer Join) against a pre-aggregated set, and Scan count
      on fact_order_items is 1, not one per customer. SQL Server decorrelates it
      into a join automatically. Rewriting it by hand as a CTE + JOIN was
      measured at 410 reads — identical — so it was left as written rather than
      changed for the appearance of an optimisation.
   =========================================================================== */
