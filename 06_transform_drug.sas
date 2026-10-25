/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  06_transform_drug.sas   (version 2)
* Purpose: Load CDM.DRUG_EXPOSURE from raw.medications, using a crosswalk built
*          from the OMOP vocabulary (replaces the hand-typed CASE crosswalk).
* Needs:   02c_load_vocabulary_rxnorm_atc.sas run first (vocab.concept, vocab.maps_to);
*          cdm.person (03) and cdm.visit_occurrence (04) already loaded.
* Output:  vocab.drug_crosswalk (one row per Synthea code), cdm.drug_exposure
*
* Why version 2: the old crosswalk
*   (a) mapped ibuprofen 310965 to lisinopril, albuterol 2123111 to amoxicillin
*       and prednisone 312615 to simvastatin, and gave metformin and simvastatin
*       the same concept id;
*   (b) returned two rows for codes whose description differs only in letter
*       case (856987, 1000126, 1049221), which duplicated their drug_exposure rows;
*   (c) gave concept 0 to every drug outside its 7 hand-typed codes.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";
libname vocab "&project_path/vocab";   /* also add this line to 00_setup_libraries.sas */

/* ========================================================================== */
/* Step 1: Drug crosswalk from the vocabulary                                  */
/* Synthea CODE is an RxNorm code: find the RxNorm concept by code, then       */
/* follow 'Maps to' to the standard concept. One row per code.                 */
/* ========================================================================== */

proc sql;
    create table work.med_codes as
    select strip(put(code, 20.)) as source_code length=20,
           min(description) as description length=255
    from raw.medications
    group by calculated source_code;

    create table work.crosswalk_build as
    select s.source_code, s.description,
           c.concept_id as source_concept_id,
           coalesce(m.concept_id_2,
                    case when c.standard_concept = 'S' then c.concept_id else . end)
               as std_concept_id
    from work.med_codes s
    left join vocab.concept c
        on c.vocabulary_id = 'RxNorm'
       and c.concept_code = s.source_code
    left join vocab.maps_to m
        on m.concept_id_1 = c.concept_id;
quit;

/* Known mismatch: Synthea labels code 833036 'Captopril 25 MG Oral Tablet', but in
   RxNorm 833036 is acetaminophen / hydrocodone (confirmed in RxNav); the RxNorm
   code for captopril 25 MG Oral Tablet is 317173. We trust Synthea's description. */
proc sql noprint;
    select min(concept_id) into :captopril_id trimmed
    from vocab.concept
    where vocabulary_id = 'RxNorm'
      and concept_code = '317173'
      and standard_concept = 'S';
quit;
%put NOTE: concept id used for captopril 25 MG Oral Tablet = &captopril_id;

proc sort data=work.crosswalk_build;
    by source_code std_concept_id;
run;

data vocab.drug_crosswalk;
    length mapping_note $150;
    set work.crosswalk_build;
    by source_code;
    if first.source_code;   /* one row per code */
    if source_code = '833036' and &captopril_id ne . then do;
        std_concept_id = &captopril_id;
        mapping_note = 'Synthea code 833036 is captopril in Synthea but acetaminophen/hydrocodone in RxNorm; remapped to RxNorm 317173';
    end;
run;

title "Check 2: crosswalk summary";
proc sql;
    select count(*) as codes,
           sum(std_concept_id is missing) as codes_without_standard_concept,
           sum(mapping_note ne '') as codes_with_manual_fix
    from vocab.drug_crosswalk;
quit;
title;

/* ========================================================================== */
/* Step 2: Stage and load cdm.drug_exposure                                    */
/* drug_concept_id        = standard RxNorm concept                            */
/* drug_source_concept_id = concept of the original Synthea code               */
/* ========================================================================== */

proc sql;
    create table work.drug_stage as
    select
        p.person_id,
        coalesce(cw.std_concept_id, 0)           as drug_concept_id,
        datepart(m.start)                        as drug_exposure_start_date format=date9.,
        m.start                                  as drug_exposure_start_datetime format=datetime20.,
        case
            when m.stop is not null and datepart(m.stop) >= datepart(m.start)
            then intck('day', datepart(m.start), datepart(m.stop)) + 1
            else 30
        end                                      as days_supply,
        /* end date consistent with days_supply (ongoing drugs: start + 29 days) */
        datepart(m.start) + calculated days_supply - 1
                                                 as drug_exposure_end_date format=date9.,
        dhms(calculated drug_exposure_end_date, 0, 0, 0)
                                                 as drug_exposure_end_datetime format=datetime20.,
        datepart(m.stop)                         as verbatim_end_date format=date9.,
        32817                                    as drug_type_concept_id,
        ''                                       as stop_reason,
        0                                        as refills,
        m.dispenses                              as quantity,  /* Synthea DISPENSES = number of dispenses, kept for traceability */
        ''                                       as sig,
        0                                        as route_concept_id,
        ''                                       as lot_number,
        v.provider_id                            as provider_id,   /* inherited from the visit */
        v.visit_occurrence_id,
        .                                        as visit_detail_id,
        strip(put(m.code, 20.))                  as drug_source_value,
        coalesce(cw.source_concept_id, 0)        as drug_source_concept_id,
        ''                                       as route_source_value,
        ''                                       as dose_unit_source_value
    from raw.medications m
    inner join cdm.person p
        on strip(m.patient) = strip(p.person_source_value)
    left join cdm.visit_occurrence v
        on strip(m.encounter) = strip(v.visit_source_value)
    left join vocab.drug_crosswalk cw
        on strip(put(m.code, 20.)) = cw.source_code;
quit;

data work.drug_stage;
    set work.drug_stage;
    drug_exposure_id = _n_;
run;

proc sql;
    delete from cdm.drug_exposure;
quit;

proc append base=cdm.drug_exposure data=work.drug_stage force;
run;

/* ========================================================================== */
/* Step 3: Checks                                                              */
/* cdm rows must not exceed raw rows (more would mean duplicated joins).       */
/* ========================================================================== */

title "Check 3: row counts and unmapped drugs";
proc sql;
    select count(*) as raw_medication_rows from raw.medications;
    select count(*) as cdm_drug_exposure_rows,
           count(distinct drug_exposure_id) as distinct_ids,
           sum(drug_concept_id = 0) as rows_without_concept
    from cdm.drug_exposure;
quit;
title;
