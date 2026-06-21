# Data Warehouse para Análisis de E-commerce con SQL (Olist)

Diseño, implementación y análisis de un **Data Warehouse relacional en estrella** sobre el dataset público de **Olist** (e-commerce brasileño), desarrollado en **PostgreSQL + DBeaver** como entrega del **Módulo SQL del Máster en Data Science de Evolve**.

El proyecto transforma datos transaccionales reales en un modelo dimensional limpio y responde **12 preguntas de negocio** mediante SQL básico y avanzado. Todas las cifras citadas en el código y en este documento están **verificadas** sobre el dataset completo (importes en reais, R$).

**Autor:** David Naranjo Ramírez

---

## 1. Objetivos

- Diseñar un modelo dimensional tipo *Star Schema* coherente y normalizado de forma controlada.
- Implementar el Data Warehouse desde cero, de forma reproducible.
- Garantizar la integridad de los datos mediante constraints y un script de calidad.
- Aplicar SQL básico y avanzado (CTEs, funciones ventana, subqueries, transacciones, funciones, vistas).
- Extraer insights accionables sobre ventas, clientes, productos, vendedores y logística.

---

## 2. Dataset

Datos: los 9 CSV de Olist no se incluyen en el repositorio por tamaño. Descárgalos del dataset Brazilian E-Commerce Public Dataset by Olist (Kaggle) y colócalos en data/csv/. La estructura de tablas y la carga están descritas en sql/01_schema.sql y sql/02_data.sql.

**Olist Brazilian E-commerce** — pedidos reales realizados en Brasil entre septiembre de 2016 y octubre de 2018.

Volúmenes de origen (recuento exacto de los CSV):

| Tabla origen | Filas |
|---|---|
| `olist_order_items` (líneas de venta) | 112.650 |
| `olist_orders` (pedidos) | 99.441 |
| `olist_customers` (cuentas de cliente) | 99.441 |
| — de los cuales clientes reales (`customer_unique_id`) | 96.096 |
| `olist_order_payments` | 103.886 |
| `olist_order_reviews` | 104.719 |
| `olist_products` | 32.951 |
| `olist_sellers` | 3.095 |
| `olist_geolocation` | 1.000.163 |
| `product_category_name_translation` | 70 |

> **Matiz importante del modelo:** en Olist, `customer_id` es una clave **operativa que se crea por cada pedido**, mientras que `customer_unique_id` identifica a la **persona real**. Por eso hay 96.096 personas frente a 99.441 cuentas. El proyecto cuenta clientes reales con `customer_unique_id`.

> **Sobre las cifras del análisis:** la tabla de hechos contiene **112.647 líneas** (las 112.650 de origen menos las 3 de un único pedido sin registro de pago) y agrupa **98.665 pedidos** de **95.419 clientes reales** (los que sobreviven al ETL; el total de personas en el origen es 96.096).

---

## 3. Arquitectura por capas

```text
CSV  ──►  STAGING  ──►  MODELO DIMENSIONAL  ──►  VISTAS  ──►  EDA / INSIGHTS
        (stg_*)        (dim_* + fact_sales)     (vw_*)      (03_eda.sql)
```

- **Staging** (`stg_*`): zona de aterrizaje de los CSV, sin claves, solo tipado.
- **Dimensional** (`dim_*`, `fact_sales`): modelo en estrella limpio con PK, FK y constraints.
- **Vistas** (`vw_*`): capa semántica de negocio reutilizable.
- **EDA**: consultas analíticas e insights (núcleo del entregable).

### Modelo en estrella

```text
                 dim_date
                    │
 dim_customer ── fact_sales ── dim_product
                  │     │
         dim_payment│ dim_seller
```

**Tabla de hechos:** `fact_sales`
**Granularidad:** 1 fila = 1 línea de producto dentro de un pedido (grano de `order_items`).

**Dimensiones:** `dim_customer`, `dim_product`, `dim_seller`, `dim_payment`, `dim_date`.

### Decisiones de diseño

- **Claves sustitutas** (`BIGINT GENERATED ALWAYS AS IDENTITY`) en las dimensiones y la fact: JOINs más eficientes y aislamiento frente a cambios en los IDs de origen. La clave de negocio se conserva con `UNIQUE`.
- `dim_date` usa una *smart key* entera `AAAAMMDD` (práctica estándar en data warehousing).
- Desnormalización controlada (estrella): `dim_product` incorpora categoría + traducción para evitar JOINs en cascada en el EDA.
- **FK NOT NULL en la fact**: el ETL solo inserta líneas con dimensión existente, por lo que no puede haber huérfanos por construcción.
- **Pago principal por pedido**: un pedido puede tener varios pagos; en la fact se conserva el de mayor importe (`ROW_NUMBER`), porque la dimensión de pago describe *cómo* se pagó, no *cuánto*.
- **Reseña más reciente por pedido**: un pedido puede tener varias reseñas (789 `review_id` repetidos en origen); el ETL conserva la última.
- **Errata del dataset**: `olist_products` trae una errata de Olist en las cabeceras `product_name_lenght` y `product_description_lenght` (con "lenght"). El staging las replica **idénticas al CSV** para que la carga funcione tanto por `\copy` (posicional) como por la interfaz de DBeaver (que empareja por nombre); la ortografía se corrige al pasar a `dim_product`.

---

## 4. Estructura del repositorio

```text
project/
├── data/
│   └── csv/                     # los 9 CSV de Olist
├── sql/
│   ├── 01_schema.sql            # esquema, constraints, índices, vistas, funciones
│   ├── 02_data.sql              # carga (staging + ETL) y transacciones
│   ├── 03_eda.sql               # EDA + 12 insights  ← CORE
│   └── 04_quality_checks.sql    # validación y correcciones de calidad
├── docs/
│   └── model.png                # diagrama ER (coherente con 01_schema.sql)
└── README.md
```

---

## 5. Cómo ejecutarlo

> Requiere PostgreSQL. Orden obligatorio: **01 → 02 → 03 → 04**.

1. **Crear el esquema y los objetos:**
   ```bash
   psql -d tu_basededatos -f sql/01_schema.sql
   ```
2. **Cargar los CSV en staging.** Dos opciones (elige una):
   - **(A) Reproducible con `psql`:** descomenta el bloque `\copy` del `PASO 0` en `02_data.sql` y ajusta la ruta a `data/csv/`.
   - **(B) Interfaz de DBeaver:** clic derecho sobre cada tabla `stg_*` → *Import Data* → CSV.
3. **Ejecutar el ETL** (carga de dimensiones y fact):
   ```bash
   psql -d tu_basededatos -f sql/02_data.sql
   ```
4. **Lanzar el análisis** (`03_eda.sql`) y la **auditoría de calidad** (`04_quality_checks.sql`).

El esquema se recrea desde cero (`DROP SCHEMA IF EXISTS ... CASCADE`), por lo que el proyecto es **idempotente**: puede ejecutarse tantas veces como se quiera.

---

## 6. Técnicas SQL cubiertas

| Requisito del enunciado | Dónde |
|---|---|
| `CREATE TABLE`, PK, FK, `UNIQUE`, `CHECK`, `NOT NULL`, `DEFAULT` | `01_schema.sql` |
| `IF EXISTS` / `IF NOT EXISTS` (ejecutable desde cero) | `01` (DROP SCHEMA, CREATE INDEX) |
| `INSERT` / `UPDATE` / `DELETE` | `02` (insert/ETL) · `04` (update/delete) |
| `CAST` explícito | `02` (`date_key`, `total_sale`) · `03` (Insight 1, 7) |
| Funciones de fecha (`generate_series`, `EXTRACT`, `TO_CHAR`) | `02` (`dim_date`) |
| `SUM` / `COUNT` / `AVG` | `03` (todos los insights) |
| Subqueries | `03` (Insight 10) |
| ≥3 JOINs con `INNER` y `LEFT` | `02` y `03` (INNER en la fact, LEFT en traducción y pagos) |
| `CASE` y lógica condicional | `03` (Insights 11, 12) y `fn_classify_delay` |
| CTEs encadenadas (`WITH`) | `03` (Insights 8, 9, 10) |
| Funciones ventana `OVER (PARTITION BY ...)` | `03` (`RANK`, `NTILE`, `LAG`, `SUM OVER`) |
| Transacciones `BEGIN` / `COMMIT` / `ROLLBACK` | `02` (SAVEPOINT + ROLLBACK) · `04` |
| ≥1 índice con explicación | `01` (5 índices sobre las FK de la fact) |
| ≥1 `VIEW` + ≥1 `FUNCTION` | `01` (**2 vistas** + **2 funciones**) |

**Vistas:** `vw_monthly_sales` (evolución mensual: volumen, pedidos, ingresos y valoración) y `vw_seller_performance` (rendimiento por vendedor). Son exactamente las dos que muestra el diagrama ER.
**Funciones:** `fn_classify_delay` (clasifica el retraso; se usa en el Insight 7) y `fn_state_revenue` (facturación por estado, parametrizada; se demuestra en el Insight 5).

---

## 7. Calidad de datos (`04_quality_checks.sql`)

Auditoría reproducible que detecta y corrige:

- **Nulos** en campos críticos (`IS NULL` / cadenas vacías con `btrim`), distinguiendo nulos legítimos (610 productos sin categoría; 942 líneas de la fact sin reseña) de problemas reales.
- **Duplicados** (`GROUP BY ... HAVING COUNT(*) > 1`) en staging y en la fact, y limpieza con `ROW_NUMBER()`.
- **Tipos / fechas incorrectos** (`information_schema`, fechas no convertibles).
- **Outliers / rangos**: importes y retrasos negativos, `review_score` fuera de `[1,5]`, cuotas inválidas.
- **Integridad referencial**: huérfanos en la fact con el patrón `LEFT JOIN ... IS NULL` (siempre 0 gracias a las FK).

Gracias a las constraints del esquema, la mayoría de comprobaciones devuelven **0**: el modelo nace limpio y el script lo demuestra. La única exclusión consciente del ETL es 1 pedido sin registro de pago (= 3 líneas de venta).

---

## 8. Preguntas de negocio respondidas (12 insights)

1. **KPIs generales**: 112.647 líneas, 98.665 pedidos, 95.419 clientes reales, 15.843.409,78 en ingresos, ticket medio 140,65 y valoración 4,03/5.
2. **Evolución mensual** de ventas + acumulado anual (ventana).
3. **Top categorías** por facturación.
4. **Categorías peor valoradas** (con filtro de volumen).
5. **Ventas por estado** + cuota de mercado.
6. **Métodos de pago** más utilizados.
7. **Retraso de entrega vs satisfacción** (usa la función propia).
8. **Ranking y segmentación de vendedores** (RANK + NTILE, cuartiles).
9. **Crecimiento mensual %** (LAG).
10. **Clientes de alto valor** (Pareto, subquery + CASE).
11. **Fin de semana vs entre semana**.
12. **Tasa de recompra / retención** (hallazgo clave).

### Hallazgos destacados

- **Estacionalidad de cierre de año**: pico en noviembre de 2017 (1.179.143,77, por el Black Friday).
- **Concentración geográfica**: São Paulo concentra el 37,38% de los ingresos, con el ticket medio más bajo del top (124,81).
- **Dominio de la tarjeta de crédito**: 75,25% de las operaciones y 78,48% del importe; el *boleto* sigue relevante (20,30%).
- **La logística manda**: en pedidos entregados, los retrasos graves hunden la valoración de 4,21 a 1,70.
- **Power sellers**: el cuartil superior de vendedores genera el 86,58% de la facturación.
- **Retención muy baja**: solo el 3,05% de los clientes repiten (aportan el 5,71% de los ingresos) → la mayor oportunidad de negocio está en la fidelización.

---

## 9. Tecnologías

PostgreSQL · DBeaver · Visual Studio Code · Git · GitHub

---

## Autor

David Naranjo Ramírez

Máster en Data Science — Evolve

Proyecto académico desarrollado para el módulo SQL.
