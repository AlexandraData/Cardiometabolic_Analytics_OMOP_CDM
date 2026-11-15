# Cardiometabolic Analytics on OMOP CDM

Data analysis to identify patterns in patient demographics, pharmacotherapy adoption and healthcare resource utilization (HRU) in a cardiometabolic population, to support the optimization of clinical care pathways, followed by a machine-learning segmentation of the patients.

The project has two parts:

1. **Cohort analysis (SAS).** Converts **Synthea synthetic patient records** (1,163 patients) into the **OMOP CDM v5.4**, defines a cardiometabolic cohort and analyses treatment initiation and healthcare use.
2. **Patient segmentation (Python).** Groups the cohort into clinical segments with **k-means clustering**, using age and comorbidities, and profiles how treatment and visits differ between segments.

The results of both parts are shown in a two-page **Power BI** dashboard (Overview, Cohort detail, Type 2 diabetes, Segments). All data is synthetic; no real patient information is used.

## Repository structure

```
Cardiometabolic_Analytics_OMOP_CDM/
├── 01_sas_etl_cohort/          Part 1: SAS scripts 00 to 10 (OMOP ETL, cohort, analysis, export)
├── 02_python_segmentation/     Part 2: Python scripts (features, clustering, profiling)
├── 03_images/                  Dashboard screenshots and figures
├── .gitignore
└── README.md
```

## Main results

### Part 1: cohort analysis

| Measure | Result |
|---|---|
| Cohort | 613 of 1,163 patients (52.7%) with at least one of five index conditions: type 2 diabetes, prediabetes, hypertension, coronary artery disease, dyslipidemia |
| Started a core cardiometabolic drug within 365 days | 371 of 613 (60.5%): hypertension 100%, dyslipidemia 96.0%, coronary artery disease 93.9%, type 2 diabetes 51.3%, prediabetes 1.4% |
| Started a drug at any time after diagnosis | 452 of 613 (73.7%) |
| Type 2 diabetes study | 73 patients; 17 (23.3%) started an antidiabetic drug within 90 days (16 metformin, 1 insulin) |
| Diabetic complications | About half of patients with type 2 diabetes develop kidney disease or a complication (retinopathy, neuropathy) within 6 years of diagnosis (Kaplan-Meier) |
| Most frequent conditions (share of all patients) | Obesity 39.8%, prediabetes 29.3%, hypertension 25.1%, dyslipidemia 16.6%, type 2 diabetes 6.3% |

Conditions are grouped into three major groups: Cardiovascular Diseases, Metabolic Disorders and Related Cardiometabolic Conditions. Insulin resistance and NAFLD are not coded in the Synthea data.

### Part 2: patient segments

Patients with at least 5 years of follow-up after the index diagnosis (529 of 613) were clustered with k-means (k = 4) on age at diagnosis and 8 comorbidity flags. The segmentation is stable (bootstrap ARI 0.89). 84 patients with shorter follow-up are not segmented.

| Segment | Patients | Mean age | Conditions per patient | Treated within 1 year | Treated at any time |
|---|---|---|---|---|---|
| S1 Early hypertension | 255 | 18 | 1.2 | 100% | 100% |
| S2 Prediabetes | 179 | 34 | 1.5 | 2% | 30% |
| S3 Dyslipidemia + obesity | 52 | 52 | 2.0 | 92% | 100% |
| S4 Multimorbid T2D | 43 | 33 | 4.9 | 40% | 93% |

Outpatient visits (wellness visits excluded) rise in the year after diagnosis in every segment, most in S1 (0.4 to 1.2 per patient) and S3 (0.2 to 1.1).

**Read these results with care.** The segments largely mirror the index condition, because Synthea assigns drugs by diagnosis, so differences in treatment between segments are mostly structural. A different method (Gower distance) gives different groups (ARI 0.34 against k-means). Inpatient and ER visits are too rare to compare, and age at diagnosis clusters at 18 in Synthea.

---

## Part 1: SAS pipeline (`01_sas_etl_cohort/`)

Run the scripts in this order. Scripts `02`, `02b` and `02c` only need to run once (or when the source files change).

| Script | What it does | Output |
|---|---|---|
| `00_setup_libraries` | Project path and the libraries raw, cdm, vocab, results | |
| `01_create_tables` | Creates the empty OMOP CDM tables | 8 CDM tables |
| `02_import_raw` | Imports the six Synthea CSV files | `raw.*` |
| `02b_load_vocabulary_snomed` | Loads SNOMED concepts and Maps-to links from ATHENA | `vocab.snomed_*` |
| `02c_load_vocabulary_rxnorm_atc` | Loads RxNorm and ATC concepts, ancestors and Maps-to links | `vocab.concept*` |
| `03_transform_person` | Person and death; gender, race and ethnicity mapped to standard concepts | `cdm.person`, `cdm.death` |
| `03b_transform_provider_care_site` | Organizations to care sites, providers | `cdm.care_site`, `cdm.provider` |
| `04_transform_visit` | Encounters to visits (inpatient, outpatient, emergency) | `cdm.visit_occurrence`, `vocab.visit_class` |
| `05_transform_condition` | SNOMED codes mapped to standard concepts; non-disease findings left out and counted | `cdm.condition_occurrence` |
| `06_transform_drug` | RxNorm codes mapped to standard concepts | `cdm.drug_exposure` |
| `06a_build_drug_class_map` | One ATC code per product (A10, B01, C01-C10), core classes and priorities | `vocab.drug_class_map` |
| `06b_transform_observation_period` | Observation period per person; person care site | `cdm.observation_period` |
| `06c_build_condition_groups` | 16 conditions in 3 major groups, flags per patient | `results.patient_condition_*` |
| `07_qc_checks` | Data quality checks (keys, duplicates, dates, unmapped rates) | PASS / FAIL / INFO report |
| `08_study_cohort_type_2_diabetes_analysis` | Incident type 2 diabetes cohort, first antidiabetic drug, healthcare use | `results.t2dm_*` |
| `09_advanced_cohort_visualizations` | Cohort, initial drug and class, time to treatment, healthcare use, figures | `results.analytic_full`, `hru_*` |
| `09a_cohort_attrition_flowchart` | Cohort attrition flowcharts | PNG images |
| `09b_type2_diabetes_complications_km` | Kaplan-Meier curves for kidney disease and diabetic complications | Figures 5 and 6 |
| `10_export_to_powerbi` | Exports CDM, analysis and lookup tables to CSV | Files for Power BI |

`filter_snomed.py` (optional helper) reduces the large ATHENA vocabulary files to the SNOMED concepts and Maps-to links used by `02b`.

### Design decisions

- **Vocabulary, not hand-typed codes.** Every concept ID comes from the OMOP vocabulary (ATHENA): condition codes through SNOMED Maps-to, drug codes through RxNorm Maps-to, drug classes through the ATC ancestors.
- **Standard domains.** Employment, stress, education and similar findings belong to the Observation domain and are not loaded into `condition_occurrence`; they are counted with a reason in `vocab.conditions_not_loaded`.
- **Reproducible IDs.** Records are numbered in a fixed sort order, so the same input gives the same IDs on every run.
- **Initial treatment.** The first core cardiometabolic drug on or after the index date. Same-day ties are decided by class priority, then by the lowest code; the number of classes started on the first day is reported.
- **Treatment rate.** Reported as treated within 365 days (patients censored at death or end of data) and, separately, treated at any time.
- **Observation period.** Start = earliest record; end = death date, otherwise the latest date in the extract.
- **Wellness visits** (39% of visits) stay in the CDM as outpatient visits; healthcare use is also reported without them.

### Synthea data-quality findings

- Drug code 833036 is described as captopril but is acetaminophen/hydrocodone in RxNorm (remapped to the captopril RxNorm code).
- 26,008 of 38,094 condition rows are social findings or codes without a standard concept.
- 165 visits (154 patients) and 15 drug records are dated 1 to 14 days after the death date.
- No code for insulin resistance or NAFLD; type 2 diabetes appears at age 5 in one patient.

---

## Part 2: Python segmentation (`02_python_segmentation/`)

The Python scripts read the CSV files exported by SAS script `10_export_to_powerbi` and write the results back as CSV files and figures. Every script is commented line by line to explain the feature engineering and the clustering.

| Script | What it does | Output |
|---|---|---|
| `config.py` | Paths and settings: 5-year window, random seed, range of k, features, condition groups | |
| `11_build_features.py` | Joins the cohort, condition flags, person and visit tables; builds one row per patient with the condition flags in the first 5 years, eligibility (at least 5 years of follow-up) and the outcomes (treatment, visits) | `patient_features.csv` |
| `12_choose_k_and_cluster.py` | Scales the features (min-max), compares k-means, Ward and Gower-distance clustering for k = 2 to 8 by silhouette, bootstrap stability (ARI) and smallest segment size, chooses k with a parsimony rule and assigns each patient to a segment | `k_selection_table.csv`, `fig_choose_k.png`, `segment_assignments.csv` |
| `13_profile_segments.py` | Names and profiles the segments (conditions, treatment, visits) with Wilson confidence intervals and chi-square / Kruskal-Wallis tests, and builds the PCA patient map | `segment_profile.csv`, `segment_tests.csv`, figures, and the Power BI tables `fact_patient_segments.csv`, `dim_segment.csv`, `fact_segment_condition.csv` |

### Method

- **Features used for clustering:** age at index diagnosis and 8 comorbidity flags (coronary artery disease, type 2 diabetes, obesity, hyperglycemia, prediabetes, metabolic syndrome, hypertension, dyslipidemia), counting conditions diagnosed in the first 5 years after the index date. Conditions that almost no patient has (prevalence under 2%) are dropped. Sex is not used, so the groups reflect disease and not gender.
- **Not used for clustering:** treatment and visits. They describe the segments afterwards, so differences between segments are findings and not circular.
- **Choosing k:** silhouette score alone keeps rising with k when most features are yes/no, so k is chosen with a parsimony rule (smallest k with at least 90% of the best silhouette), together with stability (bootstrap ARI of at least 0.80) and a minimum segment size of 5%.
- **Robustness:** k-means is compared with Ward hierarchical clustering (ARI 0.84) and with Gower-distance clustering (ARI 0.34).
- **PCA** is used only to draw the patient map, not for clustering.

### How to run

```bash
cd 02_python_segmentation
pip install -r requirements.txt
# 1. set DATA_DIR (the CSV files exported from SAS) and OUT_DIR in config.py
python 11_build_features.py
python 12_choose_k_and_cluster.py
python 13_profile_segments.py
```

Requirements: Python 3.10 or later; pandas, numpy, scikit-learn, scipy, matplotlib.

---

## Power BI dashboard

The dashboard has four pages with the same filter bar (segment, primary indication, gender, race, age group):

| Page | Content |
|---|---|
| Overview | Population KPIs, prevalence of 16 conditions, patients by age and gender, cumulative treatment initiation, initial drug classes |
| Segments | Patients per segment, treatment within 1 year with confidence intervals, condition profile, first-line drug class, outpatient visits, patient map, profile table |

The Power BI file itself is not stored in this repository. Screenshots are in `03_images/`.

## Setup (SAS part)

1. Create the folder structure on your SAS environment (the scripts use `/home/u63767888/omop_project`; change `project_path` in every script header or in `00_setup_libraries`):

   ```
   omop_project/
     raw/        Synthea CSV files (patients, encounters, conditions, medications, providers, organizations)
     vocab/      ATHENA vocabulary files (CONCEPT, CONCEPT_ANCESTOR, CONCEPT_RELATIONSHIP)
     vocab/snomed/   filtered SNOMED files (output of filter_snomed.py)
     scripts/    the .sas files
     results/    created for the analysis tables
     export/     CSV files for Power BI
   ```
2. Generate the Synthea data at https://synthetichealth.github.io/synthea/ or use your own export (CSV format).
3. Download the vocabularies from [ATHENA](https://athena.ohdsi.org) (SNOMED, RxNorm, ATC). They are subject to their own licences and are not included in this repository.
4. Run the scripts in the order above, then export with `10_export_to_powerbi` and continue with the Python part.

## Not included

The Synthea data, the ATHENA vocabularies, the SAS result tables, the exported CSV files, the segmentation outputs and the Power BI file are not stored in this repository.
