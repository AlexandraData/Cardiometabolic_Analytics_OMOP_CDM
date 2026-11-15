"""
13_profile_segments.py  -  describe the segments and compare treatment / resource use
=========================================================================================
Input : segmentation_output/patient_features.csv      (script 11)
        segmentation_output/segment_assignments.csv   (script 12)
Output: segmentation_output/segment_profile.csv       one row per segment (summary table)
        segmentation_output/segment_tests.csv         statistical tests on the OUTCOMES
        segmentation_output/fig_*.png                 figures for the portfolio page
        segmentation_output/fact_patient_segments.csv   -> Power BI (one row per cohort patient)
        segmentation_output/dim_segment.csv             -> Power BI (one row per segment)
        segmentation_output/fact_segment_condition.csv  -> Power BI (condition prevalence by segment)

Two questions are answered here:
  1. WHO are the segments?     (profile = the features that built them, so differences are expected)
  2. Do they DIFFER IN CARE?   (outcomes = first-line drug class, treated within 1 year,
                                 visits - NOT used to build the segments, so a difference is a finding)
Statistical tests are only run on the outcomes: testing the features would be circular
(the clusters were built to differ on them).
"""
import textwrap

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import chi2_contingency, kruskal
from sklearn.decomposition import PCA
from sklearn.preprocessing import MinMaxScaler

from config import (OUT_DIR, CONDITIONS, CONDITION_GROUPS, CONDITION_LABELS, FLAG_COLUMNS,
                    FEATURE_COLUMNS, NUMERIC_FEATURES, MIN_FEATURE_PREVALENCE, RANDOM_STATE)

# ----------------------------------------------------------------------------
# 0. Names for the segments.
#    Leave empty to use the suggested names, or write your own after looking at the profile, e.g.
#    SEGMENT_NAMES = {1: "Hypertension, low burden", 2: "Prediabetes and obesity", ...}
# ----------------------------------------------------------------------------
SEGMENT_NAMES = {
    1: "S1 Early hypertension",
    2: "S2 Prediabetes",
    3: "S3 Dyslipidemia + obesity",
    4: "S4 Multimorbid T2D",
}
# The keys are segment numbers (1 = largest).  If you change the settings in config.py and rerun
# script 12, check which segment is which before reusing these names.

PALETTE = ["#1F4E79", "#2E75B6", "#9DC3E6", "#F4B183", "#A9A9A9", "#70AD47", "#7F6000"]

# ----------------------------------------------------------------------------
# 1. Load and merge
# ----------------------------------------------------------------------------
feat = pd.read_csv(OUT_DIR / "patient_features.csv")
seg = pd.read_csv(OUT_DIR / "segment_assignments.csv")[["person_id", "segment_id"]]
df = feat.merge(seg, on="person_id", how="left")
df["segment_id"] = df["segment_id"].fillna(0).astype(int)      # 0 = not clustered (< 5 years of follow-up)
prof = df[df["segment_id"] > 0].copy()                          # the clustered patients
segments = sorted(prof["segment_id"].unique())
print(f"Clustered patients: {len(prof)} in {len(segments)} segments; not segmented: {(df['segment_id'] == 0).sum()}")


# ----------------------------------------------------------------------------
# 2. Suggested names: the conditions that define each segment
# ----------------------------------------------------------------------------
# lift = how much more common a condition is in the segment than in all clustered patients.
overall = prof[FLAG_COLUMNS].mean()


def suggest_name(sub):
    seg_prev = sub[FLAG_COLUMNS].mean()
    lift = seg_prev / overall.replace(0, np.nan)
    # defining conditions: present in >= 35% of the segment and at least 1.3x as common as overall
    defining = seg_prev[(seg_prev >= 0.35) & (lift >= 1.3)].sort_values(ascending=False).index[:2]
    label = " + ".join(CONDITION_LABELS[c.replace("win_", "")] for c in defining)
    if not label:   # nothing stands out: describe the most common condition instead
        top = seg_prev.sort_values(ascending=False).index[0]
        label = f"Mainly {CONDITION_LABELS[top.replace('win_', '')]}"
    # age modifier: 6+ years away from the overall mean age at index
    diff = sub["age_at_index"].mean() - prof["age_at_index"].mean()
    if diff >= 6:
        label += " (older)"
    elif diff <= -6:
        label += " (younger)"
    return label


names = {s: SEGMENT_NAMES.get(s) or f"S{s} · {suggest_name(prof[prof['segment_id'] == s])}" for s in segments}
names[0] = "Not segmented (<5 y follow-up)"
df["segment_name"] = df["segment_id"].map(names)
prof["segment_name"] = prof["segment_id"].map(names)


# ----------------------------------------------------------------------------
# 3. Profile table: one row per segment
# ----------------------------------------------------------------------------
def wilson(k, n, z=1.96):
    """95% confidence interval for a proportion (Wilson).  Honest about small segments."""
    if n == 0:
        return (np.nan, np.nan)
    p = k / n
    centre = (p + z**2 / (2 * n)) / (1 + z**2 / n)
    half = z * np.sqrt(p * (1 - p) / n + z**2 / (4 * n**2)) / (1 + z**2 / n)
    return centre - half, centre + half


rows = []
for s in segments:
    g = prof[prof["segment_id"] == s]
    treated = g[g["tx_event"] == 1]
    hru = g[g["post_outpatient_no_wellness"].notna()]        # patients with a full year before and after
    lo, hi = wilson(g["tx_event"].sum(), len(g))
    row = {
        "segment_id": s, "segment_name": names[s], "patients": len(g),
        "share_of_clustered": len(g) / len(prof),
        # who they are (features)
        "age_at_index_mean": g["age_at_index"].mean(), "pct_male": g["male"].mean(),
        "n_conditions_mean": g["n_conditions_window"].mean(),
        # outcomes
        "pct_treated_1y": g["tx_event"].mean(), "pct_treated_1y_ci_low": lo, "pct_treated_1y_ci_high": hi,
        "pct_treated_ever": g["treated_ever"].mean(),
        "median_days_to_tx_treated": treated["time_to_tx"].median(),
        "pct_combination_start": g.loc[g["treated_ever"] == 1, "started_combination"].mean(),
        "patients_with_hru": len(hru),
        "post_outpatient_no_wellness_mean": hru["post_outpatient_no_wellness"].mean(),
        "pre_outpatient_no_wellness_mean": hru["pre_outpatient_no_wellness"].mean(),
        "post_inpatient_mean": hru["post_inpatient"].mean(),
        "post_er_mean": hru["post_er"].mean(),
        "n_core_classes_1y_mean": g["n_core_classes_1y"].mean(),
    }
    for c, flag in zip(CONDITIONS, FLAG_COLUMNS):
        row[f"pct_{c}"] = g[flag].mean()
    for ind in sorted(prof["primary_indication"].unique()):
        row[f"pct_index_{ind.replace(' ', '_').lower()}"] = (g["primary_indication"] == ind).mean()
    rows.append(row)
profile = pd.DataFrame(rows)
profile.to_csv(OUT_DIR / "segment_profile.csv", index=False)

show = ["segment_name", "patients", "age_at_index_mean", "pct_male", "n_conditions_mean",
        "pct_treated_1y", "pct_treated_ever", "median_days_to_tx_treated",
        "post_outpatient_no_wellness_mean", "post_inpatient_mean"]
print("\n", profile[show].round(2).to_string(index=False))

# ----------------------------------------------------------------------------
# 4. Tests on the OUTCOMES (not on the features)
# ----------------------------------------------------------------------------
# Chi-square for yes/no and category outcomes, Kruskal-Wallis (rank test, no normality needed)
# for numeric outcomes.  Cramer's V = effect size for chi-square (0 none ... 1 perfect).
# Several tests are run on the same patients: read the p-values as a guide, not as proof.
tests = []


def chi_test(label, series):
    table = pd.crosstab(prof["segment_id"], series)
    chi2, p, dof, expected = chi2_contingency(table)
    v = np.sqrt(chi2 / (table.values.sum() * (min(table.shape) - 1)))
    tests.append({"outcome": label, "test": "chi-square", "p_value": p, "effect_size": v,
                  "note": "Cramer's V; expected counts <5 make p unreliable" if (expected < 5).any() else "Cramer's V"})


def kw_test(label, column, subset):
    groups = [subset.loc[subset["segment_id"] == s, column].dropna() for s in segments]
    groups = [g for g in groups if len(g) > 0]
    h, p = kruskal(*groups)
    eta = max(0.0, (h - len(groups) + 1) / (sum(len(g) for g in groups) - len(groups)))
    tests.append({"outcome": label, "test": "Kruskal-Wallis", "p_value": p, "effect_size": eta,
                  "note": "epsilon-squared"})


chi_test("Treated within 1 year", prof["tx_event"])
chi_test("Treated at any time", prof["treated_ever"])
chi_test("First-line drug class", prof["initial_drug_class"])
kw_test("Days to first drug (treated within 1 year)", "time_to_tx", prof[prof["tx_event"] == 1])
kw_test("Outpatient visits after index (no wellness)", "post_outpatient_no_wellness", prof)
kw_test("Inpatient visits after index", "post_inpatient", prof)
kw_test("ER visits after index", "post_er", prof)
tests = pd.DataFrame(tests)
tests.to_csv(OUT_DIR / "segment_tests.csv", index=False)
print("\n", tests.round(4).to_string(index=False))

# Labels for the plots: the segment code on the first line, the name wrapped below it.
# Works with your own names ("S1 Early hypertension") and with the suggested ones ("S1 · Name").
def two_line(name):
    code, _, rest = name.replace(" · ", " ").partition(" ")
    return code + "\n" + textwrap.fill(rest, 16)


label_of = {s: two_line(names[s]) for s in segments}
n_of = prof["segment_id"].value_counts()

# ----------------------------------------------------------------------------
# 5. Figure 1: condition profile (heatmap)
# ----------------------------------------------------------------------------
cond_rows = [c for c in CONDITIONS if prof[f"win_{c}"].mean() > 0]
heat = np.array([[prof.loc[prof["segment_id"] == s, f"win_{c}"].mean() * 100 for s in segments]
                 for c in cond_rows])
fig, ax = plt.subplots(figsize=(1.9 * len(segments) + 3, 0.45 * len(cond_rows) + 2))
im = ax.imshow(heat, cmap="Blues", aspect="auto", vmin=0, vmax=100)
ax.set_xticks(range(len(segments)))
ax.set_xticklabels([f"{label_of[s]}\n(n={n_of[s]})" for s in segments], fontsize=8)
ax.set_yticks(range(len(cond_rows)))
ax.set_yticklabels([CONDITION_LABELS[c] for c in cond_rows])
for i in range(heat.shape[0]):
    for j in range(heat.shape[1]):
        ax.text(j, i, f"{heat[i, j]:.0f}%", ha="center", va="center",
                color="white" if heat[i, j] > 55 else "black", fontsize=8)
ax.set_title(f"Condition profile by segment (% with the condition in the first 5 years)")
plt.colorbar(im, ax=ax, label="% of segment")
plt.tight_layout()
plt.savefig(OUT_DIR / "fig_segment_condition_profile.png", dpi=150)
plt.close()

# ----------------------------------------------------------------------------
# 6. Figure 2: treatment by segment
# ----------------------------------------------------------------------------
fig, axes = plt.subplots(1, 2, figsize=(14, 4.8), gridspec_kw={"width_ratios": [1, 1.4]})
p = profile.set_index("segment_id")
err = np.array([p.loc[segments, "pct_treated_1y"] - p.loc[segments, "pct_treated_1y_ci_low"],
                p.loc[segments, "pct_treated_1y_ci_high"] - p.loc[segments, "pct_treated_1y"]]) * 100
err = np.clip(err, 0, None)        # rounding can make an error bar -0.0000001 when a rate is 0% or 100%
axes[0].bar(range(len(segments)), p.loc[segments, "pct_treated_1y"] * 100, yerr=err,
            color="#2E75B6", capsize=4)
axes[0].axhline(prof["tx_event"].mean() * 100, color="grey", linestyle="--", linewidth=1)
axes[0].text(len(segments) - 0.5, prof["tx_event"].mean() * 100 + 2, "all clustered", ha="right",
             fontsize=8, color="grey")
axes[0].set_xticks(range(len(segments)))
axes[0].set_xticklabels([label_of[s] for s in segments], fontsize=7)
axes[0].set(ylim=(0, 105), ylabel="% started a core drug within 1 year",
            title="Treated within 1 year (95% CI)")

classes = prof["initial_drug_class"].value_counts()
top = classes.index[:6].tolist()
mix = (prof.assign(cls=prof["initial_drug_class"].where(prof["initial_drug_class"].isin(top), "Other"))
       .pipe(lambda d: pd.crosstab(d["segment_id"], d["cls"], normalize="index")) * 100)
bottom = np.zeros(len(segments))
for i, cls in enumerate(mix.columns):
    axes[1].bar(range(len(segments)), mix.loc[segments, cls], bottom=bottom, label=cls,
                color=PALETTE[i % len(PALETTE)])
    bottom += mix.loc[segments, cls].values
axes[1].set_xticks(range(len(segments)))
axes[1].set_xticklabels([label_of[s] for s in segments], fontsize=7)
axes[1].set(ylabel="% of segment", title="First-line drug class")
axes[1].legend(fontsize=7, bbox_to_anchor=(1.01, 1), loc="upper left")
for ax in axes:
    ax.grid(axis="y", alpha=.3)
plt.tight_layout()
plt.savefig(OUT_DIR / "fig_segment_treatment.png", dpi=150)
plt.close()

# ----------------------------------------------------------------------------
# 7. Figure 3: healthcare use by segment (patients with a full year before and after)
# ----------------------------------------------------------------------------
fig, axes = plt.subplots(1, 2, figsize=(13, 4.5))
w = 0.38
x = np.arange(len(segments))
axes[0].bar(x - w / 2, p.loc[segments, "pre_outpatient_no_wellness_mean"], w, label="1 year before", color="#9DC3E6")
axes[0].bar(x + w / 2, p.loc[segments, "post_outpatient_no_wellness_mean"], w, label="1 year after", color="#1F4E79")
axes[0].set(title="Outpatient visits per patient (wellness visits excluded)", ylabel="Mean visits")
axes[0].legend(fontsize=8)
axes[1].bar(x - w / 2, p.loc[segments, "post_inpatient_mean"], w, label="Inpatient", color="#2E75B6")
axes[1].bar(x + w / 2, p.loc[segments, "post_er_mean"], w, label="Emergency", color="#F4B183")
axes[1].set(title="Inpatient and emergency visits in the year after", ylabel="Mean visits")
axes[1].legend(fontsize=8)
for ax in axes:
    ax.set_xticks(x)
    ax.set_xticklabels([label_of[s] for s in segments], fontsize=7)
    ax.grid(axis="y", alpha=.3)
plt.tight_layout()
plt.savefig(OUT_DIR / "fig_segment_visits.png", dpi=150)
plt.close()

# ----------------------------------------------------------------------------
# 8. Figure 4: 2-D map of the patients (PCA)
# ----------------------------------------------------------------------------
# PCA squeezes the features into 2 axes that keep as much variation as possible, so the
# segments can be drawn on a flat page.  It is a picture, not part of the clustering.
# The same features and scaling as script 12 are used (near-constant flags removed).
binary_cols = [c for c in FEATURE_COLUMNS if c not in NUMERIC_FEATURES]
prev = prof[binary_cols].mean()
used = [c for c in FEATURE_COLUMNS if c not in prev[(prev < MIN_FEATURE_PREVALENCE) | (prev > 1 - MIN_FEATURE_PREVALENCE)].index]
Z = MinMaxScaler().fit_transform(prof[used].astype(float))
pca = PCA(n_components=2, random_state=RANDOM_STATE)
coords = pca.fit_transform(Z)
prof["pc1"], prof["pc2"] = coords[:, 0], coords[:, 1]

rng = np.random.default_rng(RANDOM_STATE)
jitter = rng.normal(0, 0.02, size=coords.shape)       # many patients share identical values: jitter spreads them
fig, ax = plt.subplots(figsize=(8, 6))
for i, s in enumerate(segments):
    m = (prof["segment_id"] == s).values
    ax.scatter(coords[m, 0] + jitter[m, 0], coords[m, 1] + jitter[m, 1], s=18, alpha=.7,
               color=PALETTE[i % len(PALETTE)], label=f"{names[s]} (n={m.sum()})")
ax.set(xlabel=f"PC1 ({pca.explained_variance_ratio_[0]:.0%} of variation)",
       ylabel=f"PC2 ({pca.explained_variance_ratio_[1]:.0%} of variation)",
       title="Patients and segments in two dimensions (small random jitter added)")
ax.legend(fontsize=7, loc="best")
ax.grid(alpha=.3)
plt.tight_layout()
plt.savefig(OUT_DIR / "fig_segment_map.png", dpi=150)
plt.close()

# ----------------------------------------------------------------------------
# 9. Export for Power BI
# ----------------------------------------------------------------------------
# fact_patient_segments: every cohort patient; join to cdm_person / fact_cardio_cohort on person_id.
fact = df[["person_id", "segment_id", "segment_name", "n_conditions_window"]].merge(
    prof[["person_id", "pc1", "pc2"]], on="person_id", how="left")
fact.to_csv(OUT_DIR / "fact_patient_segments.csv", index=False)

# dim_segment: one row per segment (relate on segment_id).
dim = profile[["segment_id", "segment_name", "patients", "share_of_clustered", "age_at_index_mean",
               "pct_male", "n_conditions_mean", "pct_treated_1y", "pct_treated_ever",
               "median_days_to_tx_treated"]].copy()
dim = pd.concat([dim, pd.DataFrame([{"segment_id": 0, "segment_name": names[0],
                                     "patients": int((df["segment_id"] == 0).sum())}])], ignore_index=True)
dim.to_csv(OUT_DIR / "dim_segment.csv", index=False)

# fact_segment_condition: long format (segment x condition) for a heatmap matrix in Power BI.
group_of = {c: g for g, members in CONDITION_GROUPS.items() for c in members}
long_rows = [{"segment_id": s, "condition": CONDITION_LABELS[c], "major_group": group_of[c],
              "pct_of_segment": prof.loc[prof["segment_id"] == s, f"win_{c}"].mean(),
              "pct_overall": prof[f"win_{c}"].mean()} for s in segments for c in CONDITIONS]
pd.DataFrame(long_rows).to_csv(OUT_DIR / "fact_segment_condition.csv", index=False)

print(f"\nFigures, tables and Power BI files saved to {OUT_DIR}")
