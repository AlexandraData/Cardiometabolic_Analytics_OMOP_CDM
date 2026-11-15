"""
11_build_features.py  -  build the patient feature table
=========================================================
Output: segmentation_output/patient_features.csv   (one row per cohort patient, 613 rows)

The table has two kinds of columns, kept strictly apart:

  A) FEATURES  -> used to build the segments (script 12)
       age_at_index and win_<condition> (14 comorbidity flags in the first 5 years)
       (sex 'male' is stored too, but only to describe the segments, see config.py)

  B) OUTCOMES / DESCRIPTORS -> NOT used for clustering, only to describe the segments (script 13)
       first-line drug class, treated within 1 year, time to treatment, visits before/after...

Why keep them apart?  If treatment were a feature, the segments would simply be
"people who got drug X", and asking "does treatment differ by segment?" would be circular.
"""
import numpy as np
import pandas as pd
from config import (DATA_DIR, OUT_DIR, CONDITIONS, CONDITION_GROUPS, FLAG_COLUMNS,
                    WINDOW_YEARS)

DAYS_PER_YEAR = 365.25

# ----------------------------------------------------------------------------
# 1. Load the exported tables
# ----------------------------------------------------------------------------
# fact_cardio_cohort: one row per cohort patient (613). Holds the index date (date of the
# first of the 5 cohort conditions), the initial drug, treatment flags and observation dates.
cohort = pd.read_csv(
    DATA_DIR / "fact_cardio_cohort.csv",
    parse_dates=["index_date", "obs_start", "obs_end", "first_rx_date"],
)

# fact_condition_flags: one row per patient (1,163). For each of the 16 conditions a 0/1 flag
# and the date of the FIRST record of that condition (<condition>_date).
flags = pd.read_csv(DATA_DIR / "fact_condition_flags.csv")
for cond in CONDITIONS:
    flags[f"{cond}_date"] = pd.to_datetime(flags[f"{cond}_date"])

# cdm_person: sex (F / M) and race text.
person = pd.read_csv(DATA_DIR / "cdm_person.csv",
                     usecols=["person_id", "gender_source_value", "race_source_value"])

# fact_hru_utilization: visits in the year before / after the index date.
# Only patients with a full year on BOTH sides are in this table (487 of 613).
hru = pd.read_csv(DATA_DIR / "fact_hru_utilization.csv").drop(columns="primary_indication")

# cdm_visit_occurrence: needed for emergency-room visits (visit_concept_id 9203),
# which the HRU table does not contain.
visits = pd.read_csv(
    DATA_DIR / "cdm_visit_occurrence.csv",
    usecols=["person_id", "visit_concept_id", "visit_start_date"],
    parse_dates=["visit_start_date"],
)

# ----------------------------------------------------------------------------
# 2. Base table: cohort + sex + condition flags
# ----------------------------------------------------------------------------
df = (cohort
      .merge(person, on="person_id", how="left")
      .merge(flags[["person_id"] + [f"{c}_date" for c in CONDITIONS]], on="person_id", how="left"))

# Sex as a 0/1 column (1 = male).  Clustering algorithms need numbers.
df["male"] = (df["gender_source_value"] == "M").astype(int)

# ----------------------------------------------------------------------------
# 3. Who can be clustered?  Enough follow-up for the full comorbidity window
# ----------------------------------------------------------------------------
# follow_up_years = time from the index date to the end of the patient's observation
# (death date, or the end of the data extract).
df["follow_up_years"] = (df["obs_end"] - df["index_date"]).dt.days / DAYS_PER_YEAR
df["eligible_for_segmentation"] = (df["follow_up_years"] >= WINDOW_YEARS).astype(int)

# ----------------------------------------------------------------------------
# 4. FEATURE ENGINEERING: comorbidity flags inside the window
# ----------------------------------------------------------------------------
# For each condition: 1 if its first record is on or before  index_date + WINDOW_YEARS,
# else 0.  Conditions BEFORE the index date count too (they are part of the starting profile).
# Example: index date 2010-03-01, window 5 years -> a hypertension diagnosis on 2013-06-10
# counts, a stroke on 2018-01-01 does not.
window_end = df["index_date"] + pd.to_timedelta(round(WINDOW_YEARS * DAYS_PER_YEAR), unit="D")
for cond in CONDITIONS:
    first_date = df[f"{cond}_date"]                       # NaT if the patient never had it
    df[f"win_{cond}"] = (first_date.notna() & (first_date <= window_end)).astype(int)

# Summary columns used only for description (NOT for clustering: they are sums of the flags,
# so adding them would count the same information twice).
df["n_conditions_window"] = df[FLAG_COLUMNS].sum(axis=1)
for group, members in CONDITION_GROUPS.items():
    df[f"n_{group.lower()}_window"] = df[[f"win_{c}" for c in members]].sum(axis=1)

# ----------------------------------------------------------------------------
# 5. OUTCOMES for profiling (computed from the cohort file and the other tables)
# ----------------------------------------------------------------------------
# (a) Already in fact_cardio_cohort:
#     tx_event       1 = first core drug within 365 days of the index date
#     treated_ever   1 = a core drug at any time after the index date
#     time_to_tx     days to the first core drug (or days of follow-up if untreated, capped at 365)
#     initial_drug_class, n_initial_classes (classes started on the first drug day)
df["started_combination"] = (df["n_initial_classes"] > 1).astype(float)
df.loc[df["n_initial_classes"].isna(), "started_combination"] = np.nan   # untreated: not applicable
df["initial_drug_class"] = df["initial_drug_class"].fillna("No Treatment")

# (b) Outpatient / inpatient visits before and after the index date, from fact_hru_utilization.
df = df.merge(hru, on="person_id", how="left")

# (c) Emergency-room visits in the year AFTER the index date.
#     Patients without a full year of follow-up get NaN (not 0): we do not know.
v = visits.merge(df[["person_id", "index_date", "followup_365"]], on="person_id", how="inner")
in_year_after = ((v["visit_start_date"] > v["index_date"]) &
                 (v["visit_start_date"] <= v["index_date"] + pd.Timedelta(days=365)))
er_after = (v[in_year_after & (v["visit_concept_id"] == 9203)]
            .groupby("person_id").size().rename("post_er"))
df = df.merge(er_after, on="person_id", how="left")
df["post_er"] = df["post_er"].fillna(0)
df.loc[df["followup_365"] != 1, "post_er"] = np.nan

# (d) OPTIONAL: number of different core drug classes taken in the year after the index date.
#     Needs dim_drug_class.csv (exported by script 10) next to the other files.
dim_path = DATA_DIR / "dim_drug_class.csv"
df["n_core_classes_1y"] = np.nan
if dim_path.exists():
    dim = pd.read_csv(dim_path, dtype={"source_code": str})
    needed = {"source_code", "drug_class", "core_flag"}
    if needed.issubset(dim.columns):
        core = dim.loc[dim["core_flag"] == 1, ["source_code", "drug_class"]]
        drugs = pd.read_csv(
            DATA_DIR / "cdm_drug_exposure.csv",
            usecols=["person_id", "drug_source_value", "drug_exposure_start_date"],
            parse_dates=["drug_exposure_start_date"], dtype={"drug_source_value": str},
        )
        d = (drugs.merge(core, left_on="drug_source_value", right_on="source_code")
                  .merge(df[["person_id", "index_date", "followup_365"]], on="person_id"))
        in_year = ((d["drug_exposure_start_date"] >= d["index_date"]) &
                   (d["drug_exposure_start_date"] <= d["index_date"] + pd.Timedelta(days=365)))
        n_classes = (d[in_year].groupby("person_id")["drug_class"].nunique()
                     .rename("n_core_classes_1y"))
        df = df.drop(columns="n_core_classes_1y").merge(n_classes, on="person_id", how="left")
        df["n_core_classes_1y"] = df["n_core_classes_1y"].fillna(0)
        df.loc[df["followup_365"] != 1, "n_core_classes_1y"] = np.nan
    else:
        print(f"dim_drug_class.csv found but columns {needed - set(dim.columns)} are missing: skipped")
else:
    print("dim_drug_class.csv not found: n_core_classes_1y left empty (optional)")

# ----------------------------------------------------------------------------
# 6. Save
# ----------------------------------------------------------------------------
keep = (["person_id", "eligible_for_segmentation", "follow_up_years",
         # features
         "age_at_index", "male"] + FLAG_COLUMNS +
        # descriptors / outcomes
        ["n_conditions_window", "n_cardiovascular_window", "n_metabolic_window", "n_related_window",
         "primary_indication", "race", "gender", "index_date", "obs_end",
         "initial_drug_class", "tx_event", "treated_ever", "time_to_tx", "n_initial_classes",
         "started_combination", "followup_365", "prior_obs_365",
         "pre_outpatient", "post_outpatient", "pre_inpatient", "post_inpatient",
         "pre_outpatient_no_wellness", "post_outpatient_no_wellness", "post_er",
         "n_core_classes_1y"])
out = df[keep].sort_values("person_id")
out.to_csv(OUT_DIR / "patient_features.csv", index=False)

# ----------------------------------------------------------------------------
# 7. Quick checks printed to the console
# ----------------------------------------------------------------------------
print(f"Cohort patients               : {len(out)}")
print(f"Eligible (>= {WINDOW_YEARS} y follow-up)  : {int(out['eligible_for_segmentation'].sum())}")
print("\nShare of eligible patients with each condition inside the window:")
elig = out[out["eligible_for_segmentation"] == 1]
print((elig[FLAG_COLUMNS].mean().rename(lambda c: c.replace("win_", "")) * 100).round(1)
      .sort_values(ascending=False).to_string())
print("\nAge at index: ", elig["age_at_index"].describe().round(1).to_dict())
print("Many Synthea patients are diagnosed at the first adult check-up (age 18): "
      f"{(elig['age_at_index'] == 18).mean():.0%} of eligible patients have age 18 at index.")
assert out["person_id"].is_unique, "person_id must be unique"
print(f"\nSaved {OUT_DIR / 'patient_features.csv'}")
