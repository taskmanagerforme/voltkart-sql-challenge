USE Voltkart;
GO

SELECT customer_id, customer_name, signup_date from dim_customer c   
where not exists  (

    select 1 from fact_orders f WHERE 
    c.customer_id =f.customer_id
)

-- SELECT count(distinct customer_id)
-- from dim_customer
-- where customer_id in (
-- select distinct customer_id from fact_orders

-- )
-- SELECT count(distinct customer_id)
-- from dim_customer
-- from fact_orders
GO

