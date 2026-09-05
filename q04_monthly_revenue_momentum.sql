USE Voltkart;
GO

WITH cte AS
(
    SELECT
        FORMAT(CAST(order_date AS date), 'yyyy-MM') AS order_month,
        SUM(order_total) AS monthly_revenue
    FROM fact_orders
    WHERE order_status = 'Completed'
    GROUP BY FORMAT(CAST(order_date AS date), 'yyyy-MM')
),

cte2 AS
(
    SELECT
        order_month,
        monthly_revenue,

        SUM(monthly_revenue)
            OVER (
                ORDER BY order_month
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS running_total,

        LAG(monthly_revenue)
            OVER (
                ORDER BY order_month
            ) AS previous_month_revenue

    FROM cte
)

SELECT
    order_month,
    monthly_revenue,
    running_total,

    (
        (monthly_revenue - previous_month_revenue)
        / NULLIF(previous_month_revenue, 0)
    ) * 100 AS mom_pct_change

FROM cte2
ORDER BY order_month;
GO  