# RavenStack — Enterprise Retention Risk Engine

A subscription business loses customers every month. The metric that decides whether a company survives is simple: do you find out that a customer is unhappy *before* they cancel, or *after*?

This project builds the "before." It takes raw, messy SaaS data — signups, billing events, product usage, support tickets, and cancellations — and transforms it into a proactive retention engine.

Designed exactly how a modern data team would build it for a real company, this project bridges the gap between raw data and business action. It provides a live executive dashboard to show leadership exactly where revenue is leaking, and a machine learning application that flags at-risk customers weeks before they actually leave.

---

## The Business Value

This pipeline answers the three most critical questions for any recurring revenue business:

### 1. Where is the money, and is it growing or shrinking?

Monthly recurring revenue grew 117× over two years, but growth was volatile. The data reveals six separate months where the company lost more revenue to cancellations than it gained from new and expanding customers. The worst single month was June 2024, which recorded net losses of $95,379.

### 2. Who is leaving, and why?

Enterprise accounts drove **39% of all revenue lost to cancellations** — disproportionate for the highest-paying tier. Furthermore, when customers exit, the single biggest reported reason is **missing product features**, cited in 19% of all cancellations.

### 3. Can we predict who leaves next, before they do?

**Yes.** A predictive machine learning model analyzes each account's billing history, daily product usage, and support activity. It assigns every active customer a real-time flight risk score and isolates the top two specific factors driving that risk. This allows a Customer Success team to intervene with context, rather than guessing who needs help.

---

## The Deliverables

### 1. The Executive Command Center (Tableau)

A macro-level view designed for a CEO or VP of Sales to read in under a minute. It tracks total active revenue, portfolio risk, cohort retention degradation over time, and the primary drivers behind revenue churn.

<img src="assets/01_revenue_command_center.jpg" width="100%" alt="RavenStack revenue and retention dashboard">

**[🔗 Open the Live, Interactive Executive Dashboard on Tableau Public](https://public.tableau.com/app/profile/ajibola.ayomide/viz/RavenStack_Command_Center2/RavenStackRevenueRetentionCommandCenter)**

#### Deep Dive: Cohort Retention & Revenue Loss

Of the customers who signed up in a given month, what percentage are still around 1, 6, or 12 months later? 96% of customers make it past their first month — but by month six, only 68% remain. By month twelve, only 54% are still active.

<img src="assets/02_cohort_heatmap_detail.png" width="100%" alt="Cohort retention heatmap detail">

<img src="assets/03_churn_donut_detail.png" width="100%" alt="Churned revenue by plan tier detail">

---

### 2. The Customer Success Risk Terminal (Python / Streamlit)

A micro-level, actionable internal tool. A Customer Success representative can log in every morning to see a prioritized roster of global flight risks. Selecting an individual account reveals their specific risk probability, their current monthly revenue value, and the exact behavioral triggers driving their score to provide a clear next step.

<img src="assets/04_streamlit_terminal_overview.png" width="100%" alt="Streamlit risk terminal overview">

<img src="assets/05_streamlit_critical_risk_example.png" width="100%" alt="Streamlit terminal flagging a critical risk account">

---

## Architecture & Engineering Standards

This is not a theoretical sandbox project. It is engineered to handle the edge cases and strict requirements of a production business environment.

**The Data Pipeline (SQL)**
The hardest part of churn prediction is ensuring a customer's situation on any given day is represented accurately without "leaking" future information. The SQL layer cleans five raw tables and builds a recursive daily snapshot for every customer. It tracks exact revenue, activity, and status on a daily grain. If a customer churns, their revenue accurately drops to zero on that exact day, ensuring no downstream reporting tells a falsely optimistic story.

**Real-World Model Testing (Machine Learning)**
The predictive model was subjected to an "Out-of-Cohort" evaluation. Instead of randomly shuffling all customers together (which allows a model to accidentally peek at future trends), the model was trained exclusively on older customers and tested on entirely new customers it had never seen before. This proves the model can actually generalize to new business, rather than just memorizing historical data.

**Production Safeguards (Application Layer)**
The internal web application is built defensively. It includes automatic data-freshness caching, schema validation to prevent crashes if the upstream data changes, and mathematical safeguards to prevent division-by-zero errors in edge cases (such as a cohort temporarily having zero active revenue).

---

## How the Pipeline Flows

```text
Raw CSV Data (Signups, Billing, Usage, Support, Cancellations)
        │
        ▼
MySQL Data Warehouse
(Cleans data, handles type coercion safely, and generates a unified daily fact table)
        │
        ├──────────────────────────────────────────┐
        ▼                                           ▼
Tableau Dashboard                          Python Machine Learning Engine
(Executive macro-reporting)                (Trains LightGBM model, extracts SHAP drivers,
                                             and generates live risk scores)
                                                    │
                                                    ▼
                                            Streamlit Web Application
                                            (The interactive risk terminal for Customer Success)
```

---

## Repository Structure

```plaintext
ravenstack-churn-risk-engine/
│
├── data/               Source data and the generated daily feature dataset
├── sql/                MySQL scripts: schema creation, loading, and the daily spine procedure
├── notebooks/          Jupyter environment: feature engineering, survival analysis, and model training
├── app/                The Streamlit web application and serialized model artifacts
├── dashboard/          The Tableau workbook files
├── assets/             Images and architecture diagrams for documentation
├── requirements.txt    Python environment dependencies
└── README.md
```

---

## Running It Locally

### 1. Clone the Repository

```bash
git clone https://github.com/ajibola-analyst/ravenstack-churn-risk-engine.git
cd ravenstack-churn-risk-engine
```

### 2. Set Up the Isolated Environment

```bash
python -m venv venv

# Windows:
venv\Scripts\activate

# Mac/Linux:
source venv/bin/activate

pip install -r requirements.txt
```

### 3. Generate the Data Spine

Execute the SQL scripts in `sql/` using MySQL Workbench to process the raw data and export `fact_daily_spine_export.csv` into the `data/` directory.

### 4. Train the Model & Generate Scores

Open `notebooks/risk_engine.ipynb` and execute the pipeline. This will process the daily spine, train the predictive engine, and route the live scoring matrix to the application folder.

### 5. Launch the Executive Terminal

```bash
cd app
streamlit run app.py
```

---

## About the Data

This project utilizes the RavenStack synthetic SaaS dataset. It contains 500 simulated customer accounts spanning two years of signups, billing events, product usage telemetry, support tickets, and cancellations. The data is entirely synthetic and contains no personally identifiable information (PII). Credit to River @ Rivalytics for the original underlying dataset generation.
