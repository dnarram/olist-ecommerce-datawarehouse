/*==============================================================================
  FICHERO  : 02_data.sql
  PROYECTO : Data Warehouse E-commerce (Olist) · PostgreSQL
  AUTOR    : David Naranjo Ramírez

  CONTENIDO:
     PASO 0 · Carga de las tablas STAGING desde los CSV.
     PASO 1 · Limpieza de las tablas destino (recarga idempotente).
     PASO 2 · Carga de las dimensiones.
     PASO 3 · Carga de la tabla de hechos (fact_sales).
     PASO 4 · Demostración de transacciones (BEGIN / SAVEPOINT / ROLLBACK).

  REQUISITO PREVIO: ejecutar antes 01_schema.sql.
==============================================================================*/

SET search_path TO ecommerce_dw;

/*==============================================================================
  PASO 0 · CARGA DE STAGING DESDE CSV
  ------------------------------------------------------------------------------
  Dos formas de cargar:

  (A) Por código con psql  ->  descomenta el bloque \copy y ajusta la ruta.
      \copy es la opción REPRODUCIBLE recomendada para la corrección.

  (B) Con la interfaz de DBeaver  ->  clic derecho sobre cada tabla stg_*
      > "Import Data" > CSV. (El enunciado admite explícitamente la carga
      por CSV mediante la interfaz del IDE.)

  Importante: ajusta '/ruta/a/tu/proyecto/data/csv/' a tu ruta local.
==============================================================================*/

-- \copy ecommerce_dw.stg_orders              FROM '/ruta/a/tu/proyecto/data/csv/olist_orders_dataset.csv'              WITH (FORMAT csv, HEADER true);
-- \copy ecommerce_dw.stg_order_items         FROM '/ruta/a/tu/proyecto/data/csv/olist_order_items_dataset.csv'         WITH (FORMAT csv, HEADER true);
-- \copy ecommerce_dw.stg_order_payments      FROM '/ruta/a/tu/proyecto/data/csv/olist_order_payments_dataset.csv'      WITH (FORMAT csv, HEADER true);
-- \copy ecommerce_dw.stg_order_reviews       FROM '/ruta/a/tu/proyecto/data/csv/olist_order_reviews_dataset.csv'       WITH (FORMAT csv, HEADER true);
-- \copy ecommerce_dw.stg_customers           FROM '/ruta/a/tu/proyecto/data/csv/olist_customers_dataset.csv'           WITH (FORMAT csv, HEADER true);
-- \copy ecommerce_dw.stg_products            FROM '/ruta/a/tu/proyecto/data/csv/olist_products_dataset.csv'            WITH (FORMAT csv, HEADER true);
-- \copy ecommerce_dw.stg_sellers             FROM '/ruta/a/tu/proyecto/data/csv/olist_sellers_dataset.csv'             WITH (FORMAT csv, HEADER true);
-- \copy ecommerce_dw.stg_geolocation         FROM '/ruta/a/tu/proyecto/data/csv/olist_geolocation_dataset.csv'         WITH (FORMAT csv, HEADER true);
-- \copy ecommerce_dw.stg_category_translation FROM '/ruta/a/tu/proyecto/data/csv/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true);

-- NOTA de codificación: product_category_name_translation.csv lleva BOM UTF-8 y
-- olist_order_reviews_dataset.csv usa saltos de línea Windows (CRLF). Con
-- FORMAT csv + HEADER true, \copy descarta la primera línea (con el BOM) y
-- tolera el CRLF, por lo que la carga es correcta sin pasos extra.


/*==============================================================================
  CARGA DEL MODELO DIMENSIONAL  (transacción única: o se carga todo o nada)
==============================================================================*/
BEGIN;

SET search_path TO ecommerce_dw;

-- ----------------------------------------------------------------------------
-- PASO 1 · LIMPIEZA DE TABLAS DESTINO
-- Se vacían primero para poder recargar el DW desde cero sin duplicados.
-- RESTART IDENTITY reinicia las claves sustitutas; CASCADE respeta las FK.
-- ----------------------------------------------------------------------------
TRUNCATE TABLE
    ecommerce_dw.fact_sales,
    ecommerce_dw.dim_customer,
    ecommerce_dw.dim_product,
    ecommerce_dw.dim_seller,
    ecommerce_dw.dim_payment,
    ecommerce_dw.dim_date
RESTART IDENTITY CASCADE;

-- ----------------------------------------------------------------------------
-- PASO 2.1 · DIM_CUSTOMER
-- customer_id es la clave operativa única; customer_unique_id identifica al
-- cliente real (puede repetirse). DISTINCT ON garantiza 1 fila por customer_id.
-- ----------------------------------------------------------------------------
INSERT INTO ecommerce_dw.dim_customer (
    customer_unique_id,
    customer_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state
)
SELECT DISTINCT ON (customer_id)
    customer_unique_id,
    customer_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state
FROM ecommerce_dw.stg_customers
ORDER BY customer_id, customer_unique_id;

-- ----------------------------------------------------------------------------
-- PASO 2.2 · DIM_SELLER
-- ----------------------------------------------------------------------------
INSERT INTO ecommerce_dw.dim_seller (
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state
)
SELECT DISTINCT ON (seller_id)
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state
FROM ecommerce_dw.stg_sellers
ORDER BY seller_id;

-- ----------------------------------------------------------------------------
-- PASO 2.3 · DIM_PRODUCT  (LEFT JOIN con la traducción de categorías)
-- Se usa LEFT JOIN para NO perder productos cuya categoría no tiene traducción.
-- ----------------------------------------------------------------------------
INSERT INTO ecommerce_dw.dim_product (
    product_id,
    product_category_name,
    product_category_name_english,
    product_name_length,
    product_description_length,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm
)
SELECT DISTINCT ON (p.product_id)
    p.product_id,
    p.product_category_name,
    t.product_category_name_english,
    p.product_name_lenght,         -- corrige la errata: lenght (staging) -> length (dim)
    p.product_description_lenght,  -- corrige la errata: lenght (staging) -> length (dim)
    p.product_photos_qty,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm
FROM ecommerce_dw.stg_products p
LEFT JOIN ecommerce_dw.stg_category_translation t
    ON p.product_category_name = t.product_category_name
ORDER BY p.product_id;

-- ----------------------------------------------------------------------------
-- PASO 2.4 · DIM_PAYMENT  (combinaciones únicas método + nº de cuotas)
-- ----------------------------------------------------------------------------
INSERT INTO ecommerce_dw.dim_payment (
    payment_type,
    payment_installments
)
SELECT DISTINCT
    payment_type,
    payment_installments
FROM ecommerce_dw.stg_order_payments
WHERE payment_type IS NOT NULL
  AND payment_installments IS NOT NULL;

-- ----------------------------------------------------------------------------
-- PASO 2.5 · DIM_DATE
-- Se genera 1 fila por día entre la fecha mínima y máxima de compra del dataset
-- usando generate_series (funciones de fecha).
-- ----------------------------------------------------------------------------
WITH date_bounds AS (
    SELECT
        MIN(order_purchase_timestamp::date) AS min_date,
        MAX(order_purchase_timestamp::date) AS max_date
    FROM ecommerce_dw.stg_orders
    WHERE order_purchase_timestamp IS NOT NULL
),
date_series AS (
    SELECT generate_series(min_date, max_date, interval '1 day')::date AS full_date
    FROM date_bounds
)
INSERT INTO ecommerce_dw.dim_date (
    date_key, full_date, year, quarter, month,
    month_name, week, day, weekday_name, is_weekend
)
SELECT
    CAST(TO_CHAR(full_date, 'YYYYMMDD') AS INTEGER) AS date_key,  -- CAST explícito
    full_date,
    EXTRACT(YEAR    FROM full_date)::INTEGER AS year,
    EXTRACT(QUARTER FROM full_date)::INTEGER AS quarter,
    EXTRACT(MONTH   FROM full_date)::INTEGER AS month,
    TRIM(TO_CHAR(full_date, 'FMMonth'))      AS month_name,
    EXTRACT(WEEK    FROM full_date)::INTEGER  AS week,
    EXTRACT(DAY     FROM full_date)::INTEGER  AS day,
    TRIM(TO_CHAR(full_date, 'FMDay'))         AS weekday_name,
    CASE WHEN EXTRACT(ISODOW FROM full_date) IN (6, 7)
         THEN TRUE ELSE FALSE END             AS is_weekend
FROM date_series
ORDER BY full_date;

-- ----------------------------------------------------------------------------
-- PASO 3 · FACT_SALES
-- Grano: 1 fila = 1 producto vendido dentro de un pedido.
-- Se deduplican dos relaciones 1:N antes de unir a la fact:
--   - PAGOS  : un pedido puede tener varios pagos -> se elige el PRINCIPAL
--              (mayor importe). En la fact solo describimos CÓMO se pagó.
--   - RESEÑAS: un pedido puede tener varias reseñas -> se elige la MÁS RECIENTE.
--
-- ALCANCE: el JOIN final con dim_payment es INNER, por lo que se excluyen los
-- pedidos SIN registro de pago (en Olist es 1 pedido). Es una decisión de
-- alcance consciente: una venta sin método de pago no puede atribuirse a la
-- dimensión de pago. El resto de JOINs no descartan filas.
-- ----------------------------------------------------------------------------
WITH payment_ranked AS (
    SELECT
        order_id, payment_type, payment_installments, payment_value,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY payment_value DESC, payment_installments ASC, payment_type ASC
        ) AS rn
    FROM ecommerce_dw.stg_order_payments
    WHERE payment_type IS NOT NULL
      AND payment_installments IS NOT NULL
),
main_payment AS (
    SELECT order_id, payment_type, payment_installments
    FROM payment_ranked
    WHERE rn = 1
),
review_ranked AS (
    SELECT
        order_id, review_score, review_creation_date, review_answer_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY review_creation_date DESC NULLS LAST,
                     review_answer_timestamp DESC NULLS LAST
        ) AS rn
    FROM ecommerce_dw.stg_order_reviews
),
main_review AS (
    SELECT order_id, review_score
    FROM review_ranked
    WHERE rn = 1
),
sales_base AS (
    SELECT
        oi.order_id,
        oi.order_item_id,
        o.customer_id,
        oi.product_id,
        oi.seller_id,
        oi.price,
        oi.freight_value,
        o.order_status,
        o.order_purchase_timestamp,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        mr.review_score,
        mp.payment_type,
        mp.payment_installments
    FROM ecommerce_dw.stg_order_items oi
    INNER JOIN ecommerce_dw.stg_orders o
        ON oi.order_id = o.order_id
    LEFT JOIN main_review mr
        ON oi.order_id = mr.order_id
    LEFT JOIN main_payment mp
        ON oi.order_id = mp.order_id
)
INSERT INTO ecommerce_dw.fact_sales (
    order_id, order_item_id,
    customer_key, product_key, seller_key, date_key, payment_key,
    price, freight_value, total_sale,
    review_score, delivery_days, delay_days, order_status
)
SELECT
    sb.order_id,
    sb.order_item_id,
    dc.customer_key,
    dp.product_key,
    ds.seller_key,
    dd.date_key,
    dpay.payment_key,
    sb.price,
    sb.freight_value,
    ROUND((sb.price + sb.freight_value)::NUMERIC, 2) AS total_sale,
    sb.review_score,
    -- días de entrega (compra -> entrega); GREATEST evita valores negativos
    CASE WHEN sb.order_delivered_customer_date IS NOT NULL
         THEN GREATEST(0, sb.order_delivered_customer_date::DATE
                          - sb.order_purchase_timestamp::DATE)
         ELSE NULL
    END AS delivery_days,
    -- retraso = días entregados por encima de la fecha estimada (0 si llega a tiempo)
    CASE WHEN sb.order_delivered_customer_date IS NOT NULL
          AND sb.order_estimated_delivery_date IS NOT NULL
          AND sb.order_delivered_customer_date::DATE > sb.order_estimated_delivery_date::DATE
         THEN sb.order_delivered_customer_date::DATE
              - sb.order_estimated_delivery_date::DATE
         ELSE 0
    END AS delay_days,
    sb.order_status
FROM sales_base sb
INNER JOIN ecommerce_dw.dim_customer dc ON sb.customer_id = dc.customer_id
INNER JOIN ecommerce_dw.dim_product  dp ON sb.product_id  = dp.product_id
INNER JOIN ecommerce_dw.dim_seller   ds ON sb.seller_id   = ds.seller_id
INNER JOIN ecommerce_dw.dim_payment  dpay
       ON sb.payment_type = dpay.payment_type
      AND sb.payment_installments = dpay.payment_installments
INNER JOIN ecommerce_dw.dim_date     dd ON dd.full_date = sb.order_purchase_timestamp::DATE;

COMMIT;


/*==============================================================================
  PASO 4 · DEMOSTRACIÓN DE TRANSACCIONES (BEGIN / SAVEPOINT / ROLLBACK)
  ------------------------------------------------------------------------------
  Bloque puramente demostrativo: NO altera el DW. Se inserta un registro de
  prueba, se crea un SAVEPOINT, se deshace parte del trabajo con
  ROLLBACK TO SAVEPOINT y finalmente se descarta TODA la transacción con
  ROLLBACK, de modo que nada persiste.
==============================================================================*/
BEGIN;
    -- cambio temporal (no se confirmará)
    INSERT INTO ecommerce_dw.dim_payment (payment_type, payment_installments)
    VALUES ('demo_tx', 1);

    SAVEPOINT antes_de_borrar;

    -- borramos el registro recién insertado
    DELETE FROM ecommerce_dw.dim_payment WHERE payment_type = 'demo_tx';

    -- deshacemos SOLO el DELETE: el registro 'demo_tx' "vuelve a existir"
    ROLLBACK TO SAVEPOINT antes_de_borrar;

ROLLBACK;   -- descartamos toda la transacción: 'demo_tx' nunca llegó a guardarse

/*============================== FIN 02_data.sql =============================*/