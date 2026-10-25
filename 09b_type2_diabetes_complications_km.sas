/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  09b_type2_diabetes_complications_km.sas
* Purpose: Kaplan-Meier curves for the time from the type 2 diabetes diagnosis to
*          (a) the first kidney disease or diabetic complication (retinopathy,
*          neuropathy), and (b) each of the two separately.
* Needs:   06b, 06c and 09 run first (results.patient_condition_flags,
*          cdm.observation_period).
* Output:  results.t2dm_complication_km  (one row per patient and outcome)
*
* Definitions
*   Start      = date of the first type 2 diabetes record (flag table).
*   Event      = first kidney disease / diabetic complication record AFTER that
*                date. Patients who already had the outcome on or before the
*                diagnosis date are left out of that outcome (not incident).
*   Censoring  = end of the observation period (death or end of the extract).
*   Time unit  = years. Follow-up is cut at 25 years (administrative censoring):
*                beyond that fewer than 5 patients are at risk and single events
*                make the curve jump (for example kidney disease at 42 years).
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";
libname results "&project_path/results";

ods graphics on / reset=all width=900px height=550px;

%let max_years = 25;   /* administrative censoring, see header */

/* ========================================================================== */
/* Step 1: Type 2 diabetes patients with their outcome dates                   */
/* ========================================================================== */

proc sql;
    create table work.t2d_base as
    select f.person_id,
           f.type2_diabetes_date          as t2d_date format=date9.,
           f.kidney_disease_date,
           f.diabetic_complications_date,
           min(f.kidney_disease_date, f.diabetic_complications_date)
                                          as any_outcome_date format=date9.,
           o.observation_period_end_date  as obs_end format=date9.
    from results.patient_condition_flags f
    inner join cdm.observation_period o
        on f.person_id = o.person_id
    where f.type2_diabetes = 1;
quit;

/* ========================================================================== */
/* Step 2: One row per patient and outcome: time in years and event 0/1        */
/* ========================================================================== */

proc datasets library=work nolist;
    delete t2d_km;
quit;

%macro add_outcome(label=, datevar=);
    data work._o;
        length outcome $60;
        set work.t2d_base;
        outcome = "&label";
        if &datevar ne . and &datevar <= t2d_date then delete;  /* already present at diagnosis */
        if &datevar ne . then do;
            time_years = (&datevar - t2d_date) / 365.25;
            event = 1;
        end;
        else do;
            time_years = (obs_end - t2d_date) / 365.25;
            event = 0;
        end;
        if time_years > &max_years then do;
            time_years = &max_years;
            event = 0;
        end;
        keep person_id outcome time_years event;
    run;
    proc append base=work.t2d_km data=work._o force;
    run;
%mend add_outcome;

%add_outcome(label=Kidney disease or diabetic complication, datevar=any_outcome_date)
%add_outcome(label=Kidney disease,                          datevar=kidney_disease_date)
%add_outcome(label=Diabetic complications (retinopathy and neuropathy), datevar=diabetic_complications_date)

data results.t2dm_complication_km;
    set work.t2d_km;
    label time_years = "Years since type 2 diabetes diagnosis";
run;

title "Check 1: patients, events and patients left out because the outcome was already present";
proc sql;
    select o.outcome,
           count(distinct o.person_id) as patients_in_analysis,
           sum(o.event) as events,
           (select count(*) from work.t2d_base) - calculated patients_in_analysis as left_out_already_present,
           median(o.time_years) as median_follow_up_years format=6.1,
           max(o.time_years)    as max_follow_up_years format=6.1
    from results.t2dm_complication_km o
    group by o.outcome;
quit;
title;

/* ========================================================================== */
/* Figure 5: any kidney disease or diabetic complication                       */
/* ========================================================================== */

title1 bold "Figure 5: Time from Type 2 Diabetes Diagnosis to First Kidney Disease or Diabetic Complication";
title2 h=10pt "Cumulative probability, 95% Hall-Wellner bands; censored at death or end of data";
proc lifetest data=results.t2dm_complication_km
              (where=(outcome = 'Kidney disease or diabetic complication'))
              plots=survival(failure atrisk cb=hw) notable;
    time time_years * event(0);
run;

/* ========================================================================== */
/* Figure 6: kidney disease and diabetic complications separately              */
/* The same patients appear in both curves, so no group test is shown.         */
/* ========================================================================== */

title1 bold "Figure 6: Kidney Disease and Diabetic Complications After Type 2 Diabetes Diagnosis";
title2 h=10pt "Cumulative probability; the two outcomes are measured in the same patients (no log-rank test)";
proc lifetest data=results.t2dm_complication_km
              (where=(outcome in ('Kidney disease',
                                  'Diabetic complications (retinopathy and neuropathy)')))
              plots=survival(failure atrisk) notable;
    time time_years * event(0);
    strata outcome / test=none;
run;

title;
