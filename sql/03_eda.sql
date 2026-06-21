/*==============================================================================
  FICHERO  : 03_eda.sql   ← NÚCLEO DEL ENTREGABLE
  PROYECTO : Data Warehouse E-commerce (Olist) · PostgreSQL
  AUTOR    : David Naranjo Ramírez

  OBJETIVO : Análisis exploratorio y obtención de insights de negocio sobre
             >112.000 líneas de venta reales, usando SQL básico y avanzado.

  REQUISITO PREVIO: ejecutar 01_schema.sql y 02_data.sql.

  ------------------------------------------------------------------------------
  NOTA SOBRE LAS CIFRAS DE LOS COMENTARIOS
  Los valores numéricos de los comentarios están VERIFICADOS sobre el dataset
  completo de Olist (importes en reais, R$). Reflejan exactamente el resultado
  de cada consulta sobre la carga estándar; si tu carga difiere mínimamente, el
  PATRÓN de negocio se mantiene.

  TÉCNICAS SQL DEMOSTRADAS EN ESTE FICHERO:
  JOIN (INNER/LEFT) · GROUP BY/HAVING · SUM/COUNT/AVG · CASE · CAST ·
  funciones de fecha · subqueries · CTEs encadenadas · funciones ventana
  (OVER PARTITION BY, RANK, NTILE, LAG, SUM OVER) · uso de FUNCTION propia.
==============================================================================*/

SET search_path TO ecommerce_dw;


/*==============================================================================
  SECCIÓN 1 · OVERVIEW DEL DATA WAREHOUSE
  Recuento de filas por tabla del modelo (control de carga).
==============================================================================*/
SELECT 'fact_sales'   AS tabla, COUNT(*) AS registros FROM fact_sales
UNION ALL SELECT 'dim_customer', COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_product',  COUNT(*) FROM dim_product
UNION ALL SELECT 'dim_seller',   COUNT(*) FROM dim_seller
UNION ALL SELECT 'dim_payment',  COUNT(*) FROM dim_payment
UNION ALL SELECT 'dim_date',     COUNT(*) FROM dim_date
ORDER BY registros DESC;


/*==============================================================================
  INSIGHT 1 · KPIs GENERALES DEL NEGOCIO
  Une fact con dim_customer para distinguir CUENTAS de CLIENTES REALES.
==============================================================================*/
SELECT
    COUNT(*)                                   AS total_lineas_venta,
    COUNT(DISTINCT f.order_id)                 AS total_pedidos,
    COUNT(DISTINCT c.customer_unique_id)       AS total_clientes_unicos,
    COUNT(DISTINCT f.seller_key)               AS total_vendedores,
    ROUND(SUM(f.total_sale), 2)                AS ingresos_totales,
    ROUND(AVG(f.total_sale), 2)                AS ticket_medio,
    ROUND(AVG(CAST(f.review_score AS NUMERIC)), 2) AS review_media   -- CAST explícito
FROM fact_sales f
INNER JOIN dim_customer c
    ON f.customer_key = c.customer_key;

-- Cifras reales del DW: 112.647 líneas de venta, 98.665 pedidos y 95.419
-- clientes reales (customer_unique_id). Hay más "cuentas" (customer_id) que
-- personas porque Olist crea un customer_id por pedido. Ingresos = 15.843.409,78
-- (R$), ticket medio 140,65 y valoración media 4,03/5: buen volumen y
-- satisfacción general positiva.


/*==============================================================================
  INSIGHT 2 · EVOLUCIÓN MENSUAL DE VENTAS  (+ acumulado anual con función ventana)
  Funciones de fecha + ventana SUM() OVER (PARTITION BY year ORDER BY month).
==============================================================================*/
SELECT
    d.year,
    d.month,
    COUNT(DISTINCT f.order_id)                       AS pedidos,
    ROUND(SUM(f.total_sale), 2)                      AS ventas,
    ROUND(
        SUM(SUM(f.total_sale)) OVER (
            PARTITION BY d.year ORDER BY d.month
        ), 2)                                        AS acumulado_anual
FROM fact_sales f
INNER JOIN dim_date d
    ON f.date_key = d.date_key
GROUP BY d.year, d.month
ORDER BY d.year, d.month;

-- El negocio crece con fuerza durante 2017 y alcanza su pico en noviembre de
-- 2017 (1.179.143,77 en ventas, por el Black Friday brasileño). El acumulado
-- anual evidencia una marcada estacionalidad de cierre de año. 2016 (solo
-- sep/oct/dic, muy parciales) y los últimos meses de 2018 se interpretan con
-- cautela.


/*==============================================================================
  INSIGHT 3 · TOP 10 CATEGORÍAS POR FACTURACIÓN
  COALESCE para tratar categorías sin traducción / sin categoría.
==============================================================================*/
SELECT
    COALESCE(p.product_category_name_english,
             p.product_category_name, 'sin_categoria') AS categoria,
    COUNT(*)                    AS productos_vendidos,
    ROUND(SUM(f.total_sale), 2) AS ingresos
FROM fact_sales f
INNER JOIN dim_product p
    ON f.product_key = p.product_key
GROUP BY 1
ORDER BY ingresos DESC
LIMIT 10;

-- Fuerte concentración. Lideran health_beauty (1.441.104,61) y watches_gifts
-- (1.305.541,61); en cambio bed_bath_table vende más unidades (11.115) pero
-- factura menos (1.241.681,72) → no solo importa el volumen, también el valor
-- unitario del producto.


/*==============================================================================
  INSIGHT 4 · TOP 10 CATEGORÍAS PEOR VALORADAS  (con filtro de volumen)
  HAVING para excluir categorías con pocas ventas (poco significativas).
==============================================================================*/
SELECT
    COALESCE(p.product_category_name_english,
             p.product_category_name, 'sin_categoria') AS categoria,
    ROUND(AVG(f.review_score), 2) AS review_media,
    COUNT(*)                      AS total_ventas
FROM fact_sales f
INNER JOIN dim_product p
    ON f.product_key = p.product_key
WHERE f.review_score IS NOT NULL
GROUP BY 1
HAVING COUNT(*) > 100
ORDER BY review_media ASC
LIMIT 10;

-- El mobiliario lidera las peores valoraciones: office_furniture cae a 3,49,
-- muy por debajo de la media (4,03). Apunta a problemas logísticos o de daños
-- en productos grandes/voluminosos durante la entrega.


/*==============================================================================
  INSIGHT 5 · VENTAS POR ESTADO (+ cuota de mercado con ventana)
  SUM() OVER () para calcular el % sobre el total sin subconsulta extra.
==============================================================================*/
SELECT
    c.customer_state,
    COUNT(DISTINCT f.order_id)  AS pedidos,
    ROUND(SUM(f.total_sale), 2) AS ingresos,
    ROUND(AVG(f.total_sale), 2) AS ticket_medio,
    ROUND(100.0 * SUM(f.total_sale)
                / SUM(SUM(f.total_sale)) OVER (), 2) AS pct_ingresos
FROM fact_sales f
INNER JOIN dim_customer c
    ON f.customer_key = c.customer_key
GROUP BY c.customer_state
ORDER BY ingresos DESC;

-- São Paulo (SP) concentra el 37,38% de los ingresos, pero con el ticket medio
-- más bajo del top (124,81). Estados como BA muestran tickets más altos (160,97)
-- con mucho menos volumen: distintos patrones de consumo y mercados a desarrollar.

-- Demostración de la FUNCIÓN parametrizada fn_state_revenue (definida en 01_schema):
SELECT
    ecommerce_dw.fn_state_revenue('SP') AS ingresos_sp,
    ecommerce_dw.fn_state_revenue('RJ') AS ingresos_rj,
    ecommerce_dw.fn_state_revenue('MG') AS ingresos_mg;
-- Devuelve 5.921.534,66 / 2.129.681,98 / 1.856.161,49 respectivamente,
-- coincidiendo con la consulta agregada anterior.


/*==============================================================================
  INSIGHT 6 · MÉTODOS DE PAGO MÁS UTILIZADOS
  LEFT JOIN desde dim_payment para incluir métodos aunque no tengan ventas.
==============================================================================*/
SELECT
    p.payment_type,
    COUNT(f.sales_key)                       AS operaciones,
    ROUND(COALESCE(SUM(f.total_sale), 0), 2) AS ventas
FROM dim_payment p
LEFT JOIN fact_sales f
    ON f.payment_key = p.payment_key
GROUP BY p.payment_type
ORDER BY operaciones DESC;

-- Dominio de la tarjeta de crédito: 75,25% de las operaciones y 78,48% del
-- importe. El "boleto" (20,30%) sigue siendo relevante: clientes que demandan
-- métodos alternativos (menor bancarización / pago sin crédito). El tipo
-- 'not_defined' aparece con 0 operaciones porque nunca es el pago principal.


/*==============================================================================
  INSIGHT 7 · RELACIÓN ENTRE RETRASO Y SATISFACCIÓN
  Usa la FUNCIÓN fn_classify_delay() definida en 01_schema.sql.
==============================================================================*/
SELECT
    fn_classify_delay(delay_days)                  AS categoria_retraso,
    COUNT(*)                                       AS pedidos,
    ROUND(AVG(CAST(review_score AS NUMERIC)), 2)   AS review_media
FROM fact_sales
WHERE review_score IS NOT NULL
  AND delivery_days IS NOT NULL   -- solo entregados: el retraso es real, no un pedido pendiente
GROUP BY fn_classify_delay(delay_days)
ORDER BY review_media DESC;

-- Relación directa y muy fuerte (solo pedidos entregados): sin retraso = 4,21
-- de media; retraso leve 3,23; medio 2,09; y los retrasos graves se desploman a
-- 1,70. La logística es el factor crítico de la experiencia de cliente y la
-- principal palanca de mejora. La lógica de clasificación se encapsula en una
-- función reutilizable (fn_classify_delay).


/*==============================================================================
  INSIGHT 8 · RANKING Y SEGMENTACIÓN DE VENDEDORES
  CTEs encadenadas + RANK() + NTILE() (funciones ventana avanzadas).
==============================================================================*/

-- 8.a) Top 10 vendedores por facturación
WITH seller_rev AS (
    SELECT
        s.seller_id,
        s.seller_state,
        ROUND(SUM(f.total_sale), 2) AS ingresos
    FROM fact_sales f
    INNER JOIN dim_seller s
        ON f.seller_key = s.seller_key
    GROUP BY s.seller_id, s.seller_state
),
seller_ranked AS (
    SELECT
        seller_rev.*,
        RANK()    OVER (ORDER BY ingresos DESC) AS ranking,
        NTILE(4)  OVER (ORDER BY ingresos DESC) AS cuartil
    FROM seller_rev
)
SELECT ranking, seller_id, seller_state, ingresos, cuartil
FROM seller_ranked
WHERE ranking <= 10
ORDER BY ranking;

-- 8.b) Concentración de ingresos por cuartil de vendedor
WITH seller_rev AS (
    SELECT s.seller_id, SUM(f.total_sale) AS ingresos
    FROM fact_sales f
    INNER JOIN dim_seller s ON f.seller_key = s.seller_key
    GROUP BY s.seller_id
),
seller_q AS (
    SELECT seller_id, ingresos,
           NTILE(4) OVER (ORDER BY ingresos DESC) AS cuartil
    FROM seller_rev
)
SELECT
    cuartil,
    COUNT(*)                      AS vendedores,
    ROUND(SUM(ingresos), 2)       AS ingresos_cuartil,
    ROUND(100.0 * SUM(ingresos)
                / SUM(SUM(ingresos)) OVER (), 1) AS pct_ingresos
FROM seller_q
GROUP BY cuartil
ORDER BY cuartil;

-- Estructura tipo "power sellers": el cuartil superior (Q1, 774 vendedores)
-- genera el 86,58% de la facturación; el líder factura 249.640,70. La mayoría
-- de vendedores aporta importes muy bajos (Q4 = 0,65%). Distribución aún más
-- concentrada que el 80/20: riesgo de dependencia y oportunidad de diversificar.


/*==============================================================================
  INSIGHT 9 · CRECIMIENTO MENSUAL (%)  ·  CTEs ENCADENADAS + LAG()
==============================================================================*/
WITH monthly_sales AS (
    SELECT d.year, d.month, SUM(f.total_sale) AS ventas
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.date_key = d.date_key
    GROUP BY d.year, d.month
),
growth AS (
    SELECT
        monthly_sales.*,
        LAG(ventas) OVER (ORDER BY year, month) AS ventas_mes_anterior
    FROM monthly_sales
)
SELECT
    year, month,
    ROUND(ventas, 2)               AS ventas,
    ROUND(ventas_mes_anterior, 2)  AS ventas_mes_anterior,
    ROUND((ventas - ventas_mes_anterior)
          / NULLIF(ventas_mes_anterior, 0) * 100, 2) AS crecimiento_pct
FROM growth
ORDER BY year, month;

-- Tras el fuerte despegue de 2017, las tasas de crecimiento intermensual se
-- moderan: transición de una fase de crecimiento explosivo a otra de madurez,
-- donde el reto pasa de "crecer rápido" a "mantener estabilidad y eficiencia".


/*==============================================================================
  INSIGHT 10 · CLIENTES DE ALTO VALOR (PARETO)
  CTEs encadenadas + SUBQUERY (comparación con la media) + CASE + ventana.
==============================================================================*/
WITH customer_spend AS (
    SELECT c.customer_unique_id, SUM(f.total_sale) AS gasto
    FROM fact_sales f
    INNER JOIN dim_customer c
        ON f.customer_key = c.customer_key
    GROUP BY c.customer_unique_id
),
clasif AS (
    SELECT
        customer_unique_id,
        gasto,
        CASE WHEN gasto > (SELECT AVG(gasto) FROM customer_spend)  -- subquery
             THEN 'Por encima de la media'
             ELSE 'Por debajo de la media'
        END AS segmento
    FROM customer_spend
)
SELECT
    segmento,
    COUNT(*)                                              AS clientes,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct_clientes,
    ROUND(SUM(gasto), 2)                                  AS ingresos,
    ROUND(100.0 * SUM(gasto) / SUM(SUM(gasto)) OVER (), 1)AS pct_ingresos
FROM clasif
GROUP BY segmento
ORDER BY ingresos DESC;

-- Patrón Pareto claro: el 29,12% de clientes que gasta por encima de la media
-- (166,04) concentra el 63,87% de los ingresos. Son los clientes de alto valor
-- sobre los que conviene priorizar la fidelización.


/*==============================================================================
  INSIGHT 11 · FIN DE SEMANA VS ENTRE SEMANA
  CASE para etiquetar el tipo de día a partir del flag is_weekend.
==============================================================================*/
SELECT
    CASE WHEN d.is_weekend THEN 'Fin de semana' ELSE 'Entre semana' END AS tipo_dia,
    COUNT(DISTINCT f.order_id)  AS pedidos,
    ROUND(SUM(f.total_sale), 2) AS ingresos,
    ROUND(AVG(f.total_sale), 2) AS ticket_medio
FROM fact_sales f
INNER JOIN dim_date d
    ON f.date_key = d.date_key
GROUP BY d.is_weekend
ORDER BY ingresos DESC;

-- El grueso del negocio ocurre entre semana (76,99% de los pedidos), pero el
-- ticket medio es casi idéntico (140,51 entre semana vs 141,13 en fin de
-- semana): el día no cambia el PODER de gasto, solo el VOLUMEN. Palanca de
-- crecimiento: activar más demanda en fin de semana, no subir el ticket.


/*==============================================================================
  INSIGHT 12 · TASA DE RECOMPRA (RETENCIÓN)
  CTE + CASE + ventana. Mide cuántos clientes REALES repiten compra.
==============================================================================*/
WITH orders_per_customer AS (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT f.order_id) AS num_pedidos,
        SUM(f.total_sale)          AS gasto
    FROM fact_sales f
    INNER JOIN dim_customer c
        ON f.customer_key = c.customer_key
    GROUP BY c.customer_unique_id
)
SELECT
    CASE WHEN num_pedidos > 1 THEN 'Recurrente' ELSE 'Único' END AS tipo_cliente,
    COUNT(*)                                              AS clientes,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)    AS pct_clientes,
    ROUND(SUM(gasto), 2)                                  AS ingresos,
    ROUND(100.0 * SUM(gasto) / SUM(SUM(gasto)) OVER (), 2)AS pct_ingresos
FROM orders_per_customer
GROUP BY CASE WHEN num_pedidos > 1 THEN 'Recurrente' ELSE 'Único' END
ORDER BY clientes DESC;

-- Hallazgo de negocio clave: la tasa de recompra es MUY baja: solo el 3,05% de
-- los clientes (2.913) repiten, y aportan apenas el 5,71% de los ingresos. Olist
-- capta bien clientes nuevos pero apenas los retiene. La mayor oportunidad de
-- crecimiento no está solo en adquirir, sino en fidelizar: email marketing,
-- programas de recompra y mejora logística (ver INSIGHT 7).


/*============================== FIN DEL EDA =================================*/