"""
config.py  -  settings shared by the three segmentation scripts
================================================================
Project : Cardiometabolic Population Analysis (OMOP CDM v5.4 on Synthea)
Step    : patient segmentation (clustering)

Run order (from VS Code, any folder; each script is independent of the terminal path):
    11_build_features.py       one row per patient: features for clustering + outcomes for profiling
    12_choose_k_and_cluster.py compare algorithms, choose the number of segments (k), assign patients
    13_profile_segments.py     describe each segment, compare treatment / visits, export for Power BI

Python packages (Python 3.9+):
    pip install pandas numpy scikit-learn scipy matplotlib
"""
from pathlib import Path

# ----------------------------------------------------------------------------
# 1. Folders
# ----------------------------------------------------------------------------
# DATA_DIR : folder with the CSV files exported by SAS script 10 (omop_project/export).
#            Needed files: cdm_person, cdm_visit_occurrence, cdm_drug_exposure,
#            fact_cardio_cohort, fact_condition_flags, fact_hru_utilization
#            Optional    : dim_drug_class (adds "number of core drug classes in year 1")
# EDIT THIS LINE if your CSV files are somewhere else, e.g. Path(r"C:\Users\you\omop_project\export")
HERE = Path(__file__).resolve().parent
DATA_DIR = HERE.parent / "data"

HERE = Path(__file__).resolve().parent
DATA_DIR = Path(r"C:\Users\yourname\cardiometabolic_population")

# OUT_DIR : everything the scripts create (tables and figures) goes here.
#OUT_DIR = HERE.parent / "segmentation_output"
OUT_DIR = Path(r"C:\Users\yourname\cardiometabolic_population\Output_Statistics")
OUT_DIR.mkdir(parents=True, exist_ok=True)

# ----------------------------------------------------------------------------
# 2. Study design
# ----------------------------------------------------------------------------
# The clustering uses each patient's comorbidity profile in the first WINDOW_YEARS
# years from the index diagnosis (the first of the five cohort conditions).
# Why a fixed window?  A patient followed for 40 years has more time to collect
# diagnoses than one followed for 6, so "number of conditions" would mostly measure
# follow-up length.  Same window for everybody = fair comparison.
# Patients with less follow-up than the window are left out of the clustering
# (they are still exported, as "Not segmented").
WINDOW_YEARS = 5

# Features present in fewer than this share of the clustered patients are dropped
# from the clustering (a flag that is almost always 0 adds noise, not structure).
# They are still shown in the segment profile.
MIN_FEATURE_PREVALENCE = 0.02

# ----------------------------------------------------------------------------
# 3. Clustering settings
# ----------------------------------------------------------------------------
RANDOM_STATE = 42
K_RANGE = range(2, 9)          # numbers of segments to compare
N_BOOTSTRAP = 100              # resamples used to measure how stable the segments are
MIN_SEGMENT_SHARE = 0.05       # a segment should contain at least 5% of the patients
MIN_STABILITY = 0.80           # mean adjusted Rand index (ARI) needed to call a k "stable"
SCALING = "minmax"             # "minmax": every feature 0-1 (flags keep their natural scale)
                               # "standard": z-scores (rare flags get a big weight)
FINAL_METHOD = "kmeans"        # "kmeans", "ward" or "gower_average"
K_FINAL = None                 # None = chosen by the rule in script 12; or type a number, e.g. 4

# ----------------------------------------------------------------------------
# 4. Conditions used as features (names match the columns of fact_condition_flags)
# ----------------------------------------------------------------------------
# Insulin resistance and NAFLD are left out: Synthea has no codes for them (always 0).
CONDITION_GROUPS = {
    "Cardiovascular": ["heart_attack", "cardiac_arrest", "stroke",
                       "coronary_artery_disease", "heart_failure"],
    "Metabolic":      ["type2_diabetes", "obesity", "diabetic_complications",
                       "hyperglycemia", "prediabetes", "metabolic_syndrome"],
    "Related":        ["hypertension", "dyslipidemia", "kidney_disease"],
}
CONDITIONS = [c for group in CONDITION_GROUPS.values() for c in group]
CONDITION_LABELS = {c: c.replace("_", " ").title() for c in CONDITIONS}
CONDITION_LABELS["type2_diabetes"] = "Type 2 Diabetes"
CONDITION_LABELS["coronary_artery_disease"] = "Coronary Artery Disease"
CONDITION_LABELS["heart_attack"] = "Heart Attack (MI)"

# Column names created by script 11
FLAG_COLUMNS = [f"win_{c}" for c in CONDITIONS]          # condition present within the window
# Sex is NOT a clustering input: with it, the first test run produced one all-male and one
# all-female segment with the same conditions, i.e. a split that says nothing clinical.
# Sex (and race) are used to DESCRIBE the segments instead (script 13).
FEATURE_COLUMNS = ["age_at_index"] + FLAG_COLUMNS         # inputs of the clustering
NUMERIC_FEATURES = ["age_at_index"]                       # all others are 0/1 flags
