/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  09_advanced_cohort_visualizations.sas
* Purpose: Comprehensive visual reporting suite for the Cardiometabolic & T2DM 
*          cohort. Generates treatment bar charts, demographic boxplots,
*          Kaplan-Meier time-to-treatment curves, and paired pre/post HRU comparisons.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* Reset graphics and enable standard HTML output rendering */
ods graphics on / reset=all width=900px height=550px;

/* ========================================================================== */
/* Step 1: Broad Cardiometabolic Index Cohort (With String Normalization)     */
/* ========================================================================== */

proc sql;
    create table work.cardio_events as
    select 
        c.person_id,
        c.condition_start_date,
        strip(c.condition_source_value) as clean_code,
        case 
            when calculated clean_code = '44054006' then 'Type 2 Diabetes'
            when calculated clean_code = '15777000' then 'Prediabetes'
            when calculated clean_code in ('38341003', '59621000') then 'Hypertension'
            when calculated clean_code = '53741008' then 'Coronary Artery Disease'
            else 'Other Metabolic'
        end as indication
    from cdm.condition_occurrence c
    where strip(c.condition_source_value) in (
        '44054006', /* Type 2 diabetes */
        '15777000', /* Prediabetes */
        '38341003', /* Essential hypertension */
        '59621000', /* Essential hypertension */
        '53741008'  /* Coronary arteriosclerosis */
    );
quit;

proc sort data=work.cardio_events;
    by person_id condition_start_date;
run;

data work.cardio_index;
    set work.cardio_events;
    by person_id condition_start_date;
    if first.person_id;
    rename condition_start_date = index_date
           indication = primary_indication;
    drop clean_code;
    format condition_start_date date9.;
run;

/* ========================================================================== */
/* Step 1b: Deduplicate Index Event and Join Demographics                      */
/* ========================================================================== */

proc sort data=work.cardio_events;
    by person_id condition_start_date;
run;

data work.cardio_index;
    set work.cardio_events;
    by person_id condition_start_date;
    if first.person_id;
    rename condition_start_date = index_date
           indication = primary_indication;
    drop clean_code;
    format condition_start_date date9.;
run;

/* Build WORK.COHORT_DEMOGRAPHICS directly from CDM.PERSON (Pure Numeric Keys) */
proc sql;
    create table work.cohort_demographics as
    select
        ci.person_id,
        ci.index_date,
        ci.primary_indication,
        p.gender_source_value as gender,
        p.race_source_value as race,
        year(ci.index_date) - p.year_of_birth as age_at_index
    from work.cardio_index ci
    inner join cdm.person p
        on ci.person_id = p.person_id;
quit;

/* ========================================================================== */
/* Step 2: Extract Initial Medication Regimen & Assemble ANALYTIC_FULL        */
/* ========================================================================== */

proc sql;
    create table work.earliest_rx as
    select
        b.person_id,
        min(d.drug_exposure_start_date) as first_rx_date format=date9.,
        case
            when d.drug_concept_id = 19078461 or strip(d.drug_source_value) = '860975' then 'Metformin'
            when d.drug_concept_id = 1308216  or strip(d.drug_source_value) = '310965' then 'ACE Inhibitor (Lisinopril)'
            when d.drug_concept_id = 19001409 or strip(d.drug_source_value) = '197361' then 'CCB (Amlodipine)'
            when d.drug_concept_id = 19059798 or strip(d.drug_source_value) = '310798' then 'Thiazide'
            when d.drug_concept_id = 1545958  or strip(d.drug_source_value) = '617314' then 'Statin (Atorvastatin)'
            else 'Other Regimen'
        end as initial_drug
    from work.cohort_demographics b
    inner join cdm.drug_exposure d
        on b.person_id = d.person_id
    where d.drug_exposure_start_date >= b.index_date
    group by b.person_id, calculated initial_drug;
quit;

proc sort data=work.cohort_demographics;
    by person_id;
run;

proc sort data=work.earliest_rx;
    by person_id first_rx_date;
run;

data work.analytic_full;
    merge work.cohort_demographics(in=a) work.earliest_rx(in=b);
    by person_id;
    if a;
    if first.person_id;

    if initial_drug = '' then initial_drug = 'No Treatment';

    /* Survival parameters: Event = Treatment initiation within 365 days */
    if first_rx_date ne . and (first_rx_date - index_date) <= 365 then do;
        time_to_tx = first_rx_date - index_date;
        tx_event = 1;
    end;
    else do;
        time_to_tx = 365;
        tx_event = 0;
    end;
run;

/* ========================================================================== */
/* Step 3: Healthcare Resource Utilization (Pre vs. Post Index Encounters)    */
/* ========================================================================== */

proc sql;
    create table work.hru_raw as
    select
        c.person_id,
        c.primary_indication,
        /* Outpatient pre vs post 1-year */
        sum(case when v.visit_start_date between (c.index_date - 365) and (c.index_date - 1)
                      and v.visit_concept_id = 9202 then 1 else 0 end) as pre_outpatient,
        sum(case when v.visit_start_date between (c.index_date + 1) and (c.index_date + 365)
                      and v.visit_concept_id = 9202 then 1 else 0 end) as post_outpatient,
        /* Inpatient pre vs post 1-year */
        sum(case when v.visit_start_date between (c.index_date - 365) and (c.index_date - 1)
                      and v.visit_concept_id = 9201 then 1 else 0 end) as pre_inpatient,
        sum(case when v.visit_start_date between (c.index_date + 1) and (c.index_date + 365)
                      and v.visit_concept_id = 9201 then 1 else 0 end) as post_inpatient
    from work.analytic_full c
    left join cdm.visit_occurrence v
        on c.person_id = v.person_id
    group by c.person_id, c.primary_indication;
quit;

/* Transpose HRU data into long format for paired boxplot visualization */
data work.hru_long;
    set work.hru_raw;
    period = '1 Yr Pre-Index '; visit_count = pre_outpatient; visit_type = 'Outpatient'; output;
    period = '1 Yr Post-Index'; visit_count = post_outpatient; visit_type = 'Outpatient'; output;
    period = '1 Yr Pre-Index '; visit_count = pre_inpatient;  visit_type = 'Inpatient';  output;
    period = '1 Yr Post-Index'; visit_count = post_inpatient;  visit_type = 'Inpatient';  output;
    keep person_id primary_indication period visit_count visit_type;
run;

/* ========================================================================== */
/* VISUALIZATION 2: Age Distribution by Primary Diagnosis (Boxplot)          */
/* ========================================================================== */

title1 bold "Figure 2: Age at Diagnosis Across Cardiometabolic Indications";
title2 h=10pt "Interquartile ranges and outliers for cohort age at index event";
proc sgplot data=work.analytic_full;
    vbox age_at_index / category=primary_indication 
                        group=gender
                        fillattrs=(transparency=0.2)
                        boxwidth=0.6;
    xaxis label="Primary Cardiometabolic Indication" labelattrs=(weight=bold);
    yaxis label="Age at Index (Years)" grid values=(0 to 100 by 10) labelattrs=(weight=bold);
    keylegend / title="Sex" position=topright location=inside across=1;
run;

/* ========================================================================== */
/* VISUALIZATION 3: Time-to-Treatment Initiation (Kaplan-Meier Survival Curve)*/
/* ========================================================================== */

title1 bold "Figure 3: Time to Initial Pharmacotherapy (Kaplan-Meier)";
title2 h=10pt "Probability of remaining untreated over 365 days post-index date";
proc lifetest data=work.analytic_full plots=survival(atrisk cb=hw test) notable;
    time time_to_tx * tx_event(0); /* 0 = Censored */
    strata primary_indication;
run;

/* ========================================================================== */
/* VISUALIZATION 4: Pre vs. Post Healthcare Utilization (Paired Boxplot)      */
/* ========================================================================== */

title1 bold "Figure 4: Healthcare Resource Utilization 1-Year Pre vs. Post Diagnosis";
title2 h=10pt "Comparison of encounter frequency before and after cardiometabolic index event";
proc sgplot data=work.hru_long;
    where visit_type = 'Outpatient';
    vbox visit_count / category=period 
                       group=primary_indication 
                       fillattrs=(transparency=0.3)
                       boxwidth=0.6;
    xaxis label="Study Observation Window" labelattrs=(weight=bold);
    yaxis label="Annual Outpatient Encounters" grid labelattrs=(weight=bold);
    keylegend / title="Indication" position=topright;
run;

title;  