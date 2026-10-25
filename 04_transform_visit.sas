/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  04_transform_visit.sas   (version 2)
* Purpose: Load CDM.VISIT_OCCURRENCE from raw.encounters.
* Needs:   03_transform_person and 03b_transform_provider_care_site run first.
* Notes:   - visit_occurrence_id follows the order of the visit start time (then
*            the Synthea Id), so the same input always gives the same IDs.
*            Re-run 05 and 06 after this script: they take visit_occurrence_id
*            from this table.
*          - provider_id and care_site_id come from the encounter's PROVIDER and
*            ORGANIZATION (every encounter has both).
*          - preceding_visit_occurrence_id = the same person's previous visit.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

proc sql;
    create table work.visit_stage0 as
    select
        p.person_id,
        lowcase(strip(e.encounterclass)) as encounterclass_src length=30,
        case lowcase(strip(e.encounterclass))
            when 'inpatient'   then 9201 /* Inpatient Visit */
            when 'outpatient'  then 9202 /* Outpatient Visit */
            when 'emergency'   then 9203 /* Emergency Room Visit */
            when 'ambulatory'  then 9202 /* Outpatient Visit */
            when 'wellness'    then 9202 /* Outpatient Visit */
            when 'urgentcare'  then 9203 /* Emergency Room Visit */
            else 0
        end as visit_concept_id,
        datepart(e.start)                  as visit_start_date format=date9.,
        e.start                            as visit_start_datetime format=datetime20.,
        datepart(coalesce(e.stop, e.start)) as visit_end_date format=date9.,
        coalesce(e.stop, e.start)          as visit_end_datetime format=datetime20.,
        32817                              as visit_type_concept_id, /* EHR encounter */
        pr.provider_id,
        cs.care_site_id,
        strip(e.Id)                        as visit_source_value length=50,
        0                                  as visit_source_concept_id,
        0                                  as admitted_from_concept_id,
        ''                                 as admitted_from_source_value length=50,
        0                                  as discharged_to_concept_id,
        ''                                 as discharged_to_source_value length=50
    from raw.encounters e
    inner join cdm.person p
        on strip(e.patient) = p.person_source_value
    left join cdm.provider pr
        on strip(e.provider) = pr.provider_source_value
    left join cdm.care_site cs
        on strip(e.organization) = cs.care_site_source_value
    order by e.start, e.Id;
quit;

data work.visit_stage1;
    set work.visit_stage0;
    visit_occurrence_id = _n_;
run;

proc sort data=work.visit_stage1;
    by person_id visit_start_datetime visit_occurrence_id;
run;

data work.visit_stage;
    set work.visit_stage1;
    by person_id;
    retain prev_id;
    if first.person_id then prev_id = .;
    preceding_visit_occurrence_id = prev_id;
    prev_id = visit_occurrence_id;
    keep visit_occurrence_id person_id visit_concept_id
         visit_start_date visit_start_datetime visit_end_date visit_end_datetime
         visit_type_concept_id provider_id care_site_id
         visit_source_value visit_source_concept_id
         admitted_from_concept_id admitted_from_source_value
         discharged_to_concept_id discharged_to_source_value
         preceding_visit_occurrence_id;
run;

/* Lookup: Synthea encounter class for each visit (wellness, ambulatory, ...).
   The CDM keeps all of them as outpatient (9202); script 09 uses this table
   for a sensitivity analysis that excludes wellness visits. */
proc sql;
    create table vocab.visit_class as
    select visit_occurrence_id, encounterclass_src as encounter_class
    from work.visit_stage1;

    delete from cdm.visit_occurrence;
quit;

proc append base=cdm.visit_occurrence data=work.visit_stage force;
run;

/* ========================================================================== */
/* Checks                                                                      */
/* ========================================================================== */

title "Check 1: one visit per encounter, every visit linked to provider and care site";
proc sql;
    select (select count(*) from raw.encounters)                              as raw_encounters,
           (select count(*) from cdm.visit_occurrence)                        as cdm_visits,
           (select count(distinct visit_source_value) from cdm.visit_occurrence) as distinct_encounter_ids,
           (select count(*) from cdm.visit_occurrence where provider_id is missing)  as visits_without_provider,
           (select count(*) from cdm.visit_occurrence where care_site_id is missing) as visits_without_care_site
    from (select 1 as x from raw.patients(obs=1));
quit;

title "Check 2: Synthea encounter class vs visit concept (0 = not mapped)";
proc sql;
    select encounterclass_src as synthea_encounterclass,
           visit_concept_id,
           count(*) as visits
    from work.visit_stage0
    group by encounterclass_src, visit_concept_id
    order by visits desc;
quit;

title "Check 3: end date before start date (must be 0)";
proc sql;
    select count(*) as visits_ending_before_start
    from cdm.visit_occurrence
    where visit_end_datetime < visit_start_datetime;
quit;
title;
