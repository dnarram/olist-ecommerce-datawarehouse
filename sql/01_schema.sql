/*==============================================================================
  PROYECTO : Data Warehouse E-commerce (Olist)
  MOTOR    : PostgreSQL
  AUTOR    : David Naranjo Ramírez
  MÓDULO   : SQL · Máster en Data Science (Evolve)

  FICHERO  : 01_schema.sql
  CONTENIDO: Creación completa del esquema del Data Warehouse.
             - Capa STAGING (datos crudos del CSV)
             - Capa DIMENSIONAL (modelo en estrella limpio)
             - Tabla de HECHOS
             - Constraints (PK, FK, UNIQUE, CHECK, DEFAULT, NOT NULL)
             - Índices (con justificación)
             - Vistas de negocio
             - Funciones

  --------------------------------------------------------------------------
  MODELO DE DATOS — STAR SCHEMA
  --------------------------------------------------------------------------
  1 tabla de hechos (fact_sales) + 5 dimensiones:
      fact_sales ──< dim_customer
                 ──< dim_product
                 ──< dim_seller
                 ──< dim_payment
                 ──< dim_date

  GRANULARIDAD DE LA FACT:
      1 fila = 1 línea de producto dentro de un pedido
      (equivale a una fila de olist_order_items).

  ALCANCE (qué entra / qué queda fuera):
      DENTRO  -> pedidos con líneas de venta y método de pago identificable.
      FUERA   -> geolocalización a nivel de coordenada (solo se usa el estado
                 que ya viene en customers/sellers), reseñas en texto libre
                 (solo se usa la puntuación) y pedidos sin registro de pago
                 (decisión de alcance documentada en 02_data.sql).

  JUSTIFICACIÓN DE LA NORMALIZACIÓN:
      - Las tablas STAGING reproducen el CSV "tal cual" (sin claves), porque
        su único objetivo es servir de zona de aterrizaje para el ETL.
      - El modelo DIMENSIONAL sigue un esquema en estrella: las dimensiones
        están ligeramente desnormalizadas a propósito (p. ej. dim_product
        guarda categoría + traducción + medidas) para favorecer consultas
        analíticas rápidas y legibles, evitando JOINs en cascada.
      - Cada dimensión usa una CLAVE SUSTITUTA (surrogate key) numérica como
        PK, en lugar de la clave de negocio (VARCHAR de 32 chars). Esto hace
        los JOINs de la fact más eficientes y aísla el DW de cambios en los
        identificadores de origen. La clave de negocio se conserva con un
        UNIQUE para garantizar la integridad y permitir el ETL.
      - dim_date es la excepción: usa una "smart key" entera AAAAMMDD como PK,
        práctica estándar en data warehousing para fechas.
==============================================================================*/

-- Reproducible desde cero: si el esquema existe, se elimina y se recrea.
DROP SCHEMA IF EXISTS ecommerce_dw CASCADE;
CREATE SCHEMA ecommerce_dw;

SET search_path TO ecommerce_dw;


/*==============================================================================
  CAPA 1 · STAGING
  Zona de aterrizaje de los CSV. Sin PK/FK: solo tipado básico.
  La carga de estos datos se realiza en 02_data.sql (PASO 0).
==============================================================================*/

CREATE TABLE ecommerce_dw.stg_orders (
    order_id                      VARCHAR(50),
    customer_id                   VARCHAR(50),
    order_status                  VARCHAR(30),
    order_purchase_timestamp      TIMESTAMP,
    order_approved_at             TIMESTAMP,
    order_delivered_carrier_date  TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

CREATE TABLE ecommerce_dw.stg_order_items (
    order_id            VARCHAR(50),
    order_item_id       INTEGER,
    product_id          VARCHAR(50),
    seller_id           VARCHAR(50),
    shipping_limit_date TIMESTAMP,
    price               NUMERIC(10,2),
    freight_value       NUMERIC(10,2)
);

CREATE TABLE ecommerce_dw.stg_order_payments (
    order_id             VARCHAR(50),
    payment_sequential   INTEGER,
    payment_type         VARCHAR(50),
    payment_installments INTEGER,
    payment_value        NUMERIC(10,2)
);

CREATE TABLE ecommerce_dw.stg_order_reviews (
    review_id               VARCHAR(50),
    order_id                VARCHAR(50),
    review_score            INTEGER,
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TIMESTAMP,
    review_answer_timestamp TIMESTAMP
);

CREATE TABLE ecommerce_dw.stg_customers (
    customer_id              VARCHAR(50),
    customer_unique_id       VARCHAR(50),
    customer_zip_code_prefix INTEGER,
    customer_city            VARCHAR(100),
    customer_state           VARCHAR(10)
);

-- IMPORTANTE: los nombres de columna replican EXACTAMENTE la cabecera del CSV
-- de Olist, que trae la errata "lenght" (en lugar de "length") en
-- product_name_lenght y product_description_lenght. Mantenerlos idénticos al
-- CSV permite que la carga funcione tanto por \copy (posicional) como por la
-- interfaz de DBeaver. La ortografía se corrige al pasar a la dimensión 
--(dim_product) en 02_data.sql.
CREATE TABLE ecommerce_dw.stg_products (
    product_id                 VARCHAR(50),
    product_category_name      VARCHAR(100),
    product_name_lenght        INTEGER,   -- errata del dataset original
    product_description_lenght INTEGER,   -- errata del dataset original
    product_photos_qty         INTEGER,
    product_weight_g           NUMERIC,
    product_length_cm          NUMERIC,
    product_height_cm          NUMERIC,
    product_width_cm           NUMERIC
);

CREATE TABLE ecommerce_dw.stg_sellers (
    seller_id              VARCHAR(50),
    seller_zip_code_prefix INTEGER,
    seller_city            VARCHAR(100),
    seller_state           VARCHAR(10)
);

CREATE TABLE ecommerce_dw.stg_geolocation (
    geolocation_zip_code_prefix INTEGER,
    geolocation_lat             NUMERIC(12,8),
    geolocation_lng             NUMERIC(12,8),
    geolocation_city            VARCHAR(100),
    geolocation_state           VARCHAR(10)
);

CREATE TABLE ecommerce_dw.stg_category_translation (
    product_category_name         VARCHAR(100),
    product_category_name_english VARCHAR(100)
);


/*==============================================================================
  CAPA 2 · MODELO DIMENSIONAL (STAR SCHEMA)
  Tablas limpias con PK, claves de negocio UNIQUE, NOT NULL, CHECK y DEFAULT.
==============================================================================*/

-- ----------------------------------------------------------------------------
-- dim_customer
-- Grano: 1 fila = 1 cuenta operativa de cliente (customer_id).
-- Nota Olist: customer_id es único por pedido; customer_unique_id identifica
-- a la PERSONA real y puede repetirse (se usa para contar clientes únicos).
-- ----------------------------------------------------------------------------
CREATE TABLE ecommerce_dw.dim_customer (
    customer_key             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id              VARCHAR(50) NOT NULL,           -- clave de negocio
    customer_unique_id       VARCHAR(50) NOT NULL,           -- cliente real
    customer_zip_code_prefix INTEGER,
    customer_city            VARCHAR(100),
    customer_state           VARCHAR(10),
    load_ts                  TIMESTAMP NOT NULL DEFAULT now(),-- DEFAULT
    CONSTRAINT uq_dim_customer_bk UNIQUE (customer_id)        -- evita duplicados
);
COMMENT ON TABLE ecommerce_dw.dim_customer IS '1 fila = 1 cuenta de cliente (customer_id). customer_unique_id = persona real.';

-- ----------------------------------------------------------------------------
-- dim_seller
-- Grano: 1 fila = 1 vendedor.
-- ----------------------------------------------------------------------------
CREATE TABLE ecommerce_dw.dim_seller (
    seller_key             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seller_id              VARCHAR(50) NOT NULL,
    seller_zip_code_prefix INTEGER,
    seller_city            VARCHAR(100),
    seller_state           VARCHAR(10),
    load_ts                TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_seller_bk UNIQUE (seller_id)
);
COMMENT ON TABLE ecommerce_dw.dim_seller IS '1 fila = 1 vendedor (seller_id).';

-- ----------------------------------------------------------------------------
-- dim_product
-- Grano: 1 fila = 1 producto. Incluye categoría original + traducción al
-- inglés (desnormalización controlada para evitar un JOIN extra en el EDA).
-- ----------------------------------------------------------------------------
CREATE TABLE ecommerce_dw.dim_product (
    product_key                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id                    VARCHAR(50) NOT NULL,
    product_category_name         VARCHAR(100),
    product_category_name_english VARCHAR(100),
    product_name_length           INTEGER,
    product_description_length    INTEGER,
    product_photos_qty            INTEGER,
    product_weight_g              NUMERIC,
    product_length_cm             NUMERIC,
    product_height_cm             NUMERIC,
    product_width_cm              NUMERIC,
    load_ts                       TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT uq_dim_product_bk UNIQUE (product_id)
);
COMMENT ON TABLE ecommerce_dw.dim_product IS '1 fila = 1 producto (product_id). Categoría con traducción incorporada.';

-- ----------------------------------------------------------------------------
-- dim_payment  (dimensión "junk": combinaciones de método + nº de cuotas)
-- Grano: 1 fila = 1 combinación única (payment_type, payment_installments).
-- ----------------------------------------------------------------------------
CREATE TABLE ecommerce_dw.dim_payment (
    payment_key          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_type         VARCHAR(50) NOT NULL,
    payment_installments INTEGER     NOT NULL,
    CONSTRAINT uq_dim_payment_bk UNIQUE (payment_type, payment_installments),
    CONSTRAINT chk_payment_installments CHECK (payment_installments >= 0)
);
COMMENT ON TABLE ecommerce_dw.dim_payment IS '1 fila = 1 combinación (tipo de pago, nº de cuotas).';

-- ----------------------------------------------------------------------------
-- dim_date  (dimensión de calendario con smart key AAAAMMDD)
-- Grano: 1 fila = 1 día natural.
-- ----------------------------------------------------------------------------
CREATE TABLE ecommerce_dw.dim_date (
    date_key     INTEGER PRIMARY KEY,                 -- AAAAMMDD (smart key)
    full_date    DATE        NOT NULL,
    year         INTEGER     NOT NULL,
    quarter      INTEGER     NOT NULL,
    month        INTEGER     NOT NULL,
    month_name   VARCHAR(20),
    week         INTEGER,
    day          INTEGER     NOT NULL,
    weekday_name VARCHAR(20),
    is_weekend   BOOLEAN     NOT NULL DEFAULT FALSE,
    CONSTRAINT uq_dim_date_fulldate UNIQUE (full_date),
    CONSTRAINT chk_month   CHECK (month   BETWEEN 1 AND 12),
    CONSTRAINT chk_quarter CHECK (quarter BETWEEN 1 AND 4)
);
COMMENT ON TABLE ecommerce_dw.dim_date IS '1 fila = 1 día natural. PK = AAAAMMDD.';

-- ----------------------------------------------------------------------------
-- fact_sales  (TABLA DE HECHOS)
-- Grano: 1 fila = 1 línea de producto dentro de un pedido.
-- Claves foráneas a las 5 dimensiones (todas NOT NULL: el ETL solo inserta
-- líneas con dimensión existente, por lo que no puede haber huérfanos).
-- ----------------------------------------------------------------------------
CREATE TABLE ecommerce_dw.fact_sales (
    sales_key     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      VARCHAR(50) NOT NULL,
    order_item_id INTEGER     NOT NULL,

    -- Claves foráneas (modelo en estrella)
    customer_key  BIGINT  NOT NULL REFERENCES ecommerce_dw.dim_customer(customer_key),
    product_key   BIGINT  NOT NULL REFERENCES ecommerce_dw.dim_product(product_key),
    seller_key    BIGINT  NOT NULL REFERENCES ecommerce_dw.dim_seller(seller_key),
    date_key      INTEGER NOT NULL REFERENCES ecommerce_dw.dim_date(date_key),
    payment_key   BIGINT  NOT NULL REFERENCES ecommerce_dw.dim_payment(payment_key),

    -- Métricas
    price         NUMERIC(10,2) NOT NULL,
    freight_value NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_sale    NUMERIC(12,2) NOT NULL,
    review_score  INTEGER,                       -- NULL = pedido sin reseña
    delivery_days INTEGER,                       -- días compra -> entrega
    delay_days    INTEGER NOT NULL DEFAULT 0,    -- días sobre la fecha estimada
    order_status  VARCHAR(30),

    -- Integridad y reglas de negocio
    CONSTRAINT uq_fact_order_line UNIQUE (order_id, order_item_id),
    CONSTRAINT chk_price_nonneg    CHECK (price >= 0),
    CONSTRAINT chk_freight_nonneg  CHECK (freight_value >= 0),
    CONSTRAINT chk_total_nonneg    CHECK (total_sale >= 0),
    CONSTRAINT chk_review_range    CHECK (review_score IS NULL OR review_score BETWEEN 1 AND 5),
    CONSTRAINT chk_delivery_nonneg CHECK (delivery_days IS NULL OR delivery_days >= 0),
    CONSTRAINT chk_delay_nonneg    CHECK (delay_days >= 0)
);
COMMENT ON TABLE ecommerce_dw.fact_sales IS '1 fila = 1 línea de producto en un pedido (grano de olist_order_items).';


/*==============================================================================
  CAPA 3 · ÍNDICES
  PostgreSQL crea índice automáticamente en las PK y en las columnas UNIQUE,
  pero NO en las claves foráneas. Indexamos las FK de la fact porque todas las
  consultas del EDA hacen "star join" fact -> dimensión y agrupan por sus
  atributos. El índice sobre date_key es el más rentable: acelera los filtros
  y agrupaciones temporales (evolución mensual, crecimiento, estacionalidad),
  que son las consultas más frecuentes del análisis.
  (En 112k filas el planificador puede optar por seq scan; los índices
   muestran la buena práctica y benefician filtros selectivos y point-lookups.)
==============================================================================*/

CREATE INDEX IF NOT EXISTS idx_fact_date     ON ecommerce_dw.fact_sales(date_key);
CREATE INDEX IF NOT EXISTS idx_fact_product  ON ecommerce_dw.fact_sales(product_key);
CREATE INDEX IF NOT EXISTS idx_fact_customer ON ecommerce_dw.fact_sales(customer_key);
CREATE INDEX IF NOT EXISTS idx_fact_seller   ON ecommerce_dw.fact_sales(seller_key);
CREATE INDEX IF NOT EXISTS idx_fact_payment  ON ecommerce_dw.fact_sales(payment_key);


/*==============================================================================
  CAPA 4 · VISTAS DE NEGOCIO  (mínimo 2 requeridas)
  Capa semántica que encapsula dos agregaciones de negocio reutilizables.
  NOTA: estas dos vistas son las que refleja el diagrama ER (docs/model.png),
  de modo que diagrama y código quedan sincronizados.
==============================================================================*/

-- VISTA 1: evolución mensual de ventas (volumen, pedidos, ingresos, satisfacción)
CREATE OR REPLACE VIEW ecommerce_dw.vw_monthly_sales AS
SELECT
    d.year,
    d.month,
    d.month_name,
    COUNT(*)                       AS total_items_sold,
    COUNT(DISTINCT f.order_id)     AS total_orders,
    ROUND(SUM(f.total_sale), 2)    AS revenue,
    ROUND(AVG(f.review_score), 2)  AS avg_review_score
FROM ecommerce_dw.fact_sales f
INNER JOIN ecommerce_dw.dim_date d
    ON f.date_key = d.date_key
GROUP BY d.year, d.month, d.month_name;

-- VISTA 2: rendimiento por vendedor (ranking, volumen, ingresos, satisfacción)
CREATE OR REPLACE VIEW ecommerce_dw.vw_seller_performance AS
SELECT
    s.seller_id,
    s.seller_city,
    s.seller_state,
    COUNT(*)                       AS total_items_sold,
    COUNT(DISTINCT f.order_id)     AS total_orders,
    ROUND(SUM(f.total_sale), 2)    AS revenue,
    ROUND(AVG(f.review_score), 2)  AS avg_review_score
FROM ecommerce_dw.fact_sales f
INNER JOIN ecommerce_dw.dim_seller s
    ON f.seller_key = s.seller_key
GROUP BY s.seller_id, s.seller_city, s.seller_state;


/*==============================================================================
  CAPA 5 · FUNCIONES  (se entregan 2)
==============================================================================*/

-- FUNCIÓN 1: clasifica el retraso de entrega en una categoría de negocio.
-- IMMUTABLE (depende solo de su input) -> se usa en el INSIGHT 7 del EDA.
CREATE OR REPLACE FUNCTION ecommerce_dw.fn_classify_delay(p_delay_days INTEGER)
RETURNS VARCHAR
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_delay_days IS NULL THEN
        RETURN 'Sin información';
    ELSIF p_delay_days = 0 THEN
        RETURN 'Sin retraso';
    ELSIF p_delay_days BETWEEN 1 AND 3 THEN
        RETURN 'Retraso leve';
    ELSIF p_delay_days BETWEEN 4 AND 7 THEN
        RETURN 'Retraso medio';
    ELSE
        RETURN 'Retraso grave';
    END IF;
END;
$$;

-- FUNCIÓN 2: devuelve la facturación total de un estado (consulta parametrizada).
-- STABLE (lee tablas pero no las modifica). Ejemplo de uso:
--     SELECT ecommerce_dw.fn_state_revenue('SP');
CREATE OR REPLACE FUNCTION ecommerce_dw.fn_state_revenue(p_state VARCHAR)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(ROUND(SUM(f.total_sale), 2), 0)
    FROM ecommerce_dw.fact_sales f
    INNER JOIN ecommerce_dw.dim_customer c
        ON f.customer_key = c.customer_key
    WHERE c.customer_state = p_state;
$$;

/*============================== FIN 01_schema.sql ============================*/

