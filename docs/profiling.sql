-- =============================================================================
-- theLook Analytics - Phase 1: exploration and data profiling
-- Source : bigquery-public-data.thelook_ecommerce (read-only, remote)
-- Run each block separately in BigQuery Studio and record the figures
-- in docs/data_quality_register.md
-- =============================================================================


-- =============================================================================
-- 1. INVENTORY - how big is each table?
-- Metadata only: this query scans no table data.
-- =============================================================================
SELECT
    table_id,
    row_count,
    ROUND(size_bytes / POW(1024, 2), 1) AS size_mb,
    TIMESTAMP_MILLIS(last_modified_time) AS last_modified
FROM `bigquery-public-data.thelook_ecommerce.__TABLES__`
ORDER BY size_bytes DESC;


-- =============================================================================
-- 2. SCHEMA - columns and types of every table
-- Run this first: it is the reference for every query below.
-- If a column name differs from the ones used here, fix the query, not the data.
-- =============================================================================
SELECT
    table_name,
    ordinal_position,
    column_name,
    data_type,
    is_nullable
FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.COLUMNS`
ORDER BY table_name, ordinal_position;


-- =============================================================================
-- 3. KEYS - uniqueness and nullability
-- A key must be unique AND never null. Anything else becomes a dbt test later.
-- =============================================================================
WITH k AS (
  SELECT 'users.id'           AS key_name, CAST(id       AS STRING) AS key_value FROM `bigquery-public-data.thelook_ecommerce.users`
  UNION ALL
  SELECT 'orders.order_id',   CAST(order_id AS STRING)              FROM `bigquery-public-data.thelook_ecommerce.orders`
  UNION ALL
  SELECT 'order_items.id',    CAST(id       AS STRING)              FROM `bigquery-public-data.thelook_ecommerce.order_items`
  UNION ALL
  SELECT 'products.id',       CAST(id       AS STRING)              FROM `bigquery-public-data.thelook_ecommerce.products`
  UNION ALL
  SELECT 'inventory_items.id', CAST(id      AS STRING)              FROM `bigquery-public-data.thelook_ecommerce.inventory_items`
)
SELECT
    key_name,
    COUNT(*)                                  AS total_rows,
    COUNT(DISTINCT key_value)                 AS distinct_values,
    COUNTIF(key_value IS NULL)                AS null_values,
    COUNT(*) - COUNT(DISTINCT key_value)      AS duplicated_rows
FROM k
GROUP BY key_name
ORDER BY key_name;


-- 3b. If duplicates show up, list the offending keys (adapt the table)
SELECT order_id, COUNT(*) AS occurrences
FROM `bigquery-public-data.thelook_ecommerce.orders`
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC
LIMIT 20;


-- =============================================================================
-- 4. REFERENTIAL INTEGRITY - orphan rows
-- Every order item should point to an existing order, product and user.
-- =============================================================================
SELECT
    COUNT(*)                        AS order_items_rows,
    COUNTIF(o.order_id IS NULL)     AS items_without_order,
    COUNTIF(p.id IS NULL)           AS items_without_product,
    COUNTIF(u.id IS NULL)           AS items_without_user,
    COUNTIF(ii.id IS NULL)          AS items_without_inventory_item
FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
LEFT JOIN `bigquery-public-data.thelook_ecommerce.orders`          o  ON o.order_id = oi.order_id
LEFT JOIN `bigquery-public-data.thelook_ecommerce.products`        p  ON p.id       = oi.product_id
LEFT JOIN `bigquery-public-data.thelook_ecommerce.users`           u  ON u.id       = oi.user_id
LEFT JOIN `bigquery-public-data.thelook_ecommerce.inventory_items` ii ON ii.id      = oi.inventory_item_id;


-- 4b. The other direction: orders with no line at all
SELECT COUNT(*) AS orders_without_items
FROM `bigquery-public-data.thelook_ecommerce.orders` o
LEFT JOIN `bigquery-public-data.thelook_ecommerce.order_items` oi USING (order_id)
WHERE oi.order_id IS NULL;


-- 4c. Products pointing to a distribution center that does not exist
SELECT COUNT(*) AS products_without_dc
FROM `bigquery-public-data.thelook_ecommerce.products` p
LEFT JOIN `bigquery-public-data.thelook_ecommerce.distribution_centers` dc
       ON dc.id = p.distribution_center_id
WHERE dc.id IS NULL;


-- =============================================================================
-- 5. TIME CONSISTENCY - the richest source of anomalies
-- An item cannot ship before it is created, nor be delivered before it ships.
-- =============================================================================
SELECT
    COUNT(*)                                                   AS total_rows,
    COUNTIF(shipped_at   < created_at)                         AS shipped_before_created,
    COUNTIF(delivered_at < shipped_at)                         AS delivered_before_shipped,
    COUNTIF(returned_at  < delivered_at)                       AS returned_before_delivered,
    COUNTIF(created_at   > CURRENT_TIMESTAMP())                AS created_in_future,
    COUNTIF(delivered_at > CURRENT_TIMESTAMP())                AS delivered_in_future,
    COUNTIF(created_at   < TIMESTAMP('1900-01-01'))            AS created_before_1900
FROM `bigquery-public-data.thelook_ecommerce.order_items`;


-- 5b. Same checks on the order header, to see whether both levels agree
SELECT
    COUNT(*)                                     AS total_rows,
    COUNTIF(shipped_at   < created_at)           AS shipped_before_created,
    COUNTIF(delivered_at < shipped_at)           AS delivered_before_shipped,
    COUNTIF(created_at   > CURRENT_TIMESTAMP())  AS created_in_future
FROM `bigquery-public-data.thelook_ecommerce.orders`;


-- 5c. How bad is it? Distribution of the negative shipping delay, in hours
SELECT
    TIMESTAMP_DIFF(shipped_at, created_at, HOUR) AS shipping_delay_hours,
    COUNT(*)                                     AS rows
FROM `bigquery-public-data.thelook_ecommerce.order_items`
WHERE shipped_at < created_at
GROUP BY shipping_delay_hours
ORDER BY shipping_delay_hours
LIMIT 50;


-- 5d. Time span covered by the dataset (useful to size the ingestion backfill)
SELECT
    MIN(created_at) AS first_order,
    MAX(created_at) AS last_order,
    DATE_DIFF(DATE(MAX(created_at)), DATE(MIN(created_at)), DAY) AS days_covered
FROM `bigquery-public-data.thelook_ecommerce.order_items`;


-- =============================================================================
-- 6. STATUS CONSISTENCY - header versus lines
-- =============================================================================
-- 6a. Which statuses exist, and how frequent are they?
SELECT status, COUNT(*) AS rows,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM `bigquery-public-data.thelook_ecommerce.order_items`
GROUP BY status
ORDER BY rows DESC;

-- 6b. Do the header status and the line status ever disagree?
SELECT o.status AS order_status, oi.status AS item_status, COUNT(*) AS rows
FROM `bigquery-public-data.thelook_ecommerce.orders` o
JOIN `bigquery-public-data.thelook_ecommerce.order_items` oi USING (order_id)
GROUP BY order_status, item_status
ORDER BY rows DESC;

-- 6c. Does num_of_item match the real number of lines?
WITH counted AS (
  SELECT o.order_id, o.num_of_item, COUNT(oi.id) AS real_items
  FROM `bigquery-public-data.thelook_ecommerce.orders` o
  LEFT JOIN `bigquery-public-data.thelook_ecommerce.order_items` oi USING (order_id)
  GROUP BY o.order_id, o.num_of_item
)
SELECT
    COUNT(*)                                   AS orders,
    COUNTIF(num_of_item = real_items)          AS matching,
    COUNTIF(num_of_item <> real_items)         AS mismatching
FROM counted;

-- 6d. Status versus dates: a "Complete" line should have a delivery date
SELECT
    status,
    COUNTIF(shipped_at   IS NULL) AS missing_shipped_at,
    COUNTIF(delivered_at IS NULL) AS missing_delivered_at,
    COUNTIF(returned_at  IS NOT NULL) AS has_returned_at,
    COUNT(*) AS rows
FROM `bigquery-public-data.thelook_ecommerce.order_items`
GROUP BY status
ORDER BY rows DESC;


-- =============================================================================
-- 7. NESTED AND REPEATED FIELDS - the BigQuery-specific part
-- One row per order, with its items nested in an ARRAY<STRUCT<...>>.
-- =============================================================================
WITH nested AS (
  SELECT
      o.order_id,
      o.user_id,
      o.status,
      o.created_at,
      ARRAY_AGG(
        STRUCT(
          oi.id          AS order_item_id,
          oi.product_id  AS product_id,
          oi.sale_price  AS sale_price,
          oi.status      AS item_status
        )
        ORDER BY oi.id
      ) AS items
  FROM `bigquery-public-data.thelook_ecommerce.orders` o
  JOIN `bigquery-public-data.thelook_ecommerce.order_items` oi USING (order_id)
  WHERE DATE(o.created_at) = DATE '2024-01-15'      -- keep it cheap
  GROUP BY o.order_id, o.user_id, o.status, o.created_at
)
SELECT
    order_id,
    ARRAY_LENGTH(items)                       AS item_count,
    (SELECT SUM(i.sale_price) FROM UNNEST(items) i) AS order_revenue,
    items
FROM nested
ORDER BY item_count DESC
LIMIT 20;


-- 7b. The other way round: flatten the array again with UNNEST
WITH nested AS (
  SELECT o.order_id,
         ARRAY_AGG(STRUCT(oi.id AS order_item_id, oi.sale_price AS sale_price)) AS items
  FROM `bigquery-public-data.thelook_ecommerce.orders` o
  JOIN `bigquery-public-data.thelook_ecommerce.order_items` oi USING (order_id)
  WHERE DATE(o.created_at) = DATE '2024-01-15'
  GROUP BY o.order_id
)
SELECT n.order_id, i.order_item_id, i.sale_price
FROM nested n, UNNEST(n.items) AS i
ORDER BY n.order_id, i.order_item_id
LIMIT 50;


-- =============================================================================
-- 8. COST - columnar storage in action
-- Run each query with "dry run" first (the estimate appears above the editor),
-- write down the estimate, then run it and compare with the bytes actually billed.
-- =============================================================================
-- 8a. Every column
SELECT * FROM `bigquery-public-data.thelook_ecommerce.order_items` LIMIT 10;

-- 8b. Three columns only: same rows, far fewer bytes
SELECT order_id, sale_price, created_at
FROM `bigquery-public-data.thelook_ecommerce.order_items`
LIMIT 10;

-- 8c. A filter does NOT reduce the cost on an unpartitioned table
SELECT order_id, sale_price
FROM `bigquery-public-data.thelook_ecommerce.order_items`
WHERE DATE(created_at) = DATE '2024-01-15';

-- 8d. What the jobs really cost (your own project, last 7 days)
SELECT
    creation_time,
    ROUND(total_bytes_processed / POW(1024, 3), 3) AS gb_processed,
    ROUND(total_bytes_billed    / POW(1024, 3), 3) AS gb_billed,
    total_slot_ms,
    LEFT(query, 80) AS query_start
FROM `region-us`.INFORMATION_SCHEMA.JOBS
WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND job_type = 'QUERY'
ORDER BY creation_time DESC
LIMIT 50;


-- =============================================================================
-- 9. BONUS - web sessions and funnel conversion
-- =============================================================================
WITH sessions AS (
  SELECT
      session_id,
      ANY_VALUE(traffic_source)                     AS traffic_source,
      MIN(created_at)                               AS session_start,
      COUNT(*)                                      AS events_in_session,
      COUNTIF(LOWER(event_type) = 'product')        AS saw_product,
      COUNTIF(LOWER(event_type) = 'cart')           AS added_to_cart,
      COUNTIF(LOWER(event_type) = 'purchase')       AS purchased
  FROM `bigquery-public-data.thelook_ecommerce.events`
  GROUP BY session_id
)
SELECT
    traffic_source,
    COUNT(*)                                                   AS sessions,
    ROUND(100 * SAFE_DIVIDE(COUNTIF(saw_product    > 0), COUNT(*)), 2) AS pct_product,
    ROUND(100 * SAFE_DIVIDE(COUNTIF(added_to_cart  > 0), COUNT(*)), 2) AS pct_cart,
    ROUND(100 * SAFE_DIVIDE(COUNTIF(purchased      > 0), COUNT(*)), 2) AS pct_purchase
FROM sessions
GROUP BY traffic_source
ORDER BY sessions DESC;
