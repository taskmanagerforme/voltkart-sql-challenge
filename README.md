# Voltkart — Session 1: Advanced SQL for Modern Data Engineering

Solutions to the Codebasics Data Engineering Bootcamp Session 1 assignment.
Engine: **SQL Server 2022**, run in a Docker container on Linux. Database: `Voltkart`.
One `.sql` file per question.

Questions 1–10 are answered. Q11 (bonus) was not attempted.

---

## Setup notes

The pack's `data/load.sql` targets Windows paths (`C:\cb_data\`). `BULK INSERT` reads from the
**SQL Server process's** filesystem, not the client's, so on Linux the CSVs have to be copied
into the container before the load can see them:

```bash
docker exec sqlserver mkdir -p /var/opt/mssql/cb_data
docker cp data/. sqlserver:/var/opt/mssql/cb_data/
# then run load.sql with the paths rewritten to /var/opt/mssql/cb_data/
```

**A defect in the pack's `load.sql`.** It specifies `ROWTERMINATOR='0x0a'` (LF), but all eight
CSVs are **CRLF**. The stray `\r` is absorbed into the last field of every row. Numeric and date
columns coerce it away silently; `NVARCHAR` columns keep it — which corrupted
`dim_category.category_name` (26/26 rows) and `dim_employee.region` (58/58).

The symptom is nasty because nothing errors: `WHERE category_name = 'Computers'` returns **zero
rows**, which would make a perfectly correct Q6 recursive CTE look broken. `LEN()` vs
`DATALENGTH()` is the detector — `LEN('Gaming Laptops')` returned 15 instead of 14. Fixed by
loading with `ROWTERMINATOR='0x0d0a'`. This is not Linux-specific; the same load on Windows
produces the same corruption.

Tables were left as **heaps with no indexes or primary keys**, so Q10's index work is measurable.

| table | rows |
|---|---:|
| dim_category | 26 |
| dim_employee | 58 |
| dim_product | 400 |
| dim_customer | 2,000 |
| stg_orders_incr | 800 |
| cdc_product_changes | 35 |
| fact_orders | 30,000 |
| fact_order_items | 56,825 |

**Run order matters.** Q8 and Q9 mutate `fact_orders` and `dim_product`. All analytical answers
(Q1–Q7, Q10) were produced against the original data, with the two loads run last. Both files
carry a commented snapshot/restore block.

---

## Write-up

**Q1 — Top 20 completed orders.** Three-table join, `TOP 20` with `ORDER BY order_total DESC`.
Left joins used defensively; verified zero orphan customer or sales-rep references, so the result
is identical to inner joins. No ties at the rank-20 boundary (₹475,868.10 vs ₹472,390.50), so
plain `TOP 20` is deterministic here. On unindexed heaps the plan sorts the filtered fact rows
first and pulls only the rows `TOP` needs up through the joins — the Sort dominates, not the join.

**Q2 — Customers who never ordered.** Returns **zero rows, and that is the answer**: all 2,000
customers in `dim_customer` appear in `fact_orders`, and the key ranges match exactly
(500000–501999 in both). A verification count is included, because an empty result set is
indistinguishable from a broken query otherwise. `NOT EXISTS` over `NOT IN` — `NOT IN` returns
*no rows at all* if the subquery yields a single `NULL`, since `x NOT IN (1, NULL)` evaluates to
`UNKNOWN` rather than `TRUE`. It would work by luck here; it is a silent trap on a nullable FK.

**Q3 — Top 3 products per category.** The interesting one. Grouping by `product_name` is wrong:
**11 pairs of products share both a name and a category** — same marketing name, different
`unit_price`, `unit_cost` and `launch_date`, i.e. model refreshes of the same product line. Name
grouping merged them into 389 groups instead of 400 and **changed the top 3 in 7 of the 15
categories**. In Gaming Laptops it invented a #1 seller that doesn't exist, by summing two
different SKUs. Fixed by grouping on `product_id` while still displaying `product_name` — the
output grain is set by `GROUP BY`, not by what you `SELECT`. `RANK` over `ROW_NUMBER` so a tie
for third returns both rather than dropping one arbitrarily; no ties exist in this data.

Only 15 of 26 categories appear, because `dim_product.category_id` points at *leaf* categories and
the other 11 are internal nodes. Read as "every category that has products", not as a rollup up
the tree — Q6 is where the hierarchy gets walked.

**Q4 — Monthly revenue, running total, MoM %.** `LAG` rather than a self-join (one pass), and an
explicit `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` frame rather than the `RANGE` default.
`LAG` returns the previous **row**, not the previous **calendar month**, so this is only correct if
no month is missing — verified: 27 months present, 27 expected, no gaps. The first month's MoM is
`NULL` and left that way; growth against no prior month is undefined, not 0%.

Also verified that `fact_orders.order_total` equals `SUM(fact_order_items.line_amount)` for all
30,000 orders, so Q3's line-level revenue and Q4's header-level revenue reconcile.

⚠️ **March 2025 shows −57%, and that is a data artifact, not a business event** — the data stops on
2025-03-15, so the final period is half a month.

**Q5 — Customer spend quartiles.** Two levels of aggregation: sum orders per customer to get one
lifetime figure each, then `NTILE(4)` over those 2,000 figures and aggregate again per bucket. So
`avg_lifetime_spend` is an *average of sums*, not average order value. 2,000 divides cleanly into
4 × 500. `NTILE` splits by row count, not by value, and the result shows why that matters:

| quartile | customers | avg lifetime spend | range |
|---|---:|---:|---|
| 1 | 500 | ₹227,555 | ₹1,849 – ₹343,667 |
| 2 | 500 | ₹428,917 | ₹343,767 – ₹518,375 |
| 3 | 500 | ₹628,718 | ₹518,779 – ₹752,070 |
| 4 | 500 | ₹2,273,361 | ₹752,322 – ₹8,821,717 |

The top 500 customers average **10× the bottom 500**, and quartile 4's spend range is ~25× wider
than quartile 1's. Equal customer counts, wildly unequal value.

**Q6 — Category subtree.** Recursive CTE anchored on `category_name = 'Computers'`, carrying a
depth counter and an accumulating path string. Root is depth 0. The anchor casts to
`VARCHAR(MAX)` — without it the anchor's type is inferred as `NVARCHAR(255)`, the recursive
member's concatenation is wider, and SQL Server raises *"Types don't match between the anchor and
the recursive part."* Ordering by `category_path` renders the tree depth-first for free.

**Q7 — Team revenue up the org chart.** Every employee needs their own subtree's revenue, and the
subtrees overlap — one rep's sales count for their Team Lead, Regional Manager and the CEO.
Recursing once per employee would be 58 traversals. Instead one recursive CTE emits every
**(ancestor, descendant) pair** — a closure table — anchoring each employee to *themselves* at
depth 0 so a Sales Rep counts their own revenue, then carrying `ancestor_id` unchanged down every
level. Revenue is aggregated per rep *before* the join to avoid fan-out, and joined with `LEFT`
because managers have no sales of their own.

209 pairs from 58 employees. Verification: **the CEO's team total equals total company completed
revenue exactly** (₹1,779,275,752.75 — the same figure as Q4's final running total), and the four
Regional Managers sum to precisely the same number, so the org chart partitions with no gaps and
no double counting.

**Q8 — Incremental load.** One `MERGE`: 300 updates, 500 inserts, 30,000 → 30,500 rows. `MERGE`
raises error 8672 if the source has more than one row per join key, so a duplicate check runs
first (0 duplicates here). `WHEN MATCHED` is guarded on an actual difference so unchanged rows
aren't rewritten — no wasted transaction log, no phantom modifications for downstream CDC.

Verification uses `OUTPUT $action, deleted.*, inserted.* INTO #merge_log`, which is the only way
to sample *updated* rows afterwards: once the statement commits the old values are gone, and an
`EXISTS` check can't tell an update from an insert because all 800 source rows exist in the target
either way.

Note: before this load, all 30,000 order headers agreed with their line-item sums. After it,
**300 disagree** — the batch revises header totals but ships no matching `fact_order_items` rows.
The MERGE is correct; the feed is incomplete. A real pipeline would load both in one transaction,
and a data-quality test asserting *header total = sum of lines* would now fail.

**Q9 — CDC feed.** One `MERGE` handling `I`/`U`/`D`: 10 inserted, 20 updated, 5 deleted,
400 → 405 rows. T-SQL allows at most two `WHEN MATCHED` clauses, differentiated by `AND`
conditions, with the first match winning — which is what makes update-and-delete off the same
join possible. Verified that no `I` collided with an existing product and no `D` targeted a
missing one, so the silent no-op paths never fire on this feed.

⚠️ **The five deletes orphaned 690 `fact_order_items` rows.** No foreign keys are declared, so the
deletes succeeded and left line items pointing at products that no longer exist; re-running Q3
would silently drop those rows from the category join. A CDC `D` describes the *source system* —
it isn't licence to hard-delete a warehouse dimension that facts still reference. A soft delete
(`is_deleted` flag) or restricting deletes to unreferenced rows is the standard answer.

**Q10 — Optimisation.** **913 → 410 logical reads, a 55% reduction.** Full breakdown, both text
execution plans, and the reasoning are in `q10_optimize_slow_query.sql`. The four findings:

1. `Table Scan → Index Seek` on the filtered table. `YEAR(order_date)` wraps the column in a
   function, so the predicate is not SARGable and can only be a residual on a full scan.
2. Both indexes are **covering** (`INCLUDE` carries the needed columns), so the subquery's tables
   are read as narrow index pages instead of heap pages. This is most of the win: 913 → 476.
3. **SARGability alone is worth nothing.** With no index, the `YEAR()` and date-range versions
   cost an identical 913 reads. A seekable predicate only pays once there's an index to seek.
4. **The correlated subquery is not the bottleneck.** It looks like the villain, but the plan shows
   a `Hash Match (Left Outer Join)` against a pre-aggregated set and a scan count of 1 on
   `fact_order_items` — SQL Server decorrelates it automatically. Rewriting it by hand as a
   CTE + join measured **410 reads, identical**, so it was left as written rather than changed for
   the appearance of an optimisation.

The file drops the indexes, measures the original, creates them and measures the fix, so the
before/after numbers reproduce end to end.
