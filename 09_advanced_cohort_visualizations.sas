/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  09_advanced_cohort_visualizations.sas   (version 3)
* Purpose: Cardiometabolic cohort: index date and indication, initial treatment
*          (drug and drug class), time to treatment, healthcare use before and
*          after diagnosis, and the figures for the portfolio.
* Needs:   03 ... 06b, 06a (vocab.drug_class_map) and 04's vocab.visit_class;
*          the folder omop_project/results.
* Output:  results.cohort_attrition, results.analytic_full, results.hru_raw,
*          results.hru_long  (permanent: script 10 exports these to Power BI)
*
* Version 3: dyslipidemia (hyperlipidemia 55822004, hypertriglyceridemia
*   302870006) is the fifth index condition. It adds 40 patients who had none of
*   the other four, and gives some patients an earlier index date and a different
*   primary_indication, so all cohort numbers change: re-run 09, 09a and 10.
*
* Why version 2:
*   - Steps 1 and 1b were the same code twice: one remains.
*   - The initial drug came from a hand-typed CASE (five codes, several wrong,
*     everything else 'Other Regimen'). It now comes from vocab.drug_class_map:
*     the first CORE cardiometabolic drug on or after the index date. Same-day
*     ties: lowest class_priority, then lowest source code. n_initial_classes
*     counts how many classes started on that first day.
*   - Output has BOTH the indication (primary_indication) and the drug class
*     (initial_drug_class), plus ingredient and ATC code.
*   - Observation period: follow-up for the time-to-treatment analysis ends at
*     365 days, death or the end of the extract, whichever comes first
*     (patients are censored, not counted as untreated).
*   - Healthcare use only for patients with a full year before and after the
*     index date, with and without wellness visits.
*   - Gender and race come from the standard concepts, not source text, and age
*     is exact (month and day of birth).
*   - Removed: the drug-code listings and the hand-typed drug_class_map (06a
*     does this properly).
*
* Key column definitions for Power BI:
*   treated_ever = first core drug on or after the index date (any time)
*   tx_event     = 1 if that drug started within 365 days of the index date and
*                  within the observation period (use for the 1-year rate)
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";
libname results "&project_path/results";

ods graphics on / reset=all width=900px height=550px;

%let cohort_codes = '44054006','15777000','38341003','59621000','53741008','55822004','302870006';

/* ========================================================================== */
/* Step 1: Index date = first cardiometabolic diagnosis                        */
/* Same-day ties between indications: T2D, CAD, hypertension, prediabetes, dyslipidemia */
/* ========================================================================== */

proc sql;
    create table work.cardio_events as
    select c.person_id,
           c.condition_start_date,
           case strip(c.condition_source_value)
               when '44054006' then 'Type 2 Diabetes'
               when '53741008' then 'Coronary Artery Disease'
               when '38341003' then 'Hypertension'
               when '59621000' then 'Hypertension'
               when '15777000' then 'Prediabetes'
               when '55822004' then 'Dyslipidemia'
               when '302870006' then 'Dyslipidemia'
           end as indication length=30,
           case strip(c.condition_source_value)
               when '44054006' then 1
               when '53741008' then 2
               when '38341003' then 3
               when '59621000' then 3
               when '15777000' then 4
               when '55822004' then 5
               when '302870006' then 5
           end as indication_rank
    from cdm.condition_occurrence c
    where strip(c.condition_source_value) in (&cohort_codes);
quit;

proc sort data=work.cardio_events;
    by person_id condition_start_date indication_rank;
run;

data work.cardio_index;
    set work.cardio_events;
    by person_id;
    if first.person_id;
    rename condition_start_date = index_date
           indication = primary_indication;
    keep person_id condition_start_date indication;
run;

/* ========================================================================== */
/* Step 2: Demographics and observation period                                 */
/* ========================================================================== */

proc sql;
    create table work.cohort_demographics as
    select ci.person_id,
           ci.index_date format=date9.,
           ci.primary_indication,
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
           end as race length=40,
           (year(ci.index_date) - p.year_of_birth) -
           (month(ci.index_date) < p.month_of_birth or
           (month(ci.index_date) = p.month_of_birth and day(ci.index_date) < p.day_of_birth))
               as age_at_index,
           o.observation_period_start_date as obs_start format=date9.,
           o.observation_period_end_date   as obs_end   format=date9.,
           (ci.index_date - o.observation_period_start_date >= 365) as prior_obs_365,
           (o.observation_period_end_date - ci.index_date >= 365)   as followup_365
    from work.cardio_index ci
    inner join cdm.person p
        on ci.person_id = p.person_id
    inner join cdm.observation_period o
        on ci.person_id = o.person_id;

    create table results.cohort_attrition as
    select 1 as step,
           'Patients with a cardiometabolic index diagnosis' as description length=80,
           count(*) as patients
    from work.cohort_demographics
    union all
    select 2, 'With 365+ days of observation before index', sum(prior_obs_365 = 1)
    from work.cohort_demographics
    union all
    select 3, 'With 365+ days of follow-up after index', sum(followup_365 = 1)
    from work.cohort_demographics
    union all
    select 4, 'With both (healthcare use analysis)', sum(prior_obs_365 = 1 and followup_365 = 1)
    from work.cohort_demographics;
quit;

/* ========================================================================== */
/* Step 3: Initial treatment = first CORE drug on or after the index date      */
/* ========================================================================== */

proc sql;
    create table work.rx_after_index as
    select b.person_id,
           d.drug_exposure_start_date as rx_date format=date9.,
           d.drug_source_value        as source_code,
           m.ingredient,
           m.drug_class,
           m.atc_code,
           m.class_priority
    from work.cohort_demographics b
    inner join cdm.drug_exposure d
        on b.person_id = d.person_id
    inner join vocab.drug_class_map m
        on d.drug_source_value = m.source_code
    where m.core_flag = 1
      and d.drug_exposure_start_date >= b.index_date;

    /* patients already on a core drug before the index date (reported, not removed) */
    create table work.prior_rx as
    select distinct b.person_id, 1 as prior_core_rx
    from work.cohort_demographics b
    inner join cdm.drug_exposure d
        on b.person_id = d.person_id
    inner join vocab.drug_class_map m
        on d.drug_source_value = m.source_code
    where m.core_flag = 1
      and d.drug_exposure_start_date < b.index_date;
quit;

proc sort data=work.rx_after_index out=work.rx_sorted;
    by person_id rx_date class_priority source_code;
run;

data work.earliest_rx;
    set work.rx_sorted;
    by person_id;
    if first.person_id;
run;

/* number of different drug classes started on the first day */
proc sql;
    create table work.first_day_classes as
    select e.person_id,
           count(distinct r.drug_class) as n_initial_classes
    from work.earliest_rx e
    inner join work.rx_after_index r
        on e.person_id = r.person_id
       and e.rx_date   = r.rx_date
    group by e.person_id;

    create table work.analytic_stage as
    select b.*,
           coalesce(pr.prior_core_rx, 0) as prior_core_rx,
           e.rx_date        as first_rx_date format=date9.,
           e.ingredient     as rx_ingredient length=80,
           e.drug_class     as rx_class      length=40,
           e.atc_code       as rx_atc        length=8,
           e.source_code    as rx_source_code length=20,
           f.n_initial_classes
    from work.cohort_demographics b
    left join work.prior_rx pr         on b.person_id = pr.person_id
    left join work.earliest_rx e       on b.person_id = e.person_id
    left join work.first_day_classes f on b.person_id = f.person_id;
quit;

data results.analytic_full;
    length initial_drug $80 initial_drug_class $40 initial_atc $8
           initial_source_code $20;
    set work.analytic_stage;

    if first_rx_date = . then do;
        initial_drug = 'No Treatment';
        initial_drug_class = 'No Treatment';
        initial_atc = '';
        initial_source_code = '';
        treated_ever = 0;
    end;
    else do;
        initial_drug = propcase(strip(rx_ingredient));
        initial_drug_class = rx_class;
        initial_atc = rx_atc;
        initial_source_code = rx_source_code;
        treated_ever = 1;
    end;

    /* Time to treatment: event = first core drug within 365 days; patients without
       an event are censored at 365 days, death or the end of the extract. */
    follow_days = max(0, min(365, obs_end - index_date));
    if first_rx_date ne . and (first_rx_date - index_date) <= follow_days then do;
        time_to_tx = first_rx_date - index_date;
        tx_event = 1;
    end;
    else do;
        time_to_tx = follow_days;
        tx_event = 0;
    end;

    drop rx_ingredient rx_class rx_atc rx_source_code;
run;

/* ========================================================================== */
/* Step 4: Healthcare use, 365 days before vs after the index date             */
/* Only patients with a full year on both sides; index day excluded.           */
/* ========================================================================== */

proc sql;
    create table results.hru_raw as
    select c.person_id,
           c.primary_indication,
           sum(v.visit_start_date between c.index_date - 365 and c.index_date - 1
               and v.visit_concept_id = 9202) as pre_outpatient,
           sum(v.visit_start_date between c.index_date + 1 and c.index_date + 365
               and v.visit_concept_id = 9202) as post_outpatient,
           sum(v.visit_start_date between c.index_date - 365 and c.index_date - 1
               and v.visit_concept_id = 9201) as pre_inpatient,
           sum(v.visit_start_date between c.index_date + 1 and c.index_date + 365
               and v.visit_concept_id = 9201) as post_inpatient,
           sum(v.visit_start_date between c.index_date - 365 and c.index_date - 1
               and v.visit_concept_id = 9202 and vc.encounter_class ne 'wellness')
               as pre_outpatient_no_wellness,
           sum(v.visit_start_date between c.index_date + 1 and c.index_date + 365
               and v.visit_concept_id = 9202 and vc.encounter_class ne 'wellness')
               as post_outpatient_no_wellness
    from results.analytic_full c
    left join cdm.visit_occurrence v
        on c.person_id = v.person_id
    left join vocab.visit_class vc
        on v.visit_occurrence_id = vc.visit_occurrence_id
    where c.prior_obs_365 = 1 and c.followup_365 = 1
    group by c.person_id, c.primary_indication;
quit;

data results.hru_long;
    length period $16 visit_type $30;
    set results.hru_raw;
    period = '1 Yr Pre-Index';  visit_count = pre_outpatient;            visit_type = 'Outpatient';                output;
    period = '1 Yr Post-Index'; visit_count = post_outpatient;           visit_type = 'Outpatient';                output;
    period = '1 Yr Pre-Index';  visit_count = pre_outpatient_no_wellness;  visit_type = 'Outpatient excl. wellness'; output;
    period = '1 Yr Post-Index'; visit_count = post_outpatient_no_wellness; visit_type = 'Outpatient excl. wellness'; output;
    period = '1 Yr Pre-Index';  visit_count = pre_inpatient;             visit_type = 'Inpatient';                 output;
    period = '1 Yr Post-Index'; visit_count = post_inpatient;            visit_type = 'Inpatient';                 output;
    keep person_id primary_indication period visit_count visit_type;
run;

/* ========================================================================== */
/* Checks                                                                      */
/* ========================================================================== */

title "Check 1: cohort attrition";
proc print data=results.cohort_attrition noobs; run;

title "Check 2: one row per patient, and the treatment split (indication x drug class)";
proc sql;
    select count(*) as rows_in_analytic_full,
           count(distinct person_id) as distinct_patients
    from results.analytic_full;
quit;

proc freq data=results.analytic_full;
    tables primary_indication * initial_drug_class / norow nocol nopercent;
run;

title "Check 3: treated ever vs treated within 365 days, by indication";
proc sql;
    select primary_indication,
           count(*) as patients,
           sum(treated_ever) as treated_ever,
           calculated treated_ever / calculated patients as pct_treated_ever format=percent8.1,
           sum(tx_event) as treated_within_365,
           calculated treated_within_365 / calculated patients as pct_within_365 format=percent8.1,
           sum(prior_core_rx) as on_core_drug_before_index,
           sum(n_initial_classes > 1) as several_classes_first_day
    from results.analytic_full
    group by primary_indication;
quit;

/* ========================================================================== */
/* Figure 2: Age at diagnosis by indication                                    */
/* ========================================================================== */

title1 bold "Figure 2: Age at Diagnosis Across Cardiometabolic Indications";
title2 h=10pt "Interquartile ranges and outliers for cohort age at index event";
proc sgplot data=results.analytic_full;
    vbox age_at_index / category=primary_indication
                        group=gender
                        fillattrs=(transparency=0.2)
                        boxwidth=0.6;
    xaxis label="Primary Cardiometabolic Indication" labelattrs=(weight=bold);
    yaxis label="Age at Index (Years)" grid values=(0 to 100 by 10) labelattrs=(weight=bold);
    keylegend / title="Sex" position=topright location=inside across=1;
run;

/* ========================================================================== */
/* Figure 3: Time to first treatment (cumulative treatment initiation)         */
/* ========================================================================== */

title1 bold "Figure 3: Time to Initial Pharmacotherapy (Kaplan-Meier)";
title2 h=10pt "Cumulative treatment initiation over 365 days after the index date; patients censored at death or end of data";
proc lifetest data=results.analytic_full plots=survival(failure atrisk cb=hw test) notable;
    time time_to_tx * tx_event(0);   /* 0 = censored */
    strata primary_indication;
run;

/* ========================================================================== */
/* Figure 4: Healthcare use before vs after diagnosis                          */
/* ========================================================================== */

title1 bold "Figure 4: Healthcare Resource Utilization 1-Year Pre vs. Post Diagnosis";
title2 h=10pt "Annual outpatient encounters, patients with a full year before and after the index event";
proc sgplot data=results.hru_long;
    where visit_type = 'Outpatient';
    vbox visit_count / category=period
                       group=primary_indication
                       fillattrs=(transparency=0.3)
                       boxwidth=0.6;
    xaxis label="Study Observation Window" labelattrs=(weight=bold);
    yaxis label="Annual Outpatient Encounters" grid labelattrs=(weight=bold);
    keylegend / title="Indication" position=topright;
run;

title "Sensitivity: outpatient visits per patient with and without wellness visits";
proc means data=results.hru_long n mean median maxdec=2;
    class visit_type period;
    var visit_count;
run;

title;
