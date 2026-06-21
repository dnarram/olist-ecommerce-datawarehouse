/*==============================================================================
  FICHERO  : 04_quality_checks.sql
  PROYECTO : Data Warehouse E-commerce (Olist) · PostgreSQL
  AUTOR    : David Naranjo Ramírez

  OBJETIVO : Validar la calidad e integridad del Data Warehouse y aplicar
             correcciones seguras. Detecta nulos, duplicados, tipos/fechas
             incorrectos, outliers y huérfanos referenciales.

  REQUISITO PREVIO: ejecutar 01_schema.sql y 02_data.sql.

  NOTA: en el dataset de Olist la mayoría de estas comprobaciones devuelven 0
        (el modelo ya nace limpio gracias a las CONSTRAINTS del esquema). Se
        incluyen igualmente como AUDITORÍA reproducible y para demostrar las
        técnicas (IS NULL, GROUP BY/HAVING, RANK/ROW_NUMBER, rangos válidos).
        Única exclusión consciente del ETL: 1 pedido sin registro de pago
        (= 3 líneas de venta), por el INNER JOIN con dim_payment.
==============================================================================*/

SET search_path TO ecommerce_dw;


/*==============================================================================
  1 · PERFILADO RÁPIDO DE TABLAS CLAVE
==============================================================================*/
SELECT 'stg_orders'               AS table_name, COUNT(*) AS row_count FROM ecommerce_dw.stg_orders
UNION ALL SELECT 'stg_order_items',          COUNT(*) FROM ecommerce_dw.stg_order_items
UNION ALL SELECT 'stg_order_payments',       COUNT(*) FROM ecommerce_dw.stg_order_payments
UNION ALL SELECT 'stg_order_reviews',        COUNT(*) FROM ecommerce_dw.stg_order_reviews
UNION ALL SELECT 'stg_customers',            COUNT(*) FROM ecommerce_dw.stg_customers
UNION ALL SELECT 'stg_products',             COUNT(*) FROM ecommerce_dw.stg_products
UNION ALL SELECT 'stg_sellers',              COUNT(*) FROM ecommerce_dw.stg_sellers
UNION ALL SELECT 'dim_customer',             COUNT(*) FROM ecommerce_dw.dim_customer
UNION ALL SELECT 'dim_product',              COUNT(*) FROM ecommerce_dw.dim_product
UNION ALL SELECT 'dim_seller',               COUNT(*) FROM ecommerce_dw.dim_seller
UNION ALL SELECT 'dim_payment',              COUNT(*) FROM ecommerce_dw.dim_payment
UNION ALL SELECT 'dim_date',                 COUNT(*) FROM ecommerce_dw.dim_date
UNION ALL SELECT 'fact_sales',               COUNT(*) FROM ecommerce_dw.fact_sales
ORDER BY table_name;


/*==============================================================================
  2 · NULOS EN CAMPOS CRÍTICOS  (un único resumen en lugar de N consultas)
  btrim(...) = '' detecta también cadenas vacías/espacios, no solo NULL.
==============================================================================*/
SELECT 'stg_orders.order_id'      AS campo,
       COUNT(*) FILTER (WHERE order_id IS NULL OR btrim(order_id) = '') AS nulos
FROM ecommerce_dw.stg_orders
UNION ALL
SELECT 'stg_orders.customer_id',
       COUNT(*) FILTER (WHERE customer_id IS NULL OR btrim(customer_id) = '')
FROM ecommerce_dw.stg_orders
UNION ALL
SELECT 'stg_orders.purchase_ts',
       COUNT(*) FILTER (WHERE order_purchase_timestamp IS NULL)
FROM ecommerce_dw.stg_orders
UNION ALL
SELECT 'stg_order_items.product_id',
       COUNT(*) FILTER (WHERE product_id IS NULL OR btrim(product_id) = '')
FROM ecommerce_dw.stg_order_items
UNION ALL
SELECT 'stg_order_items.price',
       COUNT(*) FILTER (WHERE price IS NULL)
FROM ecommerce_dw.stg_order_items
UNION ALL
SELECT 'stg_products.category (sin categoría)',
       COUNT(*) FILTER (WHERE product_category_name IS NULL OR btrim(product_category_name) = '')
FROM ecommerce_dw.stg_products
UNION ALL
SELECT 'fact_sales.review_score (sin reseña)',
       COUNT(*) FILTER (WHERE review_score IS NULL)
FROM ecommerce_dw.fact_sales
UNION ALL
SELECT 'fact_sales.total_sale',
       COUNT(*) FILTER (WHERE total_sale IS NULL)
FROM ecommerce_dw.fact_sales;
-- Verificado en Olist: 0 en claves/importes. Nulos legítimos: 610 productos sin
-- categoría y 942 líneas de la fact sin reseña (pedido sin valoración).


/*==============================================================================
  3 · DUPLICADOS EN STAGING  (GROUP BY + HAVING COUNT(*) > 1)
==============================================================================*/
-- Pedidos duplicados
SELECT order_id, COUNT(*) AS duplicate_count
FROM ecommerce_dw.stg_orders
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC, order_id;

-- Productos duplicados
SELECT product_id, COUNT(*) AS duplicate_count
FROM ecommerce_dw.stg_products
GROUP BY product_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC, product_id;

-- Líneas de pedido duplicadas (clave natural order_id + order_item_id)
SELECT order_id, order_item_id, COUNT(*) AS duplicate_count
FROM ecommerce_dw.stg_order_items
GROUP BY order_id, order_item_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;

-- Reviews con review_id repetido (789 filas en Olist; el ETL conserva la reseña
-- más reciente por pedido, así que estos duplicados no llegan a la fact)
SELECT review_id, COUNT(*) AS duplicate_count
FROM ecommerce_dw.stg_order_reviews
GROUP BY review_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC
LIMIT 20;


/*==============================================================================
  4 · DUPLICADOS EN LA FACT  (no deberían existir: hay UNIQUE en el esquema)
==============================================================================*/
SELECT order_id, order_item_id, COUNT(*) AS duplicate_count
FROM ecommerce_dw.fact_sales
GROUP BY order_id, order_item_id
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;


/*==============================================================================
  5 · VALIDACIÓN DE TIPOS / FECHAS
  Se comprueba que las columnas tienen el tipo esperado (p. ej. que las fechas
  NO se hayan quedado como texto). Útil si la carga se hizo por interfaz.
==============================================================================*/
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'ecommerce_dw'
  AND table_name = 'fact_sales'
ORDER BY ordinal_position;

-- Verificación de que las fechas de compra son convertibles (no texto basura):
SELECT COUNT(*) AS fechas_no_validas
FROM ecommerce_dw.stg_orders
WHERE order_purchase_timestamp IS NULL
  AND order_status NOT IN ('canceled', 'unavailable');


/*==============================================================================
  6 · OUTLIERS / RANGOS ESPERADOS
==============================================================================*/
-- review_score fuera de [1,5]
SELECT COUNT(*) AS invalid_review_score
FROM ecommerce_dw.fact_sales
WHERE review_score IS NOT NULL AND review_score NOT BETWEEN 1 AND 5;

-- Importes negativos
SELECT
    COUNT(*) FILTER (WHERE price < 0)         AS precios_negativos,
    COUNT(*) FILTER (WHERE freight_value < 0) AS portes_negativos,
    COUNT(*) FILTER (WHERE total_sale < 0)    AS total_negativo
FROM ecommerce_dw.fact_sales;

-- Días de entrega / retraso negativos (no tienen sentido)
SELECT
    COUNT(*) FILTER (WHERE delivery_days < 0) AS entrega_negativa,
    COUNT(*) FILTER (WHERE delay_days   < 0)  AS retraso_negativo
FROM ecommerce_dw.fact_sales;

-- Cuotas de pago inválidas
SELECT COUNT(*) AS cuotas_invalidas
FROM ecommerce_dw.dim_payment
WHERE payment_installments < 0;


/*==============================================================================
  7 · INTEGRIDAD REFERENCIAL (HUÉRFANOS EN LA FACT)
  Con las FK del esquema esto SIEMPRE devuelve 0; se comprueba como red de
  seguridad y para demostrar el patrón LEFT JOIN ... IS NULL.
==============================================================================*/
SELECT 'customer' AS dimension,
       COUNT(*) AS huerfanos
FROM ecommerce_dw.fact_sales f
LEFT JOIN ecommerce_dw.dim_customer d ON f.customer_key = d.customer_key
WHERE d.customer_key IS NULL
UNION ALL
SELECT 'product',
       COUNT(*)
FROM ecommerce_dw.fact_sales f
LEFT JOIN ecommerce_dw.dim_product d ON f.product_key = d.product_key
WHERE d.product_key IS NULL
UNION ALL
SELECT 'seller',
       COUNT(*)
FROM ecommerce_dw.fact_sales f
LEFT JOIN ecommerce_dw.dim_seller d ON f.seller_key = d.seller_key
WHERE d.seller_key IS NULL
UNION ALL
SELECT 'date',
       COUNT(*)
FROM ecommerce_dw.fact_sales f
LEFT JOIN ecommerce_dw.dim_date d ON f.date_key = d.date_key
WHERE d.date_key IS NULL
UNION ALL
SELECT 'payment',
       COUNT(*)
FROM ecommerce_dw.fact_sales f
LEFT JOIN ecommerce_dw.dim_payment d ON f.payment_key = d.payment_key
WHERE d.payment_key IS NULL;


/*==============================================================================
  8 · CORRECCIONES SEGURAS  (transacción: UPDATE + DELETE)
  Demostrativas e idempotentes: solo actúan si hay problemas reales.
==============================================================================*/
BEGIN;

-- 8.1 Normalizar estados vacíos en staging (IS NULL / cadena vacía -> 'unknown')
UPDATE ecommerce_dw.stg_orders
SET order_status = 'unknown'
WHERE order_status IS NULL OR btrim(order_status) = '';

-- 8.2 Rellenar textos de reseña vacíos
UPDATE ecommerce_dw.stg_order_reviews
SET review_comment_title = 'Sin título'
WHERE review_comment_title IS NULL OR btrim(review_comment_title) = '';

-- 8.3 Invalidar puntuaciones fuera de rango (defensivo; en Olist no hay)
UPDATE ecommerce_dw.stg_order_reviews
SET review_score = NULL
WHERE review_score IS NOT NULL AND review_score NOT BETWEEN 1 AND 5;

-- 8.4 Eliminar duplicados exactos en la traducción de categorías,
--     conservando una sola fila por par (RANK lógico con ROW_NUMBER).
WITH dupes AS (
    SELECT ctid,
           ROW_NUMBER() OVER (
               PARTITION BY product_category_name, product_category_name_english
               ORDER BY ctid
           ) AS rn
    FROM ecommerce_dw.stg_category_translation
)
DELETE FROM ecommerce_dw.stg_category_translation t
USING dupes d
WHERE t.ctid = d.ctid
  AND d.rn > 1;

-- 8.5 Eliminar duplicados de la fact si por algún motivo aparecieran
--     (conserva la fila con menor sales_key).
WITH dupes AS (
    SELECT sales_key,
           ROW_NUMBER() OVER (
               PARTITION BY order_id, order_item_id
               ORDER BY sales_key
           ) AS rn
    FROM ecommerce_dw.fact_sales
)
DELETE FROM ecommerce_dw.fact_sales f
USING dupes d
WHERE f.sales_key = d.sales_key
  AND d.rn > 1;

COMMIT;

/*========================== FIN 04_quality_checks.sql =======================*/