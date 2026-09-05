USE Voltkart;
GO

with cte as
(select o.* ,c.customer_name,e.employee_name as sales_rep_name ,e.role
from fact_orders o  
left join dim_customer c  on o.customer_id = c.customer_id
left join dim_employee e on o.sales_rep_id = e.employee_id
) 
 SELECT top 20 order_id, order_date, customer_name, sales_rep_name, order_total FROM cte f where order_status ='Completed'  order BY order_total desc

 GO

