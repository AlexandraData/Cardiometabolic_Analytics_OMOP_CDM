%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

proc sql;
    /* Clear target table */
    delete from cdm.visit_occurrence;

    /* Insert transformed records */
    insert into cdm.visit_occurrence (
        visit_occurrence_id,
        person_id,
        visit_concept_id,
        visit_start_date,
        visit_start_datetime,
        visit_end_date,
        visit_end_datetime,
        visit_type_concept_id,
        provider_id,
        care_site_id,
        visit_source_value,
        visit_source_concept_id,
        admitted_from_concept_id,
        admitted_from_source_value,
        discharged_to_concept_id,
        discharged_to_source_value,
        preceding_visit_occurrence_id
    )
    select
        monotonic() as visit_occurrence_id,
        p.person_id,
        case lowcase(e.encounterclass)
            when 'inpatient'   then 9201 /* Inpatient Visit */
            when 'outpatient'  then 9202 /* Outpatient Visit */
            when 'emergency'   then 9203 /* Emergency Room Visit */
            when 'ambulatory'  then 9202 /* Outpatient Visit */
            when 'wellness'    then 9202 /* Outpatient Visit */
            when 'urgentcare'  then 9203 /* Emergency Room Visit */
            else 0
        end as visit_concept_id,
        datepart(e.start) as visit_start_date,
        e.start           as visit_start_datetime,
        datepart(e.stop)  as visit_end_date,
        e.stop            as visit_end_datetime,
        32817             as visit_type_concept_id, /* OMOP: EHR encounter */
        .                 as provider_id,
        .                 as care_site_id,
        strip(e.Id)       as visit_source_value,
        0                 as visit_source_concept_id,
        0                 as admitted_from_concept_id,
        ''                as admitted_from_source_value,
        0                 as discharged_to_concept_id,
        ''                as discharged_to_source_value,
        .                 as preceding_visit_occurrence_id
    from raw.encounters e
    inner join cdm.person p
        on strip(e.patient) = strip(p.person_source_value);
quit;