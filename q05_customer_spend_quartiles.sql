USE Voltkart;
GO


WITH customer_spend AS
(
    SELECT
        customer_id,
        SUM(order_total) AS lifetime_spend
    FROM fact_orders
    WHERE order_status = 'Completed'
    GROUP BY customer_id
),

customer_quartiles AS
(
    SELECT
        customer_id,
        lifetime_spend,
        NTILE(4) OVER (
            ORDER BY lifetime_spend
        ) AS spend_quartile
    FROM customer_spend
)

SELECT
    spend_quartile,
    COUNT(*) AS customer_count,
    AVG(lifetime_spend) AS avg_lifetime_spend
FROM customer_quartiles
GROUP BY spend_quartile
ORDER BY spend_quartile;

go
