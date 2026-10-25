/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  05_transform_condition.sas   (version 3)
* Purpose: Load CDM.CONDITION_OCCURRENCE from raw.conditions, mapping each
*          Synthea SNOMED code through the OMOP vocabulary.
* Needs:   03_transform_person, 04_transform_visit and 02b_load_vocabulary_snomed run first.
* Output:  vocab.condition_crosswalk (one row per Synthea code),
*          vocab.conditions_not_loaded (codes left out, with the reason),
*          cdm.condition_occurrence
*
* Method:  source code -> SNOMED concept -> 'Maps to' -> standard concept.
*          Standard concepts in the CONDITION domain are loaded. Source codes whose
*          own domain is Condition but that have no standard concept (retired
*          codes) are also loaded, with concept 0 and the source concept kept, as
*          OMOP practice requires. Social and
*          clinical findings (employment, education, stress...) belong in an
*          observation table and are not loaded; they are counted in
*          vocab.conditions_not_loaded.
*          The seven cohort codes used by script 09 are ALWAYS loaded, whatever
*          their domain, so the cohort cannot change by accident.
*
* History: v2 removed duplicated rows caused by select distinct code,
*          description (84757009 Epilepsy and 233604007 Pneumonia, +71 rows).
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* Cohort codes used in script 09 (type 2 diabetes, prediabetes, hypertension x2,
   coronary arteriosclerosis, hyperlipidemia, hypertriglyceridemia) */
%let cohort_codes = '44054006','15777000','38341003','59621000','53741008','55822004','302870006';

/* ========================================================================== */
/* Step 1: One row per Synthea code, mapped through the vocabulary             */
/* ========================================================================== */

proc sql;
    create table work.cond_codes as
    select strip(put(code, 20.)) as source_code length=20,
           min(description) as description length=255
    from raw.conditions
    group by calculated source_code;

    create table work.cond_map0 as
    select a.source_code, a.description,
           s.concept_id as source_concept_id,
           s.domain_id  as source_domain length=20,
           coalesce(m.concept_id_2,
                    case when s.standard_concept = 'S' then s.concept_id else . end)
               as std_concept_id
    from work.cond_codes a
    left join vocab.snomed_concept s
        on s.concept_code = a.source_code
    left join vocab.snomed_maps_to m
        on m.concept_id_1 = s.concept_id;

    /* codes that map to more than one standard concept (we keep the lowest id) */
    create table work.cond_ntargets as
    select source_code, count(distinct std_concept_id) as n_targets
    from work.cond_map0
    group by source_code;
quit;

proc sort data=work.cond_map0;
    by source_code std_concept_id;
run;

data work.cond_map1;
    set work.cond_map0;
    by source_code;
    if first.source_code;
run;

proc sql;
    create table vocab.condition_crosswalk as
    select x.source_code, x.description, x.source_concept_id, x.source_domain,
           x.std_concept_id,
           t.concept_name as std_concept_name length=255,
           coalesce(t.domain_id, 'Unmapped') as std_domain length=20,
           n.n_targets,
           case when calculated std_domain = 'Condition'
                  or x.source_code in (&cohort_codes)
                  or (calculated std_domain = 'Unmapped' and x.source_domain = 'Condition')
                then 1 else 0 end as load_flag
    from work.cond_map1 x
    left join vocab.snomed_concept t
        on t.concept_id = x.std_concept_id
    left join work.cond_ntargets n
        on x.source_code = n.source_code;
quit;

/* ========================================================================== */
/* Step 2: Stage and load cdm.condition_occurrence                             */
/* ========================================================================== */

proc sql;
    create table work.cond_stage0 as
    select
        p.person_id,
        coalesce(cw.std_concept_id, 0)          as condition_concept_id,
        c.start                                 as condition_start_date format=date9.,
        dhms(c.start, 0, 0, 0)                  as condition_start_datetime format=datetime20.,
        c.stop                                  as condition_end_date format=date9.,
        case when c.stop is not null then dhms(c.stop, 0, 0, 0) else . end
                                                as condition_end_datetime format=datetime20.,
        32817                                   as condition_type_concept_id, /* EHR */
        0                                       as condition_status_concept_id,
        ''                                      as stop_reason length=20,
        v.provider_id,                           /* inherited from the visit */
        v.visit_occurrence_id,
        .                                       as visit_detail_id,
        strip(put(c.code, 20.))                 as condition_source_value length=50,
        coalesce(cw.source_concept_id, 0)       as condition_source_concept_id,
        ''                                      as condition_status_source_value length=50
    from raw.conditions c
    inner join cdm.person p
        on strip(c.patient) = p.person_source_value
    left join cdm.visit_occurrence v
        on strip(c.encounter) = v.visit_source_value
    inner join vocab.condition_crosswalk cw
        on strip(put(c.code, 20.)) = cw.source_code
    where cw.load_flag = 1
    order by p.person_id, c.start, calculated condition_source_value;
quit;

data work.cond_stage;
    set work.cond_stage0;
    condition_occurrence_id = _n_;
    keep condition_occurrence_id person_id condition_concept_id
         condition_start_date condition_start_datetime
         condition_end_date condition_end_datetime
         condition_type_concept_id condition_status_concept_id stop_reason
         provider_id visit_occurrence_id visit_detail_id
         condition_source_value condition_source_concept_id
         condition_status_source_value;
run;

proc sql;
    delete from cdm.condition_occurrence;
quit;

proc append base=cdm.condition_occurrence data=work.cond_stage force;
run;

/* Codes (and rows) that were NOT loaded, with the reason */
proc sql;
    create table vocab.conditions_not_loaded as
    select cw.source_code, cw.description, cw.std_domain,
           cw.std_concept_name,
           case when cw.std_domain = 'Unmapped'
                then 'No standard concept; source domain ' || coalesce(cw.source_domain, 'unknown')
                else 'Domain is ' || strip(cw.std_domain) || ', not Condition' end as reason length=80,
           count(*) as rows_left_out,
           count(distinct c.patient) as patients
    from raw.conditions c
    inner join vocab.condition_crosswalk cw
        on strip(put(c.code, 20.)) = cw.source_code
    where cw.load_flag = 0
    group by cw.source_code, cw.description, cw.std_domain, cw.std_concept_name, cw.source_domain
    order by rows_left_out desc;
quit;

/* ========================================================================== */
/* Checks                                                                      */
/* ========================================================================== */

title "Check 1: every raw row is either loaded or left out (difference must be 0)";
proc sql;
    select (select count(*) from raw.conditions)               as raw_conditions,
           (select count(*) from cdm.condition_occurrence)     as loaded,
           (select coalesce(sum(rows_left_out), 0) from vocab.conditions_not_loaded) as left_out,
           calculated raw_conditions - calculated loaded - calculated left_out as difference,
           (select count(*) from cdm.condition_occurrence where visit_occurrence_id is missing) as loaded_without_visit,
           (select count(*) from cdm.condition_occurrence where condition_concept_id = 0)       as loaded_with_concept_0
    from (select 1 as x from raw.patients(obs=1));
quit;

title "Check 2: codes by standard domain";
proc sql;
    select std_domain, count(*) as codes, sum(load_flag) as loaded_codes
    from vocab.condition_crosswalk
    group by std_domain
    order by codes desc;
    select count(*) as codes_multi_target
    from vocab.condition_crosswalk where n_targets > 1;
quit;

title "Check 3: the cohort codes found in the data (all must be loaded)";
proc sql;
    select x.source_code, x.description, x.std_concept_id, x.std_concept_name,
           x.std_domain, x.load_flag,
           (select count(*) from cdm.condition_occurrence o
            where o.condition_source_value = x.source_code) as rows_loaded
    from vocab.condition_crosswalk x
    where x.source_code in (&cohort_codes)
    order by x.source_code;
quit;

title "Check 4: the 25 most frequent codes left out";
proc print data=vocab.conditions_not_loaded(obs=25) noobs;
    var source_code description reason rows_left_out patients;
run;
title;
