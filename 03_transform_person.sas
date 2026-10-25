/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  03_transform_person.sas   (version 2)
* Purpose: Load CDM.PERSON from raw.patients.
* Needs:   01_create_tables, 02_import_raw run first.
* Notes:   - person_id is assigned in order of the Synthea patient Id, so the
*            same input always gives the same person_id (monotonic() gives no
*            such guarantee). Re-run 04, 05, 06 after this script: they join to
*            cdm.person on person_source_value.
*          - provider_id and care_site_id stay missing here; care_site_id is
*            filled later from the patient's encounters.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

proc sort data=raw.patients out=work.patients_sorted;
    by Id;
run;

data work.person_stage;
    length person_source_value $50 gender_source_value $50
           race_source_value $50 ethnicity_source_value $50;
    set work.patients_sorted;

    person_id = _n_;

    select (upcase(strip(gender)));
        when ('M') gender_concept_id = 8507;   /* MALE */
        when ('F') gender_concept_id = 8532;   /* FEMALE */
        otherwise  gender_concept_id = 0;
    end;

    year_of_birth  = year(birthdate);
    month_of_birth = month(birthdate);
    day_of_birth   = day(birthdate);
    birth_datetime = dhms(birthdate, 0, 0, 0);
    format birth_datetime datetime20.;

    /* Race concepts, each checked in ATHENA (Standard, Race domain) */
    select (lowcase(strip(race)));
        when ('white')    race_concept_id = 8527;   /* White */
        when ('black')    race_concept_id = 8516;   /* Black or African American */
        when ('asian')    race_concept_id = 8515;   /* Asian */
        when ('native')   race_concept_id = 8657;   /* American Indian or Alaska Native */
        when ('hawaiian') race_concept_id = 8557;   /* Native Hawaiian or Other Pacific Islander */
        /* 'other': 'Other Race' (8522) is non-standard and invalid in ATHENA, so there is
           no standard concept. 0 = no matching concept; race_source_value keeps 'other'. */
        otherwise         race_concept_id = 0;
    end;

    select (lowcase(strip(ethnicity)));
        when ('hispanic')    ethnicity_concept_id = 38003563;
        when ('nonhispanic') ethnicity_concept_id = 38003564;
        otherwise            ethnicity_concept_id = 0;
    end;

    person_source_value        = strip(Id);
    gender_source_value        = strip(gender);
    gender_source_concept_id   = 0;
    race_source_value          = strip(race);
    race_source_concept_id     = 0;
    ethnicity_source_value     = strip(ethnicity);
    ethnicity_source_concept_id = 0;

    keep person_id gender_concept_id year_of_birth month_of_birth day_of_birth
         birth_datetime race_concept_id ethnicity_concept_id
         person_source_value gender_source_value gender_source_concept_id
         race_source_value race_source_concept_id
         ethnicity_source_value ethnicity_source_concept_id;
run;

proc sql;
    delete from cdm.person;
quit;

proc append base=cdm.person data=work.person_stage force;
run;

/* ========================================================================== */
/* DEATH: patients with a DEATHDATE in Synthea (no cause of death is recorded) */
/* death_type_concept_id 32817 = EHR (same type concept as the drug records)   */
/* ========================================================================== */

proc sql;
    create table work.death_stage as
    select p.person_id,
           r.deathdate                  as death_date format=date9.,
           dhms(r.deathdate, 0, 0, 0)   as death_datetime format=datetime20.,
           32817                        as death_type_concept_id,
           0                            as cause_concept_id,
           ''                           as cause_source_value length=50,
           0                            as cause_source_concept_id
    from raw.patients r
    inner join cdm.person p
        on strip(r.Id) = p.person_source_value
    where r.deathdate is not missing;

    delete from cdm.death;
quit;

proc append base=cdm.death data=work.death_stage force;
run;

/* ========================================================================== */
/* Checks                                                                      */
/* ========================================================================== */

title "Check 1: one person per raw patient";
proc sql;
    select (select count(*) from raw.patients)                  as raw_patients,
           (select count(*) from cdm.person)                    as cdm_persons,
           (select count(distinct person_source_value) from cdm.person) as distinct_source_ids
    from (select 1 as x from raw.patients(obs=1));
quit;

title "Check 2: source values vs mapped concepts (a 0 concept means an unmapped value)";
proc sql;
    select 'gender' as field, gender_source_value as source_value,
           gender_concept_id as concept_id, count(*) as persons
    from cdm.person group by gender_source_value, gender_concept_id
    union all
    select 'race', race_source_value, race_concept_id, count(*)
    from cdm.person group by race_source_value, race_concept_id
    union all
    select 'ethnicity', ethnicity_source_value, ethnicity_concept_id, count(*)
    from cdm.person group by ethnicity_source_value, ethnicity_concept_id
    order by 1, 4 desc;
quit;

title "Check 3: deaths (cdm_deaths must equal raw_deaths; died_before_birth must be 0)";
proc sql;
    select (select count(*) from raw.patients where deathdate is not missing) as raw_deaths,
           (select count(*) from cdm.death) as cdm_deaths,
           (select count(*) from cdm.death d
            inner join cdm.person p on d.person_id = p.person_id
            where d.death_date < mdy(p.month_of_birth, p.day_of_birth, p.year_of_birth)) as died_before_birth
    from (select 1 as x from raw.patients(obs=1));
quit;
title;
