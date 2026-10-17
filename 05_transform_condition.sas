%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* Step 1: Condition crosswalk */
proc sql;
    create table work.condition_crosswalk as
    select distinct 
        code as source_code,
        description as source_desc,
        case code
            when 44054006  then 201826   /* Type 2 diabetes mellitus */
            when 38341003  then 320128   /* Essential hypertension */
            when 59621000  then 316866   /* Essential hypertension */
            when 195662009 then 255573   /* Acute bronchitis */
            when 10509002  then 255573   /* Acute bronchitis */
            when 65363002  then 376225   /* Otitis media */
            when 444814009 then 4112343  /* Viral sinusitis */
            when 40055000  then 257007   /* Chronic sinusitis */
            when 53741008  then 317576   /* Coronary arteriosclerosis */
            when 15777000  then 438112   /* Prediabetes */
            when 271737000 then 434005   /* Anemia */
            when 162864005 then 437663   /* Obesity */
            when 840539006 then 37311061 /* COVID-19 */
            else 0
        end as target_concept_id
    from raw.conditions;
quit;

/* Step 2: Repopulate cdm.condition_occurrence with stripped join keys */
proc sql;
    delete from cdm.condition_occurrence;

    insert into cdm.condition_occurrence (
        condition_occurrence_id,
        person_id,
        condition_concept_id,
        condition_start_date,
        condition_start_datetime,
        condition_end_date,
        condition_end_datetime,
        condition_type_concept_id,
        condition_status_concept_id,
        stop_reason,
        provider_id,
        visit_occurrence_id,
        visit_detail_id,
        condition_source_value,
        condition_source_concept_id,
        condition_status_source_value
    )
    select
        monotonic() as condition_occurrence_id,
        p.person_id,
        coalesce(cw.target_concept_id, 0) as condition_concept_id,
        c.start                  as condition_start_date,
        dhms(c.start, 0, 0, 0)   as condition_start_datetime,
        c.stop                   as condition_end_date,
        case 
            when c.stop is not null then dhms(c.stop, 0, 0, 0)
            else .
        end                      as condition_end_datetime,
        32817                    as condition_type_concept_id,
        0                        as condition_status_concept_id,
        ''                       as stop_reason,
        .                        as provider_id,
        v.visit_occurrence_id,
        .                        as visit_detail_id,
        strip(put(c.code, 12.))  as condition_source_value,
        0                        as condition_source_concept_id,
        ''                       as condition_status_source_value
    from raw.conditions c
    inner join cdm.person p
        on strip(c.patient) = strip(p.person_source_value)
    left join cdm.visit_occurrence v
        on strip(c.encounter) = strip(v.visit_source_value)
    left join work.condition_crosswalk cw
        on c.code = cw.source_code;
quit;