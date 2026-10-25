/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  01_create_tables.sas
* Purpose: Create empty OMOP CDM v5.4 tables in the CDM library.
*          Core clinical tables: person, visit_occurrence, condition_occurrence,
*          drug_exposure. Health-system tables: provider, care_site.
*          Observation window: observation_period. Deaths: death.
* Note:    Re-running this script EMPTIES every table it creates. Re-run the
*          transform scripts (03-06) afterwards.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

proc sql;
    /* 1. PERSON */
    create table cdm.person (
        person_id                   num,
        gender_concept_id           num,
        year_of_birth               num,
        month_of_birth              num,
        day_of_birth                num,
        birth_datetime              num format=datetime20.,
        race_concept_id             num,
        ethnicity_concept_id        num,
        location_id                 num,
        provider_id                 num,
        care_site_id                num,
        person_source_value         char(50),
        gender_source_value         char(50),
        gender_source_concept_id    num,
        race_source_value           char(50),
        race_source_concept_id      num,
        ethnicity_source_value      char(50),
        ethnicity_source_concept_id num
    );

    /* 2. VISIT_OCCURRENCE */
    create table cdm.visit_occurrence (
        visit_occurrence_id           num,
        person_id                     num,
        visit_concept_id              num,
        visit_start_date              num format=date9.,
        visit_start_datetime          num format=datetime20.,
        visit_end_date                num format=date9.,
        visit_end_datetime            num format=datetime20.,
        visit_type_concept_id         num,
        provider_id                   num,
        care_site_id                  num,
        visit_source_value            char(50),
        visit_source_concept_id       num,
        admitted_from_concept_id      num,
        admitted_from_source_value    char(50),
        discharged_to_concept_id      num,
        discharged_to_source_value    char(50),
        preceding_visit_occurrence_id num
    );

    /* 3. CONDITION_OCCURRENCE */
    create table cdm.condition_occurrence (
        condition_occurrence_id       num,
        person_id                     num,
        condition_concept_id          num,
        condition_start_date          num format=date9.,
        condition_start_datetime      num format=datetime20.,
        condition_end_date            num format=date9.,
        condition_end_datetime        num format=datetime20.,
        condition_type_concept_id     num,
        condition_status_concept_id   num,
        stop_reason                   char(20),
        provider_id                   num,
        visit_occurrence_id           num,
        visit_detail_id               num,
        condition_source_value        char(50),
        condition_source_concept_id   num,
        condition_status_source_value char(50)
    );

    /* 4. DRUG_EXPOSURE */
    create table cdm.drug_exposure (
        drug_exposure_id             num,
        person_id                    num,
        drug_concept_id              num,
        drug_exposure_start_date     num format=date9.,
        drug_exposure_start_datetime num format=datetime20.,
        drug_exposure_end_date       num format=date9.,
        drug_exposure_end_datetime   num format=datetime20.,
        verbatim_end_date            num format=date9.,
        drug_type_concept_id         num,
        stop_reason                  char(20),
        refills                      num,
        quantity                     num,
        days_supply                  num,
        sig                          char(255),
        route_concept_id             num,
        lot_number                   char(50),
        provider_id                  num,
        visit_occurrence_id          num,
        visit_detail_id              num,
        drug_source_value            char(100),
        drug_source_concept_id       num,
        route_source_value           char(50),
        dose_unit_source_value       char(50)
    );

    /* 5. PROVIDER (Synthea providers.csv) */
    create table cdm.provider (
        provider_id                   num,
        provider_name                 char(255),
        npi                           char(20),
        dea                           char(20),
        specialty_concept_id          num,
        care_site_id                  num,
        year_of_birth                 num,
        gender_concept_id             num,
        provider_source_value         char(50),
        specialty_source_value        char(50),
        specialty_source_concept_id   num,
        gender_source_value           char(50),
        gender_source_concept_id      num
    );

    /* 6. CARE_SITE (Synthea organizations.csv) */
    create table cdm.care_site (
        care_site_id                  num,
        care_site_name                char(255),
        place_of_service_concept_id   num,
        location_id                   num,
        care_site_source_value        char(50),
        place_of_service_source_value char(50)
    );

    /* 7. OBSERVATION_PERIOD (follow-up window per person) */
    create table cdm.observation_period (
        observation_period_id         num,
        person_id                     num,
        observation_period_start_date num format=date9.,
        observation_period_end_date   num format=date9.,
        period_type_concept_id        num
    );

    /* 8. DEATH (Synthea patients.csv DEATHDATE; no cause of death is recorded) */
    create table cdm.death (
        person_id                     num,
        death_date                    num format=date9.,
        death_datetime                num format=datetime20.,
        death_type_concept_id         num,
        cause_concept_id              num,
        cause_source_value            char(50),
        cause_source_concept_id       num
    );
quit;
