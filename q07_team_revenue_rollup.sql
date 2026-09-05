USE Voltkart;
GO

WITH rep_revenue AS (
    SELECT sales_rep_id, SUM(order_total) AS rep_revenue
    FROM fact_orders
    WHERE order_status = 'Completed'
    GROUP BY sales_rep_id
),

-- Every (ancestor, descendant) pair. Anchor pairs each employee with themselves
-- so a Sales Rep counts their own revenue; the recursive member carries
-- ancestor_id unchanged down every level.
org_tree AS (
    SELECT employee_id AS ancestor_id,
           employee_id AS descendant_id
    FROM dim_employee

    UNION ALL

    SELECT t.ancestor_id,
           e.employee_id
    FROM org_tree t
    JOIN dim_employee e ON e.manager_id = t.descendant_id
),

team_totals AS (
    SELECT t.ancestor_id AS employee_id,
           SUM(ISNULL(r.rep_revenue, 0)) AS team_total_revenue
    FROM org_tree t
    LEFT JOIN rep_revenue r ON r.sales_rep_id = t.descendant_id
    GROUP BY t.ancestor_id
)

SELECT e.employee_id,
       e.employee_name,
       e.role,
       tt.team_total_revenue
FROM team_totals tt
JOIN dim_employee e ON e.employee_id = tt.employee_id
ORDER BY tt.team_total_revenue DESC;
GO


-- Verification: the CEO's team total must equal total company completed revenue.
SELECT
    (SELECT SUM(order_total) FROM fact_orders WHERE order_status = 'Completed') AS company_total,
    (SELECT SUM(rep_revenue) FROM (
        SELECT SUM(order_total) AS rep_revenue FROM fact_orders
        WHERE order_status = 'Completed' GROUP BY sales_rep_id) x)                AS sum_of_all_reps;
GO
