-- ============================================================
-- Online Retail II - SQL (PostgreSQL)
-- Data with Saba
-- Steps: import raw data -> clean -> RFM -> cohort retention
-- Tip: in pgAdmin run one statement at a time (clear the editor first),
-- otherwise only part of the text may run.
-- ============================================================


-- ============================================================
-- 0. RAW TABLE AND IMPORT
-- ============================================================
-- Source: two CSV files (one per Excel sheet), imported with
-- pgAdmin > Import/Export Data (Header on, delimiter ",", UTF8).
-- invoicedate stays TEXT here and is converted in the clean table.
-- price must NOT have a fixed scale: NUMERIC(12,2) rounded tiny prices
-- (e.g. 0.001) to 0.00 and removed 18 extra rows in the Price > 0 step.

CREATE TABLE raw_retail (
    invoice      TEXT,
    stockcode    TEXT,
    description  TEXT,
    quantity     INTEGER,
    invoicedate  TEXT,
    price        NUMERIC,
    customer_id  TEXT,
    country      TEXT
);

-- Check: expected 1,067,371
SELECT COUNT(*) FROM raw_retail;


-- ============================================================
-- 1. CLEANING - COUNT AFTER EACH STEP
-- ============================================================
-- Goal: reproduce the Power Query cleaning. Each count must match.

-- Step 2: remove cancellations (invoice starts with C). Expected 1,047,877
SELECT COUNT(*) FROM raw_retail
WHERE invoice NOT LIKE 'C%';

-- Step 3: Quantity > 0. Expected 1,044,420
SELECT COUNT(*) FROM raw_retail
WHERE invoice NOT LIKE 'C%'
  AND quantity > 0;

-- Step 4: Price > 0. Expected 1,041,670
SELECT COUNT(*) FROM raw_retail
WHERE invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0;

-- Step 5: remove exact duplicates. Expected 1,007,913
SELECT COUNT(*) FROM (
    SELECT DISTINCT *
    FROM raw_retail
    WHERE invoice NOT LIKE 'C%'
      AND quantity > 0
      AND price > 0
) t;

-- Step 6: remove missing Customer ID. Expected 779,425
SELECT COUNT(*) FROM (
    SELECT DISTINCT *
    FROM raw_retail
    WHERE invoice NOT LIKE 'C%'
      AND quantity > 0
      AND price > 0
      AND customer_id IS NOT NULL
) t;

-- Step 7: remove non-product StockCodes. Expected 776,579
-- Product codes start with 5 digits (85048, 79323P).
-- Non-products: POST, DOT, M, D, S, B, C2, C3, BANK CHARGES, ADJUST,
-- AMAZONFEE, CRUK, PADS, TEST001, DCGS..., gift_0001_... and similar.
-- SP1002 is a real product (KID'S CHALKBOARD/EASEL), so it is kept.
SELECT COUNT(*) FROM (
    SELECT DISTINCT *
    FROM raw_retail
    WHERE invoice NOT LIKE 'C%'
      AND quantity > 0
      AND price > 0
      AND customer_id IS NOT NULL
      AND (stockcode ~ '^[0-9]{5}' OR stockcode = 'SP1002')
) t;

-- Step 8: exclude outlier invoice 581483. Expected 776,578
-- (80,995 units, about $168K, cancelled minutes later)
SELECT COUNT(*) FROM (
    SELECT DISTINCT *
    FROM raw_retail
    WHERE invoice NOT LIKE 'C%'
      AND quantity > 0
      AND price > 0
      AND customer_id IS NOT NULL
      AND (stockcode ~ '^[0-9]{5}' OR stockcode = 'SP1002')
      AND invoice <> '581483'
) t;


-- ============================================================
-- 2. CLEAN TABLE
-- ============================================================
-- Trims description, converts the text date (MM/DD/YYYY HH24:MI)
-- to a timestamp, adds a date-only column, casts customer_id.

CREATE TABLE retail_clean AS
SELECT DISTINCT
    invoice,
    stockcode,
    TRIM(description) AS description,
    quantity,
    TO_TIMESTAMP(invoicedate, 'MM/DD/YYYY HH24:MI')        AS invoicedate,
    TO_TIMESTAMP(invoicedate, 'MM/DD/YYYY HH24:MI')::date  AS invoicedatedate,
    price,
    customer_id::INTEGER AS customer_id,
    country
FROM raw_retail
WHERE invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0
  AND customer_id IS NOT NULL
  AND (stockcode ~ '^[0-9]{5}' OR stockcode = 'SP1002')
  AND invoice <> '581483';

-- Check: expected 776,578
SELECT COUNT(*) FROM retail_clean;

-- Check against the dashboard.
-- Expected: 16,900,113.12 | 36,593 | 5,852 | 10,417,743
SELECT
    ROUND(SUM(quantity * price), 2) AS total_sales,
    COUNT(DISTINCT invoice)         AS total_invoices,
    COUNT(DISTINCT customer_id)     AS total_customers,
    SUM(quantity)                   AS total_quantity
FROM retail_clean;


-- ============================================================
-- 3. RFM
-- ============================================================
-- Reference date for Recency: 2011-12-10 (day after the last invoice).
SELECT MAX(invoicedatedate) AS last_date FROM retail_clean;  -- 2011-12-09

-- Recency = days since last purchase, Frequency = distinct invoices,
-- Monetary = total sales. Expected: 5,852 rows (one per customer).
CREATE TABLE rfm_base AS
SELECT
    customer_id,
    DATE '2011-12-10' - MAX(invoicedatedate) AS recency,
    COUNT(DISTINCT invoice)                  AS frequency,
    ROUND(SUM(quantity * price), 2)          AS monetary
FROM retail_clean
GROUP BY customer_id;

-- Scores 1-5.
-- R and M: NTILE(5) (quintiles). Lowest recency (most recent) = score 5.
-- F: fixed bands instead of NTILE. Many customers share the same invoice
-- count, and NTILE split equal customers across different scores
-- (frequency = 1 landed in score 1 and 2).
CREATE TABLE rfm_scores AS
SELECT
    customer_id,
    recency,
    frequency,
    monetary,
    NTILE(5) OVER (ORDER BY recency DESC) AS r_score,
    CASE
        WHEN frequency = 1 THEN 1
        WHEN frequency = 2 THEN 2
        WHEN frequency <= 4 THEN 3
        WHEN frequency <= 8 THEN 4
        ELSE 5
    END AS f_score,
    NTILE(5) OVER (ORDER BY monetary ASC) AS m_score
FROM rfm_base;

-- Check: F score ranges must not overlap (1-1, 2-2, 3-4, 5-8, 9-373)
SELECT f_score, MIN(frequency) AS min_freq, MAX(frequency) AS max_freq, COUNT(*) AS customers
FROM rfm_scores
GROUP BY f_score
ORDER BY f_score;

-- Segments. CASE order matters: a customer gets the first matching rule.
-- The thresholds are a design choice, not a standard.
CREATE TABLE rfm_segments AS
SELECT
    customer_id,
    recency,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 4 THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score IN (2, 3) THEN 'Potential Loyalists'
        WHEN r_score >= 4 AND f_score = 1 THEN 'New Customers'
        WHEN r_score = 3 AND f_score <= 3 THEN 'Need Attention'
        WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk'
        WHEN r_score <= 2 AND f_score <= 2 THEN 'Hibernating'
        ELSE 'Others'
    END AS segment
FROM rfm_scores;

-- Segment summary with share of customers and sales.
-- Window function SUM(...) OVER () gives the grand total.
-- Expected: Champions 21.5% of customers, 68.4% of sales.
SELECT
    segment,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_customers,
    ROUND(SUM(monetary), 2) AS total_sales,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_sales
FROM rfm_segments
GROUP BY segment
ORDER BY total_sales DESC;


-- ============================================================
-- 4. COHORT RETENTION
-- ============================================================
-- Cohort = month of the customer's first purchase.
-- Note: the Dec 2009 cohort includes returning customers, because the
-- data starts that month.
CREATE TABLE customer_cohort AS
SELECT
    customer_id,
    DATE_TRUNC('month', MIN(invoicedatedate))::date AS cohort_month
FROM retail_clean
GROUP BY customer_id;

-- Check: 25 cohorts, sum of customers = 5,852
SELECT cohort_month, COUNT(*) AS customers
FROM customer_cohort
GROUP BY cohort_month
ORDER BY cohort_month;

-- One row per customer per active month.
-- month_index = months since the cohort month (0 = first purchase month).
CREATE TABLE cohort_activity AS
SELECT DISTINCT
    r.customer_id,
    c.cohort_month,
    DATE_TRUNC('month', r.invoicedatedate)::date AS activity_month,
    (EXTRACT(YEAR FROM r.invoicedatedate) - EXTRACT(YEAR FROM c.cohort_month)) * 12
      + EXTRACT(MONTH FROM r.invoicedatedate) - EXTRACT(MONTH FROM c.cohort_month) AS month_index
FROM retail_clean r
JOIN customer_cohort c ON c.customer_id = r.customer_id;

-- Check: expected 5,852
SELECT COUNT(*) FROM cohort_activity WHERE month_index = 0;

-- Retention: active customers / cohort size.
-- FIRST_VALUE takes the month-0 count of each cohort as the denominator.
CREATE TABLE cohort_retention AS
SELECT
    cohort_month,
    month_index::int AS month_index,
    COUNT(DISTINCT customer_id) AS active_customers,
    ROUND(100.0 * COUNT(DISTINCT customer_id)
        / FIRST_VALUE(COUNT(DISTINCT customer_id))
          OVER (PARTITION BY cohort_month ORDER BY month_index), 1) AS retention_pct
FROM cohort_activity
GROUP BY cohort_month, month_index;

-- Remove cells that fall in Dec 2011 (incomplete month, data ends 9 Dec).
-- Expected: 325 rows before, 300 after, 24 cohorts.
CREATE TABLE cohort_retention_final AS
SELECT *
FROM cohort_retention
WHERE cohort_month + month_index * INTERVAL '1 month' < DATE '2011-12-01';


-- ============================================================
-- 5. EXPORT TO POWER BI
-- ============================================================
-- pgAdmin > right-click table > Import/Export Data > Export (csv, header on):
--   rfm_segments            -> rfm_segments.csv             (5,852 rows)
--   cohort_retention_final  -> cohort_retention_final.csv  (300 rows)
