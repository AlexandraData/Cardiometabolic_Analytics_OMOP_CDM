%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* Step 1: Drug crosswalk */
proc sql;
    create table work.drug_crosswalk as
    select distinct 
        code as source_code,
        description as source_desc,
        case code
            when 860975  then 19078461 /* Metformin 500mg */
            when 197361  then 19001409 /* Amlodipine 5mg */
            when 310965  then 1308216  /* Lisinopril 10mg */
            when 310798  then 19059798 /* Hydrochlorothiazide 25mg */
            when 617314  then 1545958  /* Atorvastatin 20mg */
            when 312615  then 19078461 /* Simvastatin 20mg */
            when 2123111 then 40165254 /* Amoxicillin 500mg */
            else 0
        end as target_concept_id
    from raw.medications;
quit;

/* Step 2: Repopulate cdm.drug_exposure with stripped join keys */
proc sql;
    delete from cdm.drug_exposure;

    insert into cdm.drug_exposure (
        drug_exposure_id,
        person_id,
        drug_concept_id,
        drug_exposure_start_date,
        drug_exposure_start_datetime,
        drug_exposure_end_date,
        drug_exposure_end_datetime,
        verbatim_end_date,
        drug_type_concept_id,
        stop_reason,
        refills,
        quantity,
        days_supply,
        sig,
        route_concept_id,
        lot_number,
        provider_id,
        visit_occurrence_id,
        visit_detail_id,
        drug_source_value,
        drug_source_concept_id,
        route_source_value,
        dose_unit_source_value
    )
    select
        monotonic() as drug_exposure_id,
        p.person_id,
        coalesce(cw.target_concept_id, 0) as drug_concept_id,
        datepart(m.start) as drug_exposure_start_date,
        m.start           as drug_exposure_start_datetime,
        coalesce(datepart(m.stop), datepart(m.start)) as drug_exposure_end_date,
        coalesce(m.stop, m.start)                     as drug_exposure_end_datetime,
        datepart(m.stop)  as verbatim_end_date,
        32817             as drug_type_concept_id,
        ''                as stop_reason,
        0                 as refills,
        m.dispenses       as quantity,
        case 
            when m.stop is not null and datepart(m.stop) >= datepart(m.start)
            then intck('day', datepart(m.start), datepart(m.stop)) + 1
            else 30
        end               as days_supply,
        ''                as sig,
        0                 as route_concept_id,
        ''                as lot_number,
        .                 as provider_id,
        v.visit_occurrence_id,
        .                 as visit_detail_id,
        strip(put(m.code, 12.)) as drug_source_value,
        0                 as drug_source_concept_id,
        ''                as route_source_value,
        ''                as dose_unit_source_value
    from raw.medications m
    inner join cdm.person p
        on strip(m.patient) = strip(p.person_source_value)
    left join cdm.visit_occurrence v
        on strip(m.encounter) = strip(v.visit_source_value)
    left join work.drug_crosswalk cw
        on m.code = cw.source_code;
quit;