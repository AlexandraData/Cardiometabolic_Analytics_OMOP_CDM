/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  08_study_cohort_analysis.sas
* Purpose: Define an incident Type 2 Diabetes Mellitus (T2DM) cohort, 
*          evaluate baseline demographics, assess 90-day post-index first-line 
*          treatment patterns, and analyze healthcare utilization.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* ========================================================================== */
/* Step 1: Identify Incident Type 2 Diabetes Patients (Index Event Definition) */
/* ========================================================================== */

proc sql;
    create table work.t2dm_index as
    select 
        c.person_id,
        min(c.condition_start_date) as index_date format=date9.
    from cdm.condition_occurrence c
    where c.condition_concept_id = 201826 
       or c.condition_source_value = '44054006' /* SNOMED for T2DM */
    group by c.person_id;
quit;

/* ========================================================================== */
/* Step 2: Extract Baseline Demographics & Clinical Characteristics           */
/* ========================================================================== */

proc sql;
    create table work.t2dm_baseline as
    select 
        idx.person_id,
        idx.index_date,
        /* Calculate age at diagnosis */
        (year(idx.index_date) - p.year_of_birth) - 
        (month(idx.index_date) < p.month_of_birth or 
        (month(idx.index_date) = p.month_of_birth and day(idx.index_date) < p.day_of_birth)) as age_at_index,
        case p.gender_concept_id
            when 8507 then 'Male'
            when 8532 then 'Female'
            else 'Unknown'
        end as gender,
        case p.race_concept_id
            when 8527 then 'White'
            when 8516 then 'Black / African American'
            when 8515 then 'Asian'
            else 'Other / Unknown'
        end as race
    from work.t2dm_index idx
    inner join cdm.person p
        on idx.person_id = p.person_id;
quit;

/* ========================================================================== */
/* Step 3: First-Line Medication Initiation (Within 90 Days Post-Index)       */
/* ========================================================================== */

proc sql;
    create table work.post_index_drugs as
    select 
        b.person_id,
        d.drug_exposure_start_date,
        d.drug_concept_id,
        d.drug_source_value,
        case 
            /* Metformin Concept IDs / RxNorm Codes */
            when d.drug_concept_id = 19078461 or d.drug_source_value = '860975' 
                then 'Metformin'
            /* Sulfonylureas / Other Oral Antidiabetics */
            when d.drug_source_value in ('310798', '19059798') 
                then 'Sulfonylurea / Thiazide'
            /* Insulin */
            when d.drug_source_value in ('274783', '847207') 
                then 'Insulin'
            else 'Other Regimen'
        end as drug_category
    from work.t2dm_baseline b
    inner join cdm.drug_exposure d
        on b.person_id = d.person_id
    where d.drug_exposure_start_date >= b.index_date
      and d.drug_exposure_start_date <= (b.index_date + 90);
quit;

/* Deduplicate to get the earliest drug exposure per patient post-index */
proc sort data=work.post_index_drugs out=work.first_line_sorted;
    by person_id drug_exposure_start_date;
run;

data work.first_line_rx;
    set work.first_line_sorted;
    by person_id drug_exposure_start_date;
    if first.person_id;
run;

/* Combine baseline and treatment pattern into a final analytical cohort */
proc sql;
    create table work.t2dm_analytical_cohort as
    select 
        b.*,
        coalesce(r.drug_category, 'No Treatment Initiated (<=90d)') as first_line_treatment,
        r.drug_exposure_start_date as treatment_start_date format=date9.,
        case 
            when r.drug_exposure_start_date is not null 
            then (r.drug_exposure_start_date - b.index_date)
            else .
        end as days_to_treatment
    from work.t2dm_baseline b
    left join work.first_line_rx r
        on b.person_id = r.person_id;
quit;

/* ========================================================================== */
/* Step 4: Healthcare Resource Utilization (Pre vs. Post Index Encounters)    */
/* ========================================================================== */

proc sql;
    create table work.hru_utilization as
    select 
        c.person_id,
        /* Inpatient Encounters (Concept ID 9201) */
        sum(case when v.visit_start_date between (c.index_date - 365) and (c.index_date - 1) 
                      and v.visit_concept_id = 9201 then 1 else 0 end) as pre_inpatient_visits,
        sum(case when v.visit_start_date between (c.index_date + 1) and (c.index_date + 365) 
                      and v.visit_concept_id = 9201 then 1 else 0 end) as post_inpatient_visits,
        /* Outpatient / Ambulatory Encounters (Concept ID 9202) */
        sum(case when v.visit_start_date between (c.index_date - 365) and (c.index_date - 1) 
                      and v.visit_concept_id = 9202 then 1 else 0 end) as pre_outpatient_visits,
        sum(case when v.visit_start_date between (c.index_date + 1) and (c.index_date + 365) 
                      and v.visit_concept_id = 9202 then 1 else 0 end) as post_outpatient_visits
    from work.t2dm_analytical_cohort c
    left join cdm.visit_occurrence v
        on c.person_id = v.person_id
    group by c.person_id;
quit;

/* ========================================================================== */
/* Step 5: Reporting & Portfolio Summary Outputs                              */
/* ========================================================================== */

title1 "Type 2 Diabetes Cohort: Baseline Demographics & Characteristics";
proc means data=work.t2dm_analytical_cohort n mean std median min max maxdec=1;
    var age_at_index;
run;

proc freq data=work.t2dm_analytical_cohort;
    tables gender race first_line_treatment / nocum;
run;

title1 "Healthcare Resource Utilization (Pre vs. Post 1-Year Index)";
proc means data=work.hru_utilization mean median min max maxdec=2;
    var pre_outpatient_visits post_outpatient_visits 
        pre_inpatient_visits post_inpatient_visits;
run;

/* Distribution plot of first-line drug choices */
title1 "First-Line Antidiabetic Treatment Initiation within 90 Days";
proc sgplot data=work.t2dm_analytical_cohort;
    vbar first_line_treatment / datalabel fillattrs=(color=CX2B579A);
    xaxis label="Treatment Category";
    yaxis label="Patient Count";
run;

title;