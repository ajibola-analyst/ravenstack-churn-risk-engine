CREATE DATABASE IF NOT EXISTS ravenstack_raw;
CREATE DATABASE IF NOT EXISTS ravenstack_features;

USE ravenstack_raw;

/* TABLE DEFINITION */

CREATE TABLE ravenstack_accounts (
    account_id VARCHAR(50) PRIMARY KEY,
    account_name VARCHAR(100),
    industry VARCHAR(50),
    country VARCHAR(10),
    signup_date DATE,
    referral_source VARCHAR(50),
    plan_tier VARCHAR(50),
    seats INT,
    is_trial TINYINT(1),
    churn_flag TINYINT(1)
);

CREATE TABLE ravenstack_subscriptions (
    subscription_id VARCHAR(50) PRIMARY KEY,
    account_id VARCHAR(50),
    start_date DATE,
    end_date DATE NULL,
    plan_tier VARCHAR(50),
    seats INT,
    mrr_amount DECIMAL(10, 2),
    arr_amount DECIMAL(10, 2),
    is_trial TINYINT(1),
    upgrade_flag TINYINT(1),
    downgrade_flag TINYINT(1),
    churn_flag TINYINT(1),
    billing_frequency VARCHAR(20),
    auto_renew_flag TINYINT(1),
    FOREIGN KEY (account_id) REFERENCES ravenstack_accounts(account_id)
);

CREATE TABLE ravenstack_feature_usage (
    usage_id VARCHAR(50) PRIMARY KEY,
    subscription_id VARCHAR(50),
    usage_date DATE,
    feature_name VARCHAR(50),
    usage_count INT,
    usage_duration_secs INT,
    error_count INT,
    is_beta_feature TINYINT(1),
    FOREIGN KEY (subscription_id) REFERENCES ravenstack_subscriptions(subscription_id)
);

CREATE TABLE ravenstack_support_tickets (
    ticket_id VARCHAR(50) PRIMARY KEY,
    account_id VARCHAR(50),
    submitted_at TIMESTAMP,
    closed_at TIMESTAMP NULL,
    resolution_time_hours DECIMAL(10, 2),
    priority VARCHAR(20),
    first_response_time_minutes INT,
    satisfaction_score DECIMAL(3, 1) NULL,
    escalation_flag TINYINT(1),
    FOREIGN KEY (account_id) REFERENCES ravenstack_accounts(account_id)
);

CREATE TABLE ravenstack_churn_events (
    churn_event_id VARCHAR(50) PRIMARY KEY,
    account_id VARCHAR(50),
    churn_date DATE,
    reason_code VARCHAR(50),
    refund_amount_usd DECIMAL(10, 2),
    preceding_upgrade_flag TINYINT(1),
    preceding_downgrade_flag TINYINT(1),
    is_reactivation TINYINT(1),
    feedback_text TEXT NULL,
    FOREIGN KEY (account_id) REFERENCES ravenstack_accounts(account_id)
);

/* INGESTION PROTOCOL */
SET SQL_SAFE_UPDATES = 0;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_accounts.csv'
INTO TABLE ravenstack_accounts
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(account_id, account_name, industry, country, signup_date, referral_source, plan_tier, seats, @is_trial, @churn_flag)
SET is_trial = IF(TRIM(@is_trial)='True', 1, 0), 
    churn_flag = IF(TRIM(@churn_flag)='True', 1, 0);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_subscriptions.csv'
INTO TABLE ravenstack_subscriptions
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(subscription_id, account_id, start_date, @end_date, plan_tier, seats, mrr_amount, arr_amount, @is_trial, @upgrade_flag, @downgrade_flag, @churn_flag, billing_frequency, @auto_renew_flag)
SET end_date = NULLIF(TRIM(@end_date), ''),
    is_trial = IF(TRIM(@is_trial)='True', 1, 0),
    upgrade_flag = IF(TRIM(@upgrade_flag)='True', 1, 0),
    downgrade_flag = IF(TRIM(@downgrade_flag)='True', 1, 0),
    churn_flag = IF(TRIM(@churn_flag)='True', 1, 0),
    auto_renew_flag = IF(TRIM(@auto_renew_flag)='True', 1, 0);


CREATE TABLE ravenstack_raw.ravenstack_feature_usage_staging (
    usage_id VARCHAR(50),
    subscription_id VARCHAR(50),
    usage_date DATE,
    feature_name VARCHAR(50),
    usage_count INT,
    usage_duration_secs INT,
    error_count INT,
    is_beta_feature TINYINT(1)
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_feature_usage.csv'
INTO TABLE ravenstack_raw.ravenstack_feature_usage_staging
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(usage_id, subscription_id, usage_date, feature_name, usage_count, usage_duration_secs, error_count, @is_beta_feature)
SET is_beta_feature = IF(TRIM(@is_beta_feature)='True', 1, 0);

INSERT INTO ravenstack_raw.ravenstack_feature_usage (
    usage_id, subscription_id, usage_date, feature_name, usage_count, usage_duration_secs, error_count, is_beta_feature
)
WITH DeduplicatedLogs AS (
    SELECT 
        usage_id, subscription_id, usage_date, feature_name, 
        usage_count, usage_duration_secs, error_count, is_beta_feature,
        ROW_NUMBER() OVER(PARTITION BY usage_id ORDER BY usage_date) as row_num
    FROM ravenstack_raw.ravenstack_feature_usage_staging
)
SELECT 
    usage_id, subscription_id, usage_date, feature_name, 
    usage_count, usage_duration_secs, error_count, is_beta_feature
FROM DeduplicatedLogs
WHERE row_num = 1;

DROP TABLE ravenstack_raw.ravenstack_feature_usage_staging;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_support_tickets.csv'
INTO TABLE ravenstack_support_tickets
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(ticket_id, account_id, submitted_at, @closed_at, resolution_time_hours, priority, first_response_time_minutes, @satisfaction_score, @escalation_flag)
SET closed_at = NULLIF(TRIM(@closed_at), ''),
    satisfaction_score = NULLIF(TRIM(@satisfaction_score), ''),
    escalation_flag = IF(TRIM(@escalation_flag)='True', 1, 0);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/ravenstack_churn_events.csv'
INTO TABLE ravenstack_churn_events
FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\r\n' IGNORE 1 ROWS
(churn_event_id, account_id, churn_date, reason_code, refund_amount_usd, @preceding_upgrade_flag, @preceding_downgrade_flag, @is_reactivation, @feedback_text)
SET preceding_upgrade_flag = IF(TRIM(@preceding_upgrade_flag)='True', 1, 0),
    preceding_downgrade_flag = IF(TRIM(@preceding_downgrade_flag)='True', 1, 0),
    is_reactivation = IF(TRIM(@is_reactivation)='True', 1, 0),
    feedback_text = NULLIF(TRIM(@feedback_text), '');



/*  QA Check */
SELECT 'ravenstack_accounts' AS table_name, COUNT(*) AS exact_row_count FROM ravenstack_accounts
UNION ALL
SELECT 'ravenstack_subscriptions', COUNT(*) FROM ravenstack_subscriptions
UNION ALL
SELECT 'ravenstack_feature_usage', COUNT(*) FROM ravenstack_feature_usage
UNION ALL
SELECT 'ravenstack_support_tickets', COUNT(*) FROM ravenstack_support_tickets
UNION ALL
SELECT 'ravenstack_churn_events', COUNT(*) FROM ravenstack_churn_events;



/* RELATIONAL COHORT ENGINEERING  */
SET SESSION cte_max_recursion_depth = 10000;

CREATE OR REPLACE VIEW ravenstack_features.vw_revenue_retention_matrix AS 

WITH RECURSIVE calendar AS (
    SELECT MIN(signup_date) AS obs_date 
    FROM ravenstack_raw.ravenstack_accounts
    UNION ALL
    SELECT DATE_ADD(obs_date, INTERVAL 1 DAY)
    FROM calendar
    WHERE obs_date < (
        SELECT MAX(max_dt) FROM (
            SELECT MAX(usage_date) AS max_dt FROM ravenstack_raw.ravenstack_feature_usage
            UNION ALL SELECT MAX(churn_date) FROM ravenstack_raw.ravenstack_churn_events
            UNION ALL SELECT MAX(signup_date) FROM ravenstack_raw.ravenstack_accounts
        ) AS all_dates
    )
),

account_spine AS (
    SELECT 
        a.account_id, 
        a.industry, 
        a.plan_tier AS baseline_tier,
        a.referral_source,
        c.obs_date
    FROM ravenstack_raw.ravenstack_accounts a
    JOIN calendar c 
        ON c.obs_date >= a.signup_date
        AND c.obs_date <= COALESCE(
            (SELECT churn_date 
             FROM ravenstack_raw.ravenstack_churn_events e 
             WHERE e.account_id = a.account_id 
             ORDER BY churn_date DESC LIMIT 1),
            (SELECT MAX(obs_date) FROM calendar)
        )
),

daily_subs AS (
    SELECT 
        sp.account_id,
        sp.obs_date,
        s.mrr_amount,
        s.downgrade_flag,
        s.billing_frequency,
        s.auto_renew_flag,
        s.is_trial,
        ROW_NUMBER() OVER(PARTITION BY sp.account_id, sp.obs_date ORDER BY s.start_date DESC, s.mrr_amount DESC) as sub_rank
    FROM account_spine sp
    LEFT JOIN ravenstack_raw.ravenstack_subscriptions s
        ON s.account_id = sp.account_id
        AND s.start_date <= sp.obs_date
        AND (s.end_date IS NULL OR s.end_date >= sp.obs_date)
),

financial_state AS (
    SELECT 
        account_id,
        obs_date,
        SUM(COALESCE(mrr_amount, 0)) AS active_mrr_run_rate,
        SUM(COALESCE(mrr_amount, 0) / DAY(LAST_DAY(obs_date))) AS daily_billing_accrual, 
        MAX(COALESCE(downgrade_flag, 0)) AS downgrade_flag,
        MAX(billing_frequency) AS billing_frequency,
        MAX(COALESCE(auto_renew_flag, 0)) AS auto_renew_flag,
        MAX(COALESCE(is_trial, 0)) AS is_trial
    FROM daily_subs
    WHERE sub_rank = 1 
    GROUP BY account_id, obs_date
),

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
        COALESCE(LAG(active_mrr_run_rate, 1) OVER (PARTITION BY account_id ORDER BY obs_date), 0) AS prev_day_mrr,
        (active_mrr_run_rate - COALESCE(LAG(active_mrr_run_rate, 1) OVER (PARTITION BY account_id ORDER BY obs_date), 0)) AS net_mrr_delta
    FROM financial_state
),

telemetry_rollup AS (
    SELECT 
        s.account_id,
        fu.usage_date AS activity_date,
        SUM(fu.usage_duration_secs) AS daily_time_in_app,
        SUM(fu.error_count) AS daily_friction_events,
        SUM(fu.is_beta_feature) AS beta_interactions
    FROM ravenstack_raw.ravenstack_feature_usage fu
    JOIN ravenstack_raw.ravenstack_subscriptions s ON fu.subscription_id = s.subscription_id
    GROUP BY s.account_id, fu.usage_date
),

support_friction AS (
    SELECT 
        account_id,
        CAST(submitted_at AS DATE) AS ticket_date,
        COUNT(ticket_id) AS support_volume,
        AVG(resolution_time_hours) AS avg_resolution_time,
        AVG(satisfaction_score) AS avg_csat_score
    FROM ravenstack_raw.ravenstack_support_tickets
    GROUP BY account_id, CAST(submitted_at AS DATE)
),

latest_churn AS (
    SELECT 
        account_id,
        MAX(churn_date) AS churn_date
    FROM ravenstack_raw.ravenstack_churn_events
    GROUP BY account_id
)

SELECT 
    sp.account_id,
    sp.obs_date AS observation_date,
    sp.industry,
    sp.baseline_tier,
    sp.referral_source,
    
    COALESCE(fv.active_mrr_run_rate, 0) AS active_mrr_run_rate,
    COALESCE(fv.daily_billing_accrual, 0) AS daily_billing_accrual,
    fv.billing_frequency,
    COALESCE(fv.auto_renew_flag, 0) AS auto_renew_flag,
    COALESCE(fv.is_trial, 0) AS is_trial,
    COALESCE(fv.downgrade_flag, 0) AS downgrade_flag,
    
    COALESCE(tr.daily_time_in_app, 0) AS daily_time_in_app,
    COALESCE(tr.daily_friction_events, 0) AS daily_friction_events,
    COALESCE(tr.beta_interactions, 0) AS beta_interactions,
    
    COALESCE(sf.support_volume, 0) AS ticket_volume,
    sf.avg_resolution_time,
    sf.avg_csat_score,
    
    CASE 
        WHEN c.churn_date IS NOT NULL AND c.churn_date = sp.obs_date THEN 1 
        ELSE 0 
    END AS target_churn_flag,

    CASE 
        WHEN c.churn_date IS NOT NULL AND c.churn_date = sp.obs_date THEN -COALESCE(fv.prev_day_mrr, 0)
        ELSE COALESCE(fv.net_mrr_delta, 0)
    END AS net_mrr_delta
    
FROM account_spine sp
LEFT JOIN financial_vectors fv ON sp.account_id = fv.account_id AND sp.obs_date = fv.obs_date
LEFT JOIN telemetry_rollup tr ON sp.account_id = tr.account_id AND sp.obs_date = tr.activity_date
LEFT JOIN support_friction sf ON sp.account_id = sf.account_id AND sp.obs_date = sf.ticket_date
LEFT JOIN latest_churn c ON sp.account_id = c.account_id
ORDER BY sp.account_id, sp.obs_date;


/*DATABASE OPTIMIZATION */
CREATE INDEX idx_sub_account_id ON ravenstack_raw.ravenstack_subscriptions(account_id);
CREATE INDEX idx_usage_sub_id ON ravenstack_raw.ravenstack_feature_usage(subscription_id);
CREATE INDEX idx_support_account_id ON ravenstack_raw.ravenstack_support_tickets(account_id);
CREATE INDEX idx_churn_account_id ON ravenstack_raw.ravenstack_churn_events(account_id);

/* RBAC ISOLATION*/
CREATE USER IF NOT EXISTS 'risk_engine_service'@'%' IDENTIFIED BY 'SecurePassword123!';
GRANT SELECT ON ravenstack_features.vw_revenue_retention_matrix TO 'risk_engine_service'@'%';
FLUSH PRIVILEGES;