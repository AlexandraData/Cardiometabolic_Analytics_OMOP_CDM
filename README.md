# Cardiometabolic Analytics on OMOP CDM

Data analysis to identify patterns in patient demographics, pharmacotherapy adoption and healthcare resource utilization (HRU) in a cardiometabolic population, to support the optimization of clinical care pathways.

The project converts **Synthea synthetic patient records** (1,163 patients) into the **OMOP CDM v5.4** with **SAS**, defines a cardiometabolic cohort, analyses treatment initiation and healthcare use, and exports the results to a **Power BI** dashboard. All data is synthetic; no real patient information is used.

## Main results

| Measure | Result |
|---|---|
| Cohort | 613 of 1,163 patients (52.7%) with at least one of five index conditions: type 2 diabetes, prediabetes, hypertension, coronary artery disease, dyslipidemia |
| Started a core cardiometabolic drug within 365 days | 371 of 613 (60.5%): hypertension 100%, dyslipidemia 96.0%, coronary artery disease 93.9%, type 2 diabetes 51.3%, prediabetes 1.4% |
| Started a drug at any time after diagnosis | 452 of 613 (73.7%) |
| Type 2 diabetes study | 73 patients; 17 (23.3%) started an antidiabetic drug within 90 days (16 metformin, 1 insulin) |
| Diabetic complications | About half of patients with type 2 diabetes develop kidney disease or a complication (retinopathy, neuropathy) within 6 years of diagnosis (Kaplan-Meier) |
| Most frequent conditions (share of all patients) | Obesity 39.8%, prediabetes 29.3%, hypertension 25.1%, dyslipidemia 16.6%, type 2 diabetes 6.3% |

Conditions are grouped into three major groups: Cardiovascular Diseases, Metabolic Disorders and Related Cardiometabolic Conditions. Insulin resistance and NAFLD are not coded in the Synthea data.

## Pipeline

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

## Design decisions

- **Vocabulary, not hand-typed codes.** Every concept ID comes from the OMOP vocabulary (ATHENA): condition codes through SNOMED Maps-to, drug codes through RxNorm Maps-to, drug classes through the ATC ancestors.
- **Standard domains.** Employment, stress, education and similar findings belong to the Observation domain and are not loaded into `condition_occurrence`; they are counted with a reason in `vocab.conditions_not_loaded`.
- **Reproducible IDs.** Records are numbered in a fixed sort order, so the same input gives the same IDs on every run.
- **Initial treatment.** The first core cardiometabolic drug on or after the index date. Same-day ties are decided by class priority, then by the lowest code; the number of classes started on the first day is reported.
- **Treatment rate.** Reported as treated within 365 days (patients censored at death or end of data) and, separately, treated at any time.
- **Observation period.** Start = earliest record; end = death date, otherwise the latest date in the extract.
- **Wellness visits** (39% of visits) stay in the CDM as outpatient visits; healthcare use is also reported without them.

## Synthea data-quality findings

- Drug code 833036 is described as captopril but is acetaminophen/hydrocodone in RxNorm (remapped to the captopril RxNorm code).
- 26,008 of 38,094 condition rows are social findings or codes without a standard concept.
- 165 visits (154 patients) and 15 drug records are dated 1 to 14 days after the death date.
- No code for insulin resistance or NAFLD; type 2 diabetes appears at age 5 in one patient.

## Setup

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
4. Run the scripts in the order above.

## Not included

The Synthea data, the ATHENA vocabularies, the SAS result tables and the Power BI file are not stored in this repository.
