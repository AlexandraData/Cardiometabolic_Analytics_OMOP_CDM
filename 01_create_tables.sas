
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
quit;