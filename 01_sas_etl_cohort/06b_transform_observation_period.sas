/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  06b_transform_observation_period.sas
* Purpose: Load CDM.OBSERVATION_PERIOD (one row per person) and fill
*          CDM.PERSON.care_site_id.
* Needs:   03 (person, death), 03b, 04 (visits) run first.
*
* Rule for the observation period (decision "option 2"):
*   start = earliest date of any visit, condition or drug of the person
*           (normally the first visit)
*   end   = death date if the person died, otherwise the latest date in the
*           extract (the last visit end date over ALL patients)
*   So living patients share the same end date; this is correct, because the
*   extract is a snapshot taken on one day.
*
* person.care_site_id = the care site of the person's most frequent visit
*   (ties: lowest care_site_id).
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* ========================================================================== */
/* Step 1: Observation period                                                  */
/* ========================================================================== */

proc sql noprint;
    select max(visit_end_date) into :extract_end trimmed
    from cdm.visit_occurrence;
quit;
%put NOTE: latest date in the extract = %sysfunc(putn(&extract_end, date9.));

proc sql;
    /* first date of any kind per person (a few conditions and drugs are dated
       1 day before the first visit) */
    create table work.first_dates as
    select person_id, min(d) as first_date format=date9.
    from (select person_id, visit_start_date as d from cdm.visit_occurrence
          union all
          select person_id, condition_start_date from cdm.condition_occurrence
          union all
          select person_id, drug_exposure_start_date from cdm.drug_exposure)
    group by person_id;

    create table work.obs_stage0 as
    select f.person_id,
           f.first_date            as observation_period_start_date format=date9.,
           coalesce(d.death_date, &extract_end)
                                   as observation_period_end_date format=date9.,
           32817                   as period_type_concept_id   /* EHR */
    from work.first_dates f
    left join cdm.death d
        on f.person_id = d.person_id
    order by f.person_id;
quit;

data work.obs_stage;
    set work.obs_stage0;
    observation_period_id = _n_;
run;

proc sql;
    delete from cdm.observation_period;
quit;

proc append base=cdm.observation_period data=work.obs_stage force;
run;

/* ========================================================================== */
/* Step 2: person.care_site_id from the most frequent visit care site          */
/* ========================================================================== */

proc sql;
    create table work.person_site as
    select person_id, care_site_id, count(*) as n_visits
    from cdm.visit_occurrence
    where care_site_id is not missing
    group by person_id, care_site_id
    order by person_id, calculated n_visits desc, care_site_id;
quit;

data work.person_site1;
    set work.person_site;
    by person_id;
    if first.person_id;
run;

proc sql;
    update cdm.person p
    set care_site_id = (select s.care_site_id
                        from work.person_site1 s
                        where s.person_id = p.person_id);
quit;

/* ========================================================================== */
/* Checks                                                                      */
/* ========================================================================== */

title "Check 1: one observation period per person; persons without visits";
proc sql;
    select (select count(*) from cdm.person)                          as persons,
           (select count(*) from cdm.observation_period)              as obs_periods,
           (select count(distinct person_id) from cdm.observation_period) as persons_with_period,
           (select count(*) from cdm.person
             where person_id not in (select person_id from cdm.observation_period))
                                                                      as persons_without_period,
           (select count(*) from cdm.observation_period
             where observation_period_end_date < observation_period_start_date)
                                                                      as end_before_start
    from (select 1 as x from raw.patients(obs=1));
quit;

title "Check 2: events outside the observation period (should be 0 or explainable)";
proc sql;
    select 'visits' as event_table, count(*) as rows_outside
    from cdm.visit_occurrence v inner join cdm.observation_period o
        on v.person_id = o.person_id
    where v.visit_start_date < o.observation_period_start_date
       or v.visit_start_date > o.observation_period_end_date
    union all
    select 'conditions', count(*)
    from cdm.condition_occurrence c inner join cdm.observation_period o
        on c.person_id = o.person_id
    where c.condition_start_date < o.observation_period_start_date
       or c.condition_start_date > o.observation_period_end_date
    union all
    select 'drugs', count(*)
    from cdm.drug_exposure d inner join cdm.observation_period o
        on d.person_id = o.person_id
    where d.drug_exposure_start_date < o.observation_period_start_date
       or d.drug_exposure_start_date > o.observation_period_end_date;
quit;

title "Check 3: person.care_site_id filled";
proc sql;
    select count(*) as persons,
           sum(care_site_id is missing) as persons_without_care_site
    from cdm.person;
quit;

title "Check 4: observation period length (years)";
proc sql;
    select min((observation_period_end_date - observation_period_start_date)/365.25) as min_years format=8.1,
           median((observation_period_end_date - observation_period_start_date)/365.25) as median_years format=8.1,
           max((observation_period_end_date - observation_period_start_date)/365.25) as max_years format=8.1
    from cdm.observation_period;
quit;
title;
