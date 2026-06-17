import streamlit as st
import pandas as pd
import joblib
import os


st.set_page_config(
    page_title="RavenStack CRO Terminal",
    page_icon="🦅",
    layout="wide",
    initial_sidebar_state="collapsed"
)

# Custom HTML/CSS Injection for the Elite Frost & Indigo Aesthetic
CSS_OVERRIDE = """
<style>
    /* Main Background - Calming Frost Blue/Lavender */
    .stApp {
        background-color: #EFF1FF;
        color: #1E293B;
        font-family: 'Inter', 'Segoe UI', sans-serif;
    }
    
    /* FIX: Force Widget Labels Visible ("Enter or Select Account ID") */
    label, div[data-testid="stWidgetLabel"] p, .stSelectbox label p {
        color: #1E293B !important;
    }
    
    /* Input Boxes & Dropdowns - Crisp White */
    div[data-baseweb="select"] > div {
        background-color: #FFFFFF !important;
        color: #1E293B !important;
        border: 1px solid #CBD5E1 !important;
        border-radius: 8px !important;
        box-shadow: 0 2px 4px rgba(0,0,0,0.02) !important;
    }
    
    /* Metric Cards - Pure White with Diffuse Shadow and Indigo Top Border */
    div[data-testid="metric-container"] {
        background-color: #FFFFFF !important;
        border: 1px solid #E2E8F0 !important;
        border-top: 4px solid #6366F1 !important; 
        padding: 20px !important;
        border-radius: 12px !important;
        box-shadow: 0px 8px 24px rgba(149, 157, 165, 0.15) !important;
        transition: transform 0.2s ease-in-out, box-shadow 0.2s ease-in-out;
    }
    
    div[data-testid="metric-container"]:hover {
        transform: translateY(-3px);
        box-shadow: 0px 12px 32px rgba(149, 157, 165, 0.25) !important;
    }
    
    /* NUKE-PROOF METRIC COLORS: Forces ALL text inside the white cards to be dark */
    div[data-testid="metric-container"] *, div[data-testid="stMetric"] * {
        color: #0F172A !important;
    }
    
    /* Specific styling for the big value numbers */
    div[data-testid="stMetricValue"] > div {
        font-weight: 800 !important;
        font-size: 2.2rem !important;
        color: #0F172A !important;
    }
    
    /* FIX: Specific styling for the upper label (Current ARR Exposure, etc) */
    div[data-testid="stMetricLabel"] *, div[data-testid="stMetricLabel"] p {
        color: #475569 !important;
        font-weight: 700 !important;
        font-size: 1.05rem !important;
    }

    /* FIX: Specific styling for the lower subtext/delta (Based on 180 days...) */
    div[data-testid="stMetricDelta"] *, div[data-testid="stMetricDelta"] div, div[data-testid="stMetricDelta"] svg {
        color: #64748B !important;
        font-weight: 600 !important;
    }
    
    /* Header Typography - Deep Slate */
    h1, h2, h3, h4 {
        color: #0F172A !important;
        font-weight: 700 !important;
        letter-spacing: -0.5px;
    }
    
    /* Divider Lines */
    hr {
        border-color: #CBD5E1 !important;
    }
    
    /* Custom Risk Status Text Colors */
    .status-critical { color: #EF4444; font-weight: 800; font-size: 1.2rem; }
    .status-warning { color: #F59E0B; font-weight: 800; font-size: 1.2rem; }
    .status-stable { color: #10B981; font-weight: 800; font-size: 1.2rem; }
    
    /* Info Box Override - Clean White with Indigo Accent */
    .stAlert {
        background-color: #FFFFFF !important;
        border-left: 4px solid #6366F1 !important;
        color: #1E293B !important;
        border-radius: 8px !important;
        box-shadow: 0 4px 12px rgba(0,0,0,0.05) !important;
    }
    
    /* Hide Streamlit Branding */
    #MainMenu {visibility: hidden;}
    footer {visibility: hidden;}
    header {visibility: hidden;}
</style>
"""
st.markdown(CSS_OVERRIDE, unsafe_allow_html=True)

# HIGH-SPEED DATA INGESTION (DECOUPLED MEMORY CACHING)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

@st.cache_data
def load_scoring_matrix():
    file_path = os.path.join(BASE_DIR, '../data/live_flight_risk_scores.csv')
    if not os.path.exists(file_path):
        st.error(f"SYSTEM HALT: {file_path} not found.")
        st.stop()
    return pd.read_csv(file_path)

@st.cache_resource
def load_ml_artifacts():
    file_path = os.path.join(BASE_DIR, 'ravenstack_survival_model.pkl')
    try:
        return joblib.load(file_path)
    except Exception as e:
        return None

df_scores = load_scoring_matrix()
kmf = load_ml_artifacts()


# THE CRO TERMINAL UI (SEARCH & FILTER)
st.title("🦅 RavenStack Executive Ops Terminal")
st.markdown("### Algorithmic Risk & Revenue Intervention Engine")
st.markdown("<hr style='border: 1px solid #CBD5E1;'>", unsafe_allow_html=True)

col_search, col_spacer = st.columns([1, 2])

with col_search:
    account_list = df_scores['account_id'].tolist()
    selected_account = st.selectbox("Enter or Select Account ID:", ["-- AWAITING INPUT --"] + account_list)


# THE DIAGNOSTIC READOUT 
if selected_account != "-- AWAITING INPUT --":
    
    client_data = df_scores[df_scores['account_id'] == selected_account].iloc[0]
    
    current_mrr = client_data['active_mrr_run_rate']
    current_arr = current_mrr * 12  
    risk_score = client_data['flight_risk_score']
    industry = client_data['industry']
    primary_drivers = client_data['primary_risk_drivers']
    
    if risk_score >= 0.70:
        threat_level_html = '<span class="status-critical">CRITICAL RISK (Intervene Immediately)</span>'
    elif risk_score >= 0.40:
        threat_level_html = '<span class="status-warning">ELEVATED RISK (Monitor Closely)</span>'
    else:
        threat_level_html = '<span class="status-stable">STABLE (Standard Lifecycle)</span>'

    st.markdown(f"#### Account Diagnostic: `{selected_account}` | Sector: {industry.title()}")
    st.markdown(f"**Current Status:** {threat_level_html}", unsafe_allow_html=True)
    st.write("")
    
    kpi1, kpi2, kpi3 = st.columns(3)
    
    with kpi1:
        st.metric(label="Current ARR Exposure", value=f"${current_arr:,.2f}")
    
    with kpi2:
        st.metric(label="Algorithmic Flight Risk", value=f"{risk_score * 100:.1f}%")
        
    with kpi3:
        if kmf is not None:
            tenure = client_data.get('tenure_days', 180)
            
            prob_now = float(kmf.predict(tenure))
            prob_next_month = float(kmf.predict(tenure + 30))
            
            survival_prob = (prob_next_month / prob_now) if prob_now > 0 else 0.0
            
            st.metric(
                label="30-Day Conditional Retention", 
                value=f"{survival_prob * 100:.1f}%",
                delta=f"Baseline absolute survival: {prob_now * 100:.1f}%",
                delta_color="off"
            )
        else:
            st.metric(label="System Architecture", value="Decoupled")
            
    st.markdown("<hr style='border: 1px solid #CBD5E1;'>", unsafe_allow_html=True)
    
    st.markdown("### Algorithmic Driver Analysis")
    st.info(f"**Primary Factors Driving Churn Probability:**\n\n{primary_drivers}")
    
    st.markdown("*Directive: Route this account to the Customer Success rapid-response queue and execute the standardized friction-mitigation playbook.*")

else:
    st.markdown("<br><br><br><center><h4 style='color:#94A3B8;'>Awaiting Account Query...</h4></center>", unsafe_allow_html=True)