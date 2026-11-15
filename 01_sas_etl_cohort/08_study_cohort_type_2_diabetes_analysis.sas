/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  08_study_cohort_type_2_diabetes_analysis.sas   (version 2)
* Purpose: Incident type 2 diabetes (T2DM) cohort: baseline characteristics,
*          first antidiabetic treatment within 90 days, and healthcare use
*          in the year before and after diagnosis.
* Needs:   03 ... 06b and 04's vocab.visit_class run first.
*          Create the folder  omop_project/results  once (it receives the tables).
* Output:  results.t2dm_attrition, results.t2dm_cohort, results.t2dm_hru
*
* Why version 2:
*   - "Incident" was not checked: now needs 365 days of observation before the
*     index date and no antidiabetic drug before it (new users only).
*   - First-line treatment took ANY first drug (paracetamol, antibiotics...) and
*     labelled it 'Other Regimen'. Now only antidiabetic drugs (ATC A10) count,
*     taken from vocab.drug_class_map, not hand-typed codes.
*   - The hand-typed codes were wrong: 310798 is hydrochlorothiazide (a diuretic,
*     not a sulfonylurea) and 19059798, 274783 and 847207 are not in the data.
*     Insulin in this data is code 106892.
*   - Same-day ties are resolved the same way as in script 09 (class_priority,
*     then lowest source code).
*   - Outpatient visits include wellness checks (39% of visits), so a
*     sensitivity count without wellness visits is added.
*   - Results are saved in a permanent library, not WORK.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";
libname results "&project_path/results";   /* also add this line to 00_setup_libraries.sas */

/* ========================================================================== */
/* Step 1: Index date = first T2DM diagnosis (OMOP concept 201826)             */
/* Synthea code 44054006 is loaded with this concept by script 05.             */
/* ========================================================================== */

proc sql;
    create table work.t2dm_index as
    select person_id,
           min(condition_start_date) as index_date format=date9.
    from cdm.condition_occurrence
    where condition_concept_id = 201826
    group by person_id;
quit;

/* ========================================================================== */
/* Step 2: Eligibility flags and attrition                                     */
/* ========================================================================== */

proc sql;
    create table work.t2dm_flags as
    select i.person_id,
           i.index_date,
           o.observation_period_start_date as obs_start format=date9.,
           o.observation_period_end_date   as obs_end   format=date9.,
           (i.index_date - o.observation_period_start_date >= 365) as prior_obs_365,
           (o.observation_period_end_date - i.index_date >= 365)   as followup_365,
           (select count(*)
            from cdm.drug_exposure d
            inner join vocab.drug_class_map m
                on d.drug_source_value = m.source_code
            where d.person_id = i.person_id
              and m.atc_code like 'A10%'
              and d.drug_exposure_start_date < i.index_date) as prior_antidiabetic_rx
    from work.t2dm_index i
    inner join cdm.observation_period o
        on i.person_id = o.person_id;

    create table results.t2dm_attrition as
    select 1 as step,
           'Patients with a T2DM diagnosis' as description length=80,
           count(*) as patients
    from work.t2dm_flags
    union all
    select 2, 'With 365+ days of observation before index', sum(prior_obs_365 = 1)
    from work.t2dm_flags
    union all
    select 3, 'And no antidiabetic drug before index (incident cohort)',
           sum(prior_obs_365 = 1 and prior_antidiabetic_rx = 0)
    from work.t2dm_flags
    union all
    select 4, 'And 365+ days of follow-up (healthcare use analysis only)',
           sum(prior_obs_365 = 1 and prior_antidiabetic_rx = 0 and followup_365 = 1)
    from work.t2dm_flags;
quit;

/* ========================================================================== */
/* Step 3: Baseline characteristics of the incident cohort                     */
/* ========================================================================== */

proc sql;
    create table work.t2dm_baseline as
    select f.person_id,
           f.index_date,
           f.followup_365,
           (year(f.index_date) - p.year_of_birth) -
           (month(f.index_date) < p.month_of_birth or
           (month(f.index_date) = p.month_of_birth and day(f.index_date) < p.day_of_birth))
               as age_at_index,
           case p.gender_concept_id
               when 8507 then 'Male'
               when 8532 then 'Female'
               else 'Unknown'
           end as gender length=10,
           case p.race_concept_id
               when 8527 then 'White'
               when 8516 then 'Black / African American'
               when 8515 then 'Asian'
               when 8657 then 'American Indian / Alaska Native'
               when 8557 then 'Native Hawaiian / Pacific Islander'
               else 'Other / Unknown'
           end as race length=40
    from work.t2dm_flags f
    inner join cdm.person p
        on f.person_id = p.person_id
    where f.prior_obs_365 = 1 and f.prior_antidiabetic_rx = 0;
quit;

/* ========================================================================== */
/* Step 4: First antidiabetic drug within 90 days after the index date         */
/* Only ATC A10 drugs. Same-day ties: lowest class_priority, then lowest code. */
/* ========================================================================== */

proc sql;
    create table work.post_index_drugs as
    select b.person_id,
           d.drug_exposure_start_date,
           d.drug_source_value,
           m.atc_code,
           m.ingredient,
           m.class_priority,
           case when m.atc_code = 'A10BA02'      then 'Metformin'
                when m.atc_code like 'A10A%'     then 'Insulin'
                else 'Other antidiabetic'
           end as drug_category length=20
    from work.t2dm_baseline b
    inner join cdm.drug_exposure d
        on b.person_id = d.person_id
    inner join vocab.drug_class_map m
        on d.drug_source_value = m.source_code
    where m.atc_code like 'A10%'
      and d.drug_exposure_start_date >= b.index_date
      and d.drug_exposure_start_date <= b.index_date + 90;
quit;

proc sort data=work.post_index_drugs out=work.first_line_sorted;
    by person_id drug_exposure_start_date class_priority drug_source_value;
run;

data work.first_line_rx;
    set work.first_line_sorted;
    by person_id;
    if first.person_id;
run;

/* How many patients started two different antidiabetic ATC codes on day 1 */
proc sql;
    create table work.first_day_ties as
    select r.person_id,
           count(distinct p.atc_code) as n_first_day_atc
    from work.first_line_rx r
    inner join work.post_index_drugs p
        on r.person_id = p.person_id
       and r.drug_exposure_start_date = p.drug_exposure_start_date
    group by r.person_id;

    create table results.t2dm_cohort as
    select b.person_id, b.index_date, b.age_at_index, b.gender, b.race,
           b.followup_365,
           coalesce(r.drug_category, 'No antidiabetic drug within 90 days')
               as first_line_treatment length=40,
           r.ingredient               as first_line_ingredient length=60,
           r.atc_code                 as first_line_atc,
           r.drug_exposure_start_date as treatment_start_date format=date9.,
           case when r.drug_exposure_start_date is not null
                then r.drug_exposure_start_date - b.index_date
                else . end            as days_to_treatment,
           t.n_first_day_atc
    from work.t2dm_baseline b
    left join work.first_line_rx r
        on b.person_id = r.person_id
    left join work.first_day_ties t
        on b.person_id = t.person_id;
quit;

/* ========================================================================== */
/* Step 5: Healthcare use, 365 days before vs after the index date             */
/* Only patients with 365+ days of follow-up. Index day itself is excluded.    */
/* Outpatient counts are shown with and without wellness visits.               */
/* ========================================================================== */

proc sql;
    create table results.t2dm_hru as
    select c.person_id,
           sum(v.visit_start_date between c.index_date - 365 and c.index_date - 1
               and v.visit_concept_id = 9201) as pre_inpatient,
           sum(v.visit_start_date between c.index_date + 1 and c.index_date + 365
               and v.visit_concept_id = 9201) as post_inpatient,
           sum(v.visit_start_date between c.index_date - 365 and c.index_date - 1
               and v.visit_concept_id = 9202) as pre_outpatient_all,
           sum(v.visit_start_date between c.index_date + 1 and c.index_date + 365
               and v.visit_concept_id = 9202) as post_outpatient_all,
           sum(v.visit_start_date between c.index_date - 365 and c.index_date - 1
               and v.visit_concept_id = 9202 and vc.encounter_class ne 'wellness')
               as pre_outpatient_no_wellness,
           sum(v.visit_start_date between c.index_date + 1 and c.index_date + 365
               and v.visit_concept_id = 9202 and vc.encounter_class ne 'wellness')
               as post_outpatient_no_wellness
    from results.t2dm_cohort c
    left join cdm.visit_occurrence v
        on c.person_id = v.person_id
    left join vocab.visit_class vc
        on v.visit_occurrence_id = vc.visit_occurrence_id
    where c.followup_365 = 1
    group by c.person_id;
quit;

/* ========================================================================== */
/* Step 6: Reporting                                                           */
/* ========================================================================== */

title1 "Cohort attrition";
proc print data=results.t2dm_attrition noobs;
run;

title1 "Type 2 diabetes cohort: baseline characteristics";
proc means data=results.t2dm_cohort n mean std median min max maxdec=1;
    var age_at_index;
run;

proc freq data=results.t2dm_cohort;
    tables gender race first_line_treatment / nocum;
run;

title1 "Days from diagnosis to first antidiabetic drug (treated patients)";
proc means data=results.t2dm_cohort n mean median min max maxdec=1;
    var days_to_treatment;
run;

title1 "Patients who started two different antidiabetic classes on the first day";
proc freq data=results.t2dm_cohort;
    tables n_first_day_atc / nocum missing;
run;

title1 "Healthcare use, 1 year before vs 1 year after diagnosis (patients with 1 year of follow-up)";
proc means data=results.t2dm_hru n mean median min max maxdec=2;
    var pre_outpatient_all post_outpatient_all
        pre_outpatient_no_wellness post_outpatient_no_wellness
        pre_inpatient post_inpatient;
run;

title1 "First antidiabetic treatment within 90 days of diagnosis";
proc sgplot data=results.t2dm_cohort;
    vbar first_line_treatment / datalabel fillattrs=(color=CX2B579A);
    xaxis label="Treatment category";
    yaxis label="Patients";
run;

title;
