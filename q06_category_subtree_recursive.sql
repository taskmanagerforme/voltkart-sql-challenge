USE Voltkart;
GO

-- SELECT * from dim_category

with par as (
SELECT category_id,category_name,parent_category_id,
 0 as lvl
 ,cast(category_name as varchar(MAX)) as category_path FROM dim_category 
where category_id =102
UNION ALL
SELECT  ch.category_id,ch.category_name,ch.parent_category_id, par.lvl +1
,cast((par.category_path + ' > ' + ch.category_name) as varchar(max)  ) as category_path
from dim_category ch
join par on par.category_id = ch.parent_category_id)
SELECT * from par 

