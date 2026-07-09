/* ==============================================================================
   RAVENSTACK — ENTERPRISE RETENTION RISK ENGINE
   Complete Data Pipeline: Schema → Ingestion → Dimensional Layer → Fact Table
 
   Analysis period: January 2, 2023 – November 30, 2024
 
   Architecture decisions and their production rationale:
 
   DECISION 1 — dim_date replaces recursive calendar CTE
   A recursive CTE regenerates the date sequence at query runtime. At 500
   accounts over 2 years this produces ~110,000 spine rows on the fly —
   acceptable. At 5 million accounts the same pattern generates 1.1 billion
   rows per query execution and will crash any OLTP server. A physical
   dim_date table is populated once, indexed on its primary key, and joined
   like any standard lookup table. The join cost is O(spine rows), not
   O(accounts × calendar days) computed from scratch each time.
   Production equivalent: dbt date spine package, Snowflake GENERATOR,
   BigQuery GENERATE_DATE_ARRAY. Same pattern, different tooling.
 
   DECISION 2 — Physical fact table replaces logical CREATE VIEW
   A logical view recalculates all CTEs and window functions on every query.
   Every Tableau dashboard refresh and every ML pipeline read hits the raw
   tables and recomputes the full chain. At production scale this means
   30-second+ latency for executives and multi-hour training runs. A
   physical fact table is computed once per refresh cycle via stored
   procedure and read many times. Dashboards load in milliseconds.
   Production equivalent: Airflow DAG scheduling nightly batch refresh,
   dbt incremental materialization strategy.
 
   DECISION 3 — BI accounting accuracy and ML leakage prevention at separate layers
   The net_mrr_delta churn-day correction satisfies GAAP accounting for the
   Tableau layer: revenue loss is recorded on the exact day it occurs. The
   Python ML pipeline enforces a strict T-1 temporal boundary — the
   observation window for every account ends the day before their churn date.
   The churn-day row (with its corrected delta) never enters any account's
   feature window. BI gets perfect accounting. ML gets zero leakage.
   These are separate architectural concerns handled at separate layers by
   design, not by accident.
 
   DECISION 4 — Incremental refresh scaffolding built in
   The stored procedure accepts p_from_date and p_to_date parameters.
   Full refresh: pass '2023-01-02' and '2024-11-30'.
   Nightly incremental: pass yesterday's date for both.
   Note: LAG-based features require a 1-day lookback buffer in incremental
   mode — financial_state should include p_from_date - 1, with the final
   INSERT filtered to >= p_from_date. For the portfolio full-refresh call
   below, this is not needed. The scaffolding is documented for production.
============================================================================== */
 

/* ==============================================================================
   PHASE 1.0: SCHEMA PROVISIONING
   Three isolated schemas: raw ingestion, shared dimensions, feature output.
   Separation ensures the risk_engine_service user never touches raw data.
============================================================================== */
 
CREATE DATABASE IF NOT EXISTS ravenstack_raw;
CREATE DATABASE IF NOT EXISTS ravenstack_dimensions;
CREATE DATABASE IF NOT EXISTS ravenstack_features;
 
USE ravenstack_raw;
 
 
/* ==============================================================================
   PHASE 1.1: RAW TABLE DEFINITIONS (DDL)
============================================================================== */
 
CREATE TABLE ravenstack_accounts (
    account_id       VARCHAR(50)    PRIMARY KEY,
    account_name     VARCHAR(100),
    industry         VARCHAR(50),
    country          VARCHAR(10),
    signup_date      DATE,
    referral_source  VARCHAR(50),
    plan_tier        VARCHAR(50),
    seats            INT,
    is_trial         TINYINT(1),
    churn_flag       TINYINT(1)
);
 
CREATE TABLE ravenstack_subscriptions (
    subscription_id    VARCHAR(50)    PRIMARY KEY,
    account_id         VARCHAR(50),
    start_date         DATE,
    end_date           DATE NULL,
    plan_tier          VARCHAR(50),
    seats              INT,
    mrr_amount         DECIMAL(10, 2),
    arr_amount         DECIMAL(10, 2),
    is_trial           TINYINT(1),
    upgrade_flag       TINYINT(1),
    downgrade_flag     TINYINT(1),
    churn_flag         TINYINT(1),
    billing_frequency  VARCHAR(20),
    auto_renew_flag    TINYINT(1),
    FOREIGN KEY (account_id) REFERENCES ravenstack_accounts(account_id)
);
 
CREATE TABLE ravenstack_feature_usage (
    usage_id             VARCHAR(50)  PRIMARY KEY,
    subscription_id      VARCHAR(50),
    usage_date           DATE,
    feature_name         VARCHAR(50),
    usage_count          INT,
    usage_duration_secs  INT,
    error_count          INT,
    is_beta_feature      TINYINT(1),
    FOREIGN KEY (subscription_id) REFERENCES ravenstack_subscriptions(subscription_id)
);
 
CREATE TABLE ravenstack_support_tickets (
    ticket_id                    VARCHAR(50)    PRIMARY KEY,
    account_id                   VARCHAR(50),
    submitted_at                 TIMESTAMP,
    closed_at                    TIMESTAMP NULL,
    resolution_time_hours        DECIMAL(10, 2),
    priority                     VARCHAR(20),
    first_response_time_minutes  INT,
    satisfaction_score           DECIMAL(3, 1) NULL,
    escalation_flag              TINYINT(1),
    FOREIGN KEY (account_id) REFERENCES ravenstack_accounts(account_id)
);
 
CREATE TABLE ravenstack_churn_events (
    churn_event_id           VARCHAR(50)  PRIMARY KEY,
    account_id               VARCHAR(50),
    churn_date               DATE,
    reason_code              VARCHAR(50),
    refund_amount_usd        DECIMAL(10, 2),
    preceding_upgrade_flag   TINYINT(1),
    preceding_downgrade_flag TINYINT(1),
    is_reactivation          TINYINT(1),
    feedback_text            TEXT NULL,
    FOREIGN KEY (account_id) REFERENCES ravenstack_accounts(account_id)
);
 
 
/* ==============================================================================
   PHASE 1.2: DIMENSIONAL DATE TABLE
   Replaces the recursive calendar CTE entirely.
 
   699 rows covering the analysis period. Populated once via stored procedure.
   Pre-computes days_in_month and is_month_end so downstream CTEs and Tableau
   calculated fields read from columns rather than calling runtime functions.
 
   To extend the analysis window: call sp_populate_dim_date again with the
   new date range. The procedure is idempotent — safe to re-run.
============================================================================== */
 
CREATE TABLE ravenstack_dimensions.dim_date (
    date_id        DATE        PRIMARY KEY,
    year_num       SMALLINT    NOT NULL,
    month_num      TINYINT     NOT NULL,
    day_num        TINYINT     NOT NULL,
    quarter_num    TINYINT     NOT NULL,
    days_in_month  TINYINT     NOT NULL,
    is_month_end   TINYINT(1)  NOT NULL
);
 
DROP PROCEDURE IF EXISTS ravenstack_dimensions.sp_populate_dim_date;
 
DELIMITER $$
CREATE PROCEDURE ravenstack_dimensions.sp_populate_dim_date(
    IN p_start DATE,
    IN p_end   DATE
)
BEGIN
    DECLARE v_date DATE DEFAULT p_start;
 
    DELETE FROM ravenstack_dimensions.dim_date
    WHERE date_id BETWEEN p_start AND p_end;
 
    WHILE v_date <= p_end DO
        INSERT INTO ravenstack_dimensions.dim_date
            (date_id, year_num, month_num, day_num, quarter_num, days_in_month, is_month_end)
        VALUES (
            v_date,
            YEAR(v_date),
            MONTH(v_date),
            DAY(v_date),
            QUARTER(v_date),
            DAY(LAST_DAY(v_date)),
            IF(v_date = LAST_DAY(v_date), 1, 0)
        );
        SET v_date = DATE_ADD(v_date, INTERVAL 1 DAY);
    END WHILE;
END$$
DELIMITER ;
 
CALL ravenstack_dimensions.sp_populate_dim_date('2023-01-02', '2024-11-30');
 
SELECT MIN(date_id)   AS period_start,
       MAX(date_id)   AS period_end,
       COUNT(*)       AS total_days,
       SUM(is_month_end) AS month_end_flags
FROM ravenstack_dimensions.dim_date;
 
 
/* ==============================================================================
   PHASE 1.3: SECURE INGESTION PROTOCOL
   Maps "True"/"False" strings to TINYINT. Handles empty strings as NULL
   to prevent 0000-00-00 date corruption. Feature usage staged and
   deduplicated before promotion to the primary key table.
============================================================================== */
 
SET SQL_SAFE_UPDATES = 0;
 
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_accounts.csv'
INTO TABLE ravenstack_accounts
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(account_id, account_name, industry, country, signup_date,
 referral_source, plan_tier, seats, @is_trial, @churn_flag)
SET is_trial   = IF(TRIM(@is_trial)   = 'True', 1, 0),
    churn_flag = IF(TRIM(@churn_flag) = 'True', 1, 0);
 
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_subscriptions.csv'
INTO TABLE ravenstack_subscriptions
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(subscription_id, account_id, start_date, @end_date, plan_tier, seats,
 mrr_amount, arr_amount, @is_trial, @upgrade_flag, @downgrade_flag,
 @churn_flag, billing_frequency, @auto_renew_flag)
SET end_date         = NULLIF(TRIM(@end_date), ''),
    is_trial         = IF(TRIM(@is_trial)         = 'True', 1, 0),
    upgrade_flag     = IF(TRIM(@upgrade_flag)     = 'True', 1, 0),
    downgrade_flag   = IF(TRIM(@downgrade_flag)   = 'True', 1, 0),
    churn_flag       = IF(TRIM(@churn_flag)       = 'True', 1, 0),
    auto_renew_flag  = IF(TRIM(@auto_renew_flag)  = 'True', 1, 0);
 
CREATE TABLE ravenstack_raw.ravenstack_feature_usage_staging (
    usage_id VARCHAR(50), subscription_id VARCHAR(50), usage_date DATE,
    feature_name VARCHAR(50), usage_count INT, usage_duration_secs INT,
    error_count INT, is_beta_feature TINYINT(1)
);
 
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_feature_usage.csv'
INTO TABLE ravenstack_raw.ravenstack_feature_usage_staging
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(usage_id, subscription_id, usage_date, feature_name,
 usage_count, usage_duration_secs, error_count, @is_beta_feature)
SET is_beta_feature = IF(TRIM(@is_beta_feature) = 'True', 1, 0);
 
INSERT INTO ravenstack_raw.ravenstack_feature_usage
    (usage_id, subscription_id, usage_date, feature_name,
     usage_count, usage_duration_secs, error_count, is_beta_feature)
WITH deduped AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY usage_id ORDER BY usage_date) AS rn
    FROM ravenstack_raw.ravenstack_feature_usage_staging
)
SELECT usage_id, subscription_id, usage_date, feature_name,
       usage_count, usage_duration_secs, error_count, is_beta_feature
FROM deduped WHERE rn = 1;
 
DROP TABLE ravenstack_raw.ravenstack_feature_usage_staging;
 
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_support_tickets.csv'
INTO TABLE ravenstack_support_tickets
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(ticket_id, account_id, submitted_at, @closed_at, resolution_time_hours,
 priority, first_response_time_minutes, @satisfaction_score, @escalation_flag)
SET closed_at          = NULLIF(TRIM(@closed_at), ''),
    satisfaction_score = NULLIF(TRIM(@satisfaction_score), ''),
    escalation_flag    = IF(TRIM(@escalation_flag) = 'True', 1, 0);
 
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_churn_events.csv'
INTO TABLE ravenstack_churn_events
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(churn_event_id, account_id, churn_date, reason_code, refund_amount_usd,
 @preceding_upgrade_flag, @preceding_downgrade_flag, @is_reactivation, @feedback_text)
SET preceding_upgrade_flag   = IF(TRIM(@preceding_upgrade_flag)   = 'True', 1, 0),
    preceding_downgrade_flag = IF(TRIM(@preceding_downgrade_flag) = 'True', 1, 0),
    is_reactivation          = IF(TRIM(@is_reactivation)          = 'True', 1, 0),
    feedback_text            = NULLIF(TRIM(@feedback_text), '');
 
 
/* ==============================================================================
   PHASE 1.4: QA VALIDATION
============================================================================== */
 
SELECT 'ravenstack_accounts'    AS table_name, COUNT(*) AS rows FROM ravenstack_accounts
UNION ALL SELECT 'ravenstack_subscriptions',   COUNT(*) FROM ravenstack_subscriptions
UNION ALL SELECT 'ravenstack_feature_usage',   COUNT(*) FROM ravenstack_feature_usage
UNION ALL SELECT 'ravenstack_support_tickets', COUNT(*) FROM ravenstack_support_tickets
UNION ALL SELECT 'ravenstack_churn_events',    COUNT(*) FROM ravenstack_churn_events
UNION ALL SELECT 'dim_date',                   COUNT(*) FROM ravenstack_dimensions.dim_date;
 
 
/* ==============================================================================
   PHASE 1.5: INDEXES
   Foreign keys, date columns, and fact table filter columns.
   dim_date.date_id is a PRIMARY KEY — already indexed.
============================================================================== */
 
CREATE INDEX idx_sub_account_id     ON ravenstack_raw.ravenstack_subscriptions(account_id);
CREATE INDEX idx_sub_start_date     ON ravenstack_raw.ravenstack_subscriptions(start_date);
CREATE INDEX idx_sub_end_date       ON ravenstack_raw.ravenstack_subscriptions(end_date);
CREATE INDEX idx_usage_sub_id       ON ravenstack_raw.ravenstack_feature_usage(subscription_id);
CREATE INDEX idx_usage_date         ON ravenstack_raw.ravenstack_feature_usage(usage_date);
CREATE INDEX idx_support_account_id ON ravenstack_raw.ravenstack_support_tickets(account_id);
CREATE INDEX idx_churn_account_id   ON ravenstack_raw.ravenstack_churn_events(account_id);
CREATE INDEX idx_churn_date         ON ravenstack_raw.ravenstack_churn_events(churn_date);
CREATE INDEX idx_accounts_signup    ON ravenstack_raw.ravenstack_accounts(signup_date);
 
 
/* ==============================================================================
   PHASE 1.6: PHYSICAL FACT TABLE DEFINITION
   fact_daily_spine: one row per account per active observation day.
   Primary key on (account_id, observation_date) guarantees uniqueness
   and provides the clustered index for account-range scans.
   Additional indexes cover Tableau filter patterns and ML pipeline reads.
============================================================================== */
 
CREATE TABLE IF NOT EXISTS ravenstack_features.fact_daily_spine (
    account_id             VARCHAR(50)    NOT NULL,
    observation_date       DATE           NOT NULL,
    industry               VARCHAR(50),
    baseline_tier          VARCHAR(50),
    referral_source        VARCHAR(50),
    active_mrr_run_rate    DECIMAL(10, 2) NOT NULL DEFAULT 0,
    daily_billing_accrual  DECIMAL(10, 4) NOT NULL DEFAULT 0,
    billing_frequency      VARCHAR(20)    NOT NULL DEFAULT 'none',
    auto_renew_flag        TINYINT(1)     NOT NULL DEFAULT 0,
    is_trial               TINYINT(1)     NOT NULL DEFAULT 0,
    downgrade_flag         TINYINT(1)     NOT NULL DEFAULT 0,
    daily_time_in_app      INT            NOT NULL DEFAULT 0,
    daily_friction_events  INT            NOT NULL DEFAULT 0,
    beta_interactions      INT            NOT NULL DEFAULT 0,
    ticket_volume          INT            NOT NULL DEFAULT 0,
    avg_resolution_time    DECIMAL(10, 2) NULL,
    avg_csat_score         DECIMAL(3, 1)  NULL,
    target_churn_flag      TINYINT(1)     NOT NULL DEFAULT 0,
    net_mrr_delta          DECIMAL(10, 2) NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, observation_date)
);
 
CREATE INDEX idx_fact_obs_date   ON ravenstack_features.fact_daily_spine(observation_date);
CREATE INDEX idx_fact_churn      ON ravenstack_features.fact_daily_spine(target_churn_flag);
CREATE INDEX idx_fact_tier       ON ravenstack_features.fact_daily_spine(baseline_tier);
CREATE INDEX idx_fact_month_end  ON ravenstack_features.fact_daily_spine(observation_date, active_mrr_run_rate);
 
 
/* ==============================================================================
   PHASE 1.7: MATERIALIZATION PROCEDURE — sp_refresh_fact_spine
 
   Populates fact_daily_spine for a given date window. Idempotent: deletes
   rows in the target window before inserting, so re-running is always safe.
 
   Parameters:
     p_from_date: window start. Full refresh: '2023-01-02'.
                  Incremental: last successfully processed date.
     p_to_date:   window end. Hard-coded to '2024-11-30' for this project.
                  In production: CURDATE() - INTERVAL 1 DAY.
 
   Production incremental note:
   LAG-based features (prev_day_mrr, net_mrr_delta) require the prior day's
   MRR as context. In incremental mode, extend financial_state to include
   DATE_SUB(p_from_date, INTERVAL 1 DAY) as its lower bound, then filter
   the final INSERT to observation_date >= p_from_date. This is the standard
   lookback-buffer pattern for incremental window function pipelines.
   For the portfolio full-refresh call below, this is not required.
============================================================================== */
 
DROP PROCEDURE IF EXISTS ravenstack_features.sp_refresh_fact_spine;
 
DELIMITER $$
 
CREATE PROCEDURE ravenstack_features.sp_refresh_fact_spine(
    IN p_from_date DATE,
    IN p_to_date   DATE
)
BEGIN
 
    DELETE FROM ravenstack_features.fact_daily_spine
    WHERE observation_date BETWEEN p_from_date AND p_to_date;
 
    INSERT INTO ravenstack_features.fact_daily_spine (
        account_id, observation_date, industry, baseline_tier, referral_source,
        active_mrr_run_rate, daily_billing_accrual, billing_frequency,
        auto_renew_flag, is_trial, downgrade_flag,
        daily_time_in_app, daily_friction_events, beta_interactions,
        ticket_volume, avg_resolution_time, avg_csat_score,
        target_churn_flag, net_mrr_delta
    )
 
    WITH
 
    /* ------------------------------------------------------------------
       latest_churn: one row per account, most recent in-period churn.
       Defined first so account_spine joins to it in a single indexed pass
       rather than running a correlated subquery per account per date row.
       Boundary: < '2024-12-01' (exclusive upper = inclusive Nov 30).
       Consistent across all four period-capping clauses in this procedure.
    ------------------------------------------------------------------ */
    latest_churn AS (
        SELECT
            account_id,
            MAX(churn_date) AS churn_date
        FROM ravenstack_raw.ravenstack_churn_events
        WHERE churn_date < '2024-12-01'
        GROUP BY account_id
    ),
 
    /* ------------------------------------------------------------------
       account_spine: one row per account per active calendar day.
       Joins accounts to dim_date — a physical indexed table, not a
       runtime-generated sequence. This is the replacement for the
       recursive calendar CTE.
 
       Active window: signup_date to latest in-period churn date,
       or p_to_date if the account has not yet churned.
 
       The BETWEEN p_from_date AND p_to_date clause on dim_date is what
       enables incremental refresh: only dates in the target window are
       joined, so the procedure processes only new rows each night.
 
       17 accounts signed up in December 2024: their signup_date falls
       after p_to_date so the JOIN condition d.date_id >= a.signup_date
       never holds. They produce zero rows. Correct analytical exclusion.
    ------------------------------------------------------------------ */
 account_spine AS (
        SELECT
            a.account_id,
            a.industry,
            a.plan_tier      AS baseline_tier,
            a.referral_source,
            d.date_id        AS obs_date,
            d.days_in_month
        FROM ravenstack_raw.ravenstack_accounts a
        /* FIX: Join the churn table FIRST so the date is available */
        LEFT JOIN latest_churn lc
            ON lc.account_id = a.account_id
        /* THEN join the dimension date using the now-available lc.churn_date */
        JOIN ravenstack_dimensions.dim_date d
            ON  d.date_id >= a.signup_date
            AND d.date_id <= COALESCE(lc.churn_date, p_to_date)
            AND d.date_id BETWEEN p_from_date AND p_to_date
    ),
 
    /* ------------------------------------------------------------------
       daily_subs: active subscription per account per day.
       ROW_NUMBER resolves overlapping billing periods from plan changes,
       upgrades, and renewals. Priority: most recent start date, then
       highest MRR as tiebreaker. Only rank = 1 is consumed downstream.
 
       LEFT JOIN: days with no active subscription return NULL for all
       subscription columns. COALESCE in financial_state handles these.
    ------------------------------------------------------------------ */
    daily_subs AS (
        SELECT
            sp.account_id,
            sp.obs_date,
            sp.days_in_month,
            s.mrr_amount,
            s.downgrade_flag,
            s.billing_frequency,
            s.auto_renew_flag,
            s.is_trial,
            ROW_NUMBER() OVER (
                PARTITION BY sp.account_id, sp.obs_date
                ORDER BY s.start_date DESC, s.mrr_amount DESC
            ) AS sub_rank
        FROM account_spine sp
        LEFT JOIN ravenstack_raw.ravenstack_subscriptions s
            ON  s.account_id  = sp.account_id
            AND s.start_date <= sp.obs_date
            AND (s.end_date IS NULL OR s.end_date >= sp.obs_date)
    ),
 
    /* ------------------------------------------------------------------
       financial_state: one clean financial row per account per day.
       Filters to sub_rank = 1 — exactly one row per account-day remains.
       MAX() aggregates on a single row return that row's value.
       Used instead of direct column reference to satisfy GROUP BY syntax.
 
       days_in_month sourced from dim_date (pre-computed per date).
       Avoids calling DAY(LAST_DAY()) as a runtime function on every row.
    ------------------------------------------------------------------ */
    financial_state AS (
        SELECT
            account_id,
            obs_date,
            days_in_month,
            MAX(COALESCE(mrr_amount,     0))                       AS active_mrr_run_rate,
            MAX(COALESCE(mrr_amount,     0)) / days_in_month       AS daily_billing_accrual,
            MAX(COALESCE(downgrade_flag, 0))                       AS downgrade_flag,
            MAX(billing_frequency)                                 AS billing_frequency,
            MAX(COALESCE(auto_renew_flag,0))                       AS auto_renew_flag,
            MAX(COALESCE(is_trial,       0))                       AS is_trial
        FROM daily_subs
        WHERE sub_rank = 1
        GROUP BY account_id, obs_date, days_in_month
    ),
 
    /* ------------------------------------------------------------------
       financial_vectors: day-over-day MRR momentum per account.
       LAG looks back one row within each account's ordered sequence.
       First observation day: LAG returns NULL, COALESCE gives 0.
       net_mrr_delta on day 1 = full MRR — correct new signup signal.
       prev_day_mrr powers the churn-day net_mrr_delta correction below.
    ------------------------------------------------------------------ */
    financial_vectors AS (
        SELECT
            account_id,
            obs_date,
            active_mrr_run_rate,
            daily_billing_accrual,
            downgrade_flag,
            billing_frequency,
            auto_renew_flag,
            is_trial,
            COALESCE(
                LAG(active_mrr_run_rate, 1) OVER (PARTITION BY account_id ORDER BY obs_date),
                0
            )                                                      AS prev_day_mrr,
            active_mrr_run_rate - COALESCE(
                LAG(active_mrr_run_rate, 1) OVER (PARTITION BY account_id ORDER BY obs_date),
                0
            )                                                      AS net_mrr_delta
        FROM financial_state
    ),
 
    /* ------------------------------------------------------------------
       telemetry_rollup: product engagement per account per day.
       feature_usage records subscription_id, not account_id directly.
       JOIN through subscriptions resolves this. Period cap mirrors the
       overall boundary for independent verifiability of this CTE block.
    ------------------------------------------------------------------ */
    telemetry_rollup AS (
        SELECT
            s.account_id,
            fu.usage_date                AS activity_date,
            SUM(fu.usage_duration_secs)  AS daily_time_in_app,
            SUM(fu.error_count)          AS daily_friction_events,
            SUM(fu.is_beta_feature)      AS beta_interactions
        FROM ravenstack_raw.ravenstack_feature_usage fu
        JOIN ravenstack_raw.ravenstack_subscriptions s
            ON fu.subscription_id = s.subscription_id
        WHERE fu.usage_date < '2024-12-01'
        GROUP BY s.account_id, fu.usage_date
    ),
 
    /* ------------------------------------------------------------------
       support_friction: support ticket signals per account per day.
       avg_resolution_time and avg_csat_score are intentionally nullable.
       Tickets are sparse events occurring on <1% of account-days.
       NULL on ticket-free days is semantically correct — it signals
       absence of a ticket, not a ticket resolved in zero time.
       LightGBM handles NULL natively via its split-finding algorithm.
       Imputing 0 would introduce a systematic category error.
    ------------------------------------------------------------------ */
    support_friction AS (
        SELECT
            account_id,
            CAST(submitted_at AS DATE)   AS ticket_date,
            COUNT(ticket_id)             AS support_volume,
            AVG(resolution_time_hours)   AS avg_resolution_time,
            AVG(satisfaction_score)      AS avg_csat_score
        FROM ravenstack_raw.ravenstack_support_tickets
        WHERE CAST(submitted_at AS DATE) < '2024-12-01'
        GROUP BY account_id, CAST(submitted_at AS DATE)
    )
 
    /* ------------------------------------------------------------------
       Final assembly: attach all signal layers to the account-day spine.
 
       target_churn_flag: fires 1 on the exact day of an account's last
       in-period churn event. 0 on all other days. For reactivated
       accounts, only the final churn is flagged — correct for a model
       predicting permanent exit, not temporary cancellation.
 
       net_mrr_delta churn correction: on the churn day, the spine ends
       and never creates a next-day row to record the revenue drop to
       zero. Without correction, churn losses are invisible in velocity
       charts. The correction records -prev_day_mrr on the churn day.
       The Python ML layer enforces T-1 temporal isolation — the churn
       day row is excluded from every account's feature window — so this
       accounting correction never reaches the model as a feature.
    ------------------------------------------------------------------ */
    SELECT
        sp.account_id,
        sp.obs_date,
        sp.industry,
        sp.baseline_tier,
        sp.referral_source,
        COALESCE(fv.active_mrr_run_rate,   0),
        COALESCE(fv.daily_billing_accrual, 0),
        COALESCE(fv.billing_frequency,     'none'),
        COALESCE(fv.auto_renew_flag,       0),
        COALESCE(fv.is_trial,              0),
        COALESCE(fv.downgrade_flag,        0),
        COALESCE(tr.daily_time_in_app,     0),
        COALESCE(tr.daily_friction_events, 0),
        COALESCE(tr.beta_interactions,     0),
        COALESCE(sf.support_volume,        0),
        sf.avg_resolution_time,
        sf.avg_csat_score,
        CASE
            WHEN lc.churn_date IS NOT NULL
             AND lc.churn_date = sp.obs_date THEN 1
            ELSE 0
        END,
        CASE
            WHEN lc.churn_date IS NOT NULL
             AND lc.churn_date = sp.obs_date
            THEN -COALESCE(fv.prev_day_mrr, 0)
            ELSE  COALESCE(fv.net_mrr_delta, 0)
        END
 
    FROM            account_spine   sp
    LEFT JOIN financial_vectors     fv ON sp.account_id = fv.account_id AND sp.obs_date = fv.obs_date
    LEFT JOIN telemetry_rollup      tr ON sp.account_id = tr.account_id AND sp.obs_date = tr.activity_date
    LEFT JOIN support_friction      sf ON sp.account_id = sf.account_id AND sp.obs_date = sf.ticket_date
    LEFT JOIN latest_churn          lc ON sp.account_id = lc.account_id;
 
END$$
 
DELIMITER ;
 
 
/* ==============================================================================
   PHASE 1.8: EXECUTE — Full refresh for the analysis period
   In production: replace '2023-01-02' with the last refresh checkpoint
   date to process only new data each night (incremental mode).
============================================================================== */
 
CALL ravenstack_features.sp_refresh_fact_spine('2023-01-02', '2024-11-30');
 
SELECT
    COUNT(*)                    AS total_rows,
    COUNT(DISTINCT account_id)  AS unique_accounts,
    MIN(observation_date)       AS period_start,
    MAX(observation_date)       AS period_end,
    SUM(target_churn_flag)      AS churn_events_flagged
FROM ravenstack_features.fact_daily_spine;
 
 
/* ==============================================================================
   PHASE 1.9: ROLE-BASED ACCESS CONTROL
   risk_engine_service: SELECT on the fact table only.
   Cannot read raw tables, write data, or access other schemas.
============================================================================== */
 
CREATE USER IF NOT EXISTS 'risk_engine_service'@'%' IDENTIFIED BY 'SecurePassword123!';
GRANT SELECT ON ravenstack_features.fact_daily_spine TO 'risk_engine_service'@'%';
FLUSH PRIVILEGES;

/* ==============================================================================
   PRODUCTION DATA EXPORT PROTOCOL (FOR LOCAL BI PROTOTYPING)
   Dumps the finalized fact table into a clean CSV inside the secure privileges directory.
============================================================================== */

SELECT 
    'account_id', 'observation_date', 'industry', 'baseline_tier', 'referral_source',
    'active_mrr_run_rate', 'daily_billing_accrual', 'billing_frequency',
    'auto_renew_flag', 'is_trial', 'downgrade_flag', 'daily_time_in_app',
    'daily_friction_events', 'beta_interactions', 'ticket_volume',
    'avg_resolution_time', 'avg_csat_score', 'target_churn_flag', 'net_mrr_delta'
UNION ALL
SELECT 
    account_id, observation_date, industry, baseline_tier, referral_source,
    CAST(active_mrr_run_rate AS CHAR), CAST(daily_billing_accrual AS CHAR), billing_frequency,
    CAST(auto_renew_flag AS CHAR), CAST(is_trial AS CHAR), CAST(downgrade_flag AS CHAR), CAST(daily_time_in_app AS CHAR),
    CAST(daily_friction_events AS CHAR), CAST(beta_interactions AS CHAR), CAST(ticket_volume AS CHAR),
    IFNULL(CAST(avg_resolution_time AS CHAR), ''), IFNULL(CAST(avg_csat_score AS CHAR), ''), 
    CAST(target_churn_flag AS CHAR), CAST(net_mrr_delta AS CHAR)
FROM ravenstack_features.fact_daily_spine
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/fact_daily_spine_export.csv'
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n';