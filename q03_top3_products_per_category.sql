USE Voltkart;
GO
with cte as (
select dc.category_name, dp.product_name, sum(fi.line_amount)  as total_revenue   from 
fact_orders fo
left join fact_order_items  fi  
on fo.order_id = fi.order_id
left join dim_product dp  
on dp.product_id = fi.product_id
left join dim_category dc 
on dc.category_id = dp.category_id
where fo.order_status ='Completed'
GROUP by dc.category_name, dp.product_name,dp.product_id
)
SELECT * from (
select * , rank() over (PARTITION by category_name ORDER BY total_revenue desc) as revenue_rank
from cte) ranked
where revenue_rank <= 3
-- fi.product_id
GO

-- SELECT  * from  dim_category


