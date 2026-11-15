"""
12_choose_k_and_cluster.py  -  choose the number of segments and cluster the patients
=======================================================================================
Input : segmentation_output/patient_features.csv        (script 11)
Output: segmentation_output/k_selection_table.csv       quality numbers for every method and k
        segmentation_output/fig_choose_k.png            elbow, silhouette and stability plots
        segmentation_output/segment_assignments.csv     person_id -> segment (1 = largest)

What "clustering" does here
---------------------------
Each patient is a point described by up to 15 numbers (age and 14 comorbidity yes/no flags).
Clustering groups points that are close to each other.  Nobody tells the algorithm what
the groups are; we only choose HOW MANY (k) and HOW distance is measured.

Three methods are compared, so the choice is evidence-based:
  kmeans         - k centres; every patient joins the nearest centre (Euclidean distance).
  ward           - hierarchical: starts with one cluster per patient and repeatedly merges the
                   two clusters that increase the within-cluster variance the least.
  gower_average  - hierarchical on the GOWER distance, the standard distance for mixed data
                   (numeric + yes/no).  Average linkage = distance between two clusters is the
                   mean distance between their members.

How the number of segments (k) is chosen - four numbers, none sufficient alone:
  1. Elbow (k-means only): within-cluster variance always falls as k grows; the "bend" shows
     where extra segments stop paying off.
  2. Silhouette (-1 to 1): how much closer a patient is to their own segment than to the next
     nearest.  Above ~0.5 = clear structure, 0.25-0.5 = weak/moderate, below 0.25 = little.
     Careful: with mostly yes/no features the silhouette is inflated, because many patients
     are identical copies of each other.  Use it to compare k within one method, not to
     "prove" the segments are real.
  3. Stability (adjusted Rand index, ARI): resample the patients with replacement 100 times,
     re-cluster, and check whether the same patients end up together.  ARI = 1 means the
     segments are reproducible; below 0.8 they depend on which patients happened to be sampled.
  4. Smallest segment: segments below 5% of patients are too small to profile or act on.
The final k is also a judgement call: look at fig_choose_k.png and at the profiles in script 13,
and override K_FINAL in config.py if another k tells a clearer clinical story.
"""
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.cluster.hierarchy import linkage, fcluster
from scipy.spatial.distance import cdist, squareform
from sklearn.cluster import AgglomerativeClustering, KMeans
from sklearn.metrics import adjusted_rand_score, silhouette_score
from sklearn.preprocessing import MinMaxScaler, StandardScaler

from config import (OUT_DIR, FEATURE_COLUMNS, NUMERIC_FEATURES, K_RANGE, N_BOOTSTRAP,
                    RANDOM_STATE, MIN_SEGMENT_SHARE, MIN_STABILITY, MIN_FEATURE_PREVALENCE,
                    SCALING, FINAL_METHOD, K_FINAL)

K_MIN_CHOICE = 3     # k = 2 is a trivial split; the automatic choice starts at 3
METHODS = ["kmeans", "ward", "gower_average"]
SILHOUETTE_TOLERANCE = 0.90   # see the parsimony rule in section 5

# ----------------------------------------------------------------------------
# 1. Load and prepare the matrix
# ----------------------------------------------------------------------------
df = pd.read_csv(OUT_DIR / "patient_features.csv")
df = df[df["eligible_for_segmentation"] == 1].reset_index(drop=True)
print(f"Patients clustered: {len(df)}")

# 1a. Drop near-constant flags (e.g. stroke, heart failure: almost nobody has them in 5 years).
#     They still appear in the profile (script 13) but would only add noise here.
binary_cols = [c for c in FEATURE_COLUMNS if c not in NUMERIC_FEATURES]
prevalence = df[binary_cols].mean()
dropped = prevalence[(prevalence < MIN_FEATURE_PREVALENCE) | (prevalence > 1 - MIN_FEATURE_PREVALENCE)].index.tolist()
features = [c for c in FEATURE_COLUMNS if c not in dropped]
print(f"Features used ({len(features)}): {features}")
print(f"Dropped (<{MIN_FEATURE_PREVALENCE:.0%} prevalence): {dropped}")

X_raw = df[features].astype(float).to_numpy()

# 1b. Scaling.  Clustering uses distances, so a feature measured on a big scale (age 1-74)
#     would drown out a 0/1 flag.  Scaling puts them on a comparable footing.
#       minmax  : every column rescaled to 0-1 (flags unchanged, age 1-74 -> 0-1)
#       standard: z-scores (a rare flag such as CAD gets a large weight when present)
X_minmax = MinMaxScaler().fit_transform(X_raw)
X = X_minmax if SCALING == "minmax" else StandardScaler().fit_transform(X_raw)

# 1c. Gower distance = average over features of |difference| on 0-1 scaled values.
#     For a yes/no flag that is 0 if equal, 1 if different; for age it is the age gap divided
#     by the age range.  Hence it equals the mean absolute difference of the min-max matrix.
D_gower = cdist(X_minmax, X_minmax, metric="cityblock") / X_minmax.shape[1]


# ----------------------------------------------------------------------------
# 2. One function per method: returns a cluster label for every row it is given
# ----------------------------------------------------------------------------
def fit_labels(method, k, rows, n_init=20, seed=RANDOM_STATE):
    """Cluster the patients in `rows` (an array of row numbers; may contain repeats)."""
    if method == "kmeans":
        return KMeans(n_clusters=k, n_init=n_init, random_state=seed).fit_predict(X[rows])
    if method == "ward":
        return AgglomerativeClustering(n_clusters=k, linkage="ward").fit_predict(X[rows])
    if method == "gower_average":
        sub = D_gower[np.ix_(rows, rows)]
        tree = linkage(squareform(sub, checks=False), method="average")
        return fcluster(tree, t=k, criterion="maxclust") - 1
    raise ValueError(method)


def silhouette(method, labels):
    if len(set(labels)) < 2:
        return np.nan
    if method == "gower_average":
        return silhouette_score(D_gower, labels, metric="precomputed")
    return silhouette_score(X, labels)


def stability(method, k, ref_labels, n_boot=N_BOOTSTRAP):
    """Mean adjusted Rand index between the full-data clustering and clusterings of bootstrap samples."""
    rng = np.random.default_rng(RANDOM_STATE)
    n, aris = len(X), []
    for _ in range(n_boot):
        rows = rng.integers(0, n, n)                       # draw n patients WITH replacement
        uniq, first = np.unique(rows, return_index=True)   # the distinct patients drawn
        boot_labels = fit_labels(method, k, rows, n_init=5)[first]
        aris.append(adjusted_rand_score(ref_labels[uniq], boot_labels))
    return float(np.mean(aris))


# ----------------------------------------------------------------------------
# 3. Evaluate every method for every k
# ----------------------------------------------------------------------------
all_rows = np.arange(len(X))
results, label_store = [], {}
for method in METHODS:
    for k in K_RANGE:
        labels = fit_labels(method, k, all_rows)
        label_store[(method, k)] = labels
        sizes = np.bincount(labels)
        results.append({
            "method": method, "k": k,
            "silhouette": silhouette(method, labels),
            "stability_ari": stability(method, k, labels),
            "smallest_segment_share": sizes.min() / len(labels),
            "inertia": KMeans(k, n_init=20, random_state=RANDOM_STATE).fit(X).inertia_
                       if method == "kmeans" else np.nan,      # for the elbow plot
        })
    print(f"  {method}: done")
res = pd.DataFrame(results)
res.to_csv(OUT_DIR / "k_selection_table.csv", index=False)
print("\n", res.round(3).to_string(index=False))

# ----------------------------------------------------------------------------
# 4. Plots
# ----------------------------------------------------------------------------
fig, axes = plt.subplots(1, 3, figsize=(15, 4))
km = res[res["method"] == "kmeans"]
axes[0].plot(km["k"], km["inertia"], marker="o", color="#1F4E79")
axes[0].set(title="Elbow (k-means)", xlabel="Number of segments (k)", ylabel="Within-cluster variance")
for method, colour in zip(METHODS, ["#1F4E79", "#2E75B6", "#9DC3E6"]):
    m = res[res["method"] == method]
    axes[1].plot(m["k"], m["silhouette"], marker="o", label=method, color=colour)
    axes[2].plot(m["k"], m["stability_ari"], marker="o", label=method, color=colour)
axes[1].set(title="Silhouette (higher = clearer)", xlabel="k", ylabel="Silhouette")
axes[2].set(title="Stability (bootstrap ARI)", xlabel="k", ylabel="Adjusted Rand index")
axes[2].axhline(MIN_STABILITY, color="grey", linestyle="--", linewidth=1)
axes[1].legend(); axes[2].legend()
for ax in axes:
    ax.grid(alpha=.3)
plt.tight_layout()
plt.savefig(OUT_DIR / "fig_choose_k.png", dpi=150)
plt.close()

# ----------------------------------------------------------------------------
# 5. Choose k for the final method
# ----------------------------------------------------------------------------
cand = res[(res["method"] == FINAL_METHOD) & (res["k"] >= K_MIN_CHOICE)]
ok = cand[(cand["smallest_segment_share"] >= MIN_SEGMENT_SHARE) & (cand["stability_ari"] >= MIN_STABILITY)]
if K_FINAL is not None:
    k_final = int(K_FINAL)
    print(f"\nk set by hand in config.py: {k_final}")
elif len(ok):
    # Parsimony rule.  With yes/no features the silhouette keeps creeping up as k grows (more
    # segments = more identical patients grouped together), so "highest silhouette" would
    # always pick the largest k.  Instead: take the SMALLEST k whose silhouette is within
    # SILHOUETTE_TOLERANCE (90%) of the best acceptable one - extra segments must earn their place.
    best = ok["silhouette"].max()
    k_final = int(ok[ok["silhouette"] >= SILHOUETTE_TOLERANCE * best].sort_values("k").iloc[0]["k"])
    print(f"\nRule: k >= {K_MIN_CHOICE}, smallest segment >= {MIN_SEGMENT_SHARE:.0%}, "
          f"stability >= {MIN_STABILITY}; smallest k with silhouette >= "
          f"{SILHOUETTE_TOLERANCE:.0%} of the best ({best:.3f}) -> k = {k_final}")
else:
    k_final = int(cand.sort_values("stability_ari", ascending=False).iloc[0]["k"])
    print(f"\nNo k met all the criteria. Fallback: most stable k = {k_final}. Check the table above.")

# ----------------------------------------------------------------------------
# 6. Final assignment.  Segment 1 = the largest, 2 = the second largest, ...
# ----------------------------------------------------------------------------
raw_labels = label_store[(FINAL_METHOD, k_final)]
order = pd.Series(raw_labels).value_counts().index.tolist()          # biggest cluster first
relabel = {old: new + 1 for new, old in enumerate(order)}
segment = np.array([relabel[x] for x in raw_labels])

out = pd.DataFrame({"person_id": df["person_id"], "segment_id": segment,
                    "method": FINAL_METHOD, "k": k_final})
out.to_csv(OUT_DIR / "segment_assignments.csv", index=False)
print(f"\nMethod {FINAL_METHOD}, k = {k_final}. Segment sizes:")
print(out["segment_id"].value_counts().sort_index().to_string())

# Do the other methods find the same groups?  (ARI 1 = identical, ~0 = unrelated)
print(f"\nAgreement with the other methods at k = {k_final} (ARI):")
for other in METHODS:
    if other != FINAL_METHOD:
        print(f"  {FINAL_METHOD} vs {other}: "
              f"{adjusted_rand_score(raw_labels, label_store[(other, k_final)]):.2f}")
print(f"\nSaved to {OUT_DIR}")
