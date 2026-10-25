/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  07_qc_checks.sas   (version 2)
* Purpose: Data quality report for the whole CDM. Run after 03 ... 06b.
* Layout:  Part A = raw import checks, Part B = CDM table checks.
*          Part B writes one line per check into work.dq with a status:
*            must be 0  -> PASS if 0, FAIL otherwise
*            info       -> reported in the portfolio, not an error
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* ========================================================================== */
/* Part A: raw import                                                          */
/* ========================================================================== */

%macro check_import(file, ds);
    data _null_;
        infile "&project_path/raw/&file..csv" end=eof;
        input;
        n + 1;
        if eof then call symputx('file_rows', n - 1);
    run;
    proc sql noprint;
        select count(*) into :ds_rows trimmed from &ds;
    quit;
    %put NOTE: &file: data lines in file = &file_rows, rows imported = &ds_rows;
%mend check_import;

%check_import(patients,      raw.patients)
%check_import(encounters,    raw.encounters)
%check_import(conditions,    raw.conditions)
%check_import(medications,   raw.medications)
%check_import(providers,     raw.providers)
%check_import(organizations, raw.organizations)

title "A1: every encounter links to a provider and an organization";
proc sql;
    select count(*) as encounters,
           sum(provider ne '') as with_provider,
           sum(organization ne '') as with_organization,
           (select count(*) from raw.encounters e
             left join raw.providers p on e.provider = p.id
             where p.id is null) as enc_no_provider_match,
           (select count(*) from raw.encounters e
             left join raw.organizations o on e.organization = o.id
             where o.id is null) as enc_no_org_match
    from raw.encounters;
quit;

/* ========================================================================== */
/* Part B: CDM                                                                 */
/* ========================================================================== */

title "B1: table row counts";
proc sql;
    select 'cdm.person' as table_name length=30, count(*) as total_records from cdm.person
    union all select 'cdm.death', count(*) from cdm.death
    union all select 'cdm.observation_period', count(*) from cdm.observation_period
    union all select 'cdm.care_site', count(*) from cdm.care_site
    union all select 'cdm.provider', count(*) from cdm.provider
    union all select 'cdm.visit_occurrence', count(*) from cdm.visit_occurrence
    union all select 'cdm.condition_occurrence', count(*) from cdm.condition_occurrence
    union all select 'cdm.drug_exposure', count(*) from cdm.drug_exposure;
quit;

title "B2: rows without a standard concept (concept_id = 0)";
proc sql;
    select 'Conditions' as domain length=20,
           count(*) as total_rows,
           sum(condition_concept_id = 0) as unmapped_rows,
           calculated unmapped_rows / calculated total_rows as unmapped_rate format=percent8.2
    from cdm.condition_occurrence
    union all
    select 'Drugs' as domain,
           count(*) as total_rows,
           sum(drug_concept_id = 0) as unmapped_rows,
           calculated unmapped_rows / calculated total_rows as unmapped_rate format=percent8.2
    from cdm.drug_exposure;
quit;

/* ---- list of checks -------------------------------------------------------- */
proc sql;
    create table work.dq
        (check_group char(24), check_description char(80), expected char(12), violations num);

    /* foreign keys */
    insert into work.dq
    select 'Foreign keys', 'Visits with invalid person_id', 'must be 0', count(*)
    from cdm.visit_occurrence v left join cdm.person p on v.person_id = p.person_id
    where p.person_id is null;

    insert into work.dq
    select 'Foreign keys', 'Visits with invalid provider_id', 'must be 0', count(*)
    from cdm.visit_occurrence v left join cdm.provider p on v.provider_id = p.provider_id
    where v.provider_id is not null and p.provider_id is null;

    insert into work.dq
    select 'Foreign keys', 'Visits with invalid care_site_id', 'must be 0', count(*)
    from cdm.visit_occurrence v left join cdm.care_site c on v.care_site_id = c.care_site_id
    where v.care_site_id is not null and c.care_site_id is null;

    insert into work.dq
    select 'Foreign keys', 'Providers with invalid care_site_id', 'must be 0', count(*)
    from cdm.provider p left join cdm.care_site c on p.care_site_id = c.care_site_id
    where p.care_site_id is not null and c.care_site_id is null;

    insert into work.dq
    select 'Foreign keys', 'Persons with invalid care_site_id', 'must be 0', count(*)
    from cdm.person p left join cdm.care_site c on p.care_site_id = c.care_site_id
    where p.care_site_id is not null and c.care_site_id is null;

    insert into work.dq
    select 'Foreign keys', 'Conditions with invalid person_id', 'must be 0', count(*)
    from cdm.condition_occurrence c left join cdm.person p on c.person_id = p.person_id
    where p.person_id is null;

    insert into work.dq
    select 'Foreign keys', 'Conditions with invalid visit_occurrence_id', 'must be 0', count(*)
    from cdm.condition_occurrence c left join cdm.visit_occurrence v
        on c.visit_occurrence_id = v.visit_occurrence_id
    where c.visit_occurrence_id is not null and v.visit_occurrence_id is null;

    insert into work.dq
    select 'Foreign keys', 'Drugs with invalid person_id', 'must be 0', count(*)
    from cdm.drug_exposure d left join cdm.person p on d.person_id = p.person_id
    where p.person_id is null;

    insert into work.dq
    select 'Foreign keys', 'Drugs with invalid visit_occurrence_id', 'must be 0', count(*)
    from cdm.drug_exposure d left join cdm.visit_occurrence v
        on d.visit_occurrence_id = v.visit_occurrence_id
    where d.visit_occurrence_id is not null and v.visit_occurrence_id is null;

    insert into work.dq
    select 'Foreign keys', 'Deaths with invalid person_id', 'must be 0', count(*)
    from cdm.death d left join cdm.person p on d.person_id = p.person_id
    where p.person_id is null;

    insert into work.dq
    select 'Foreign keys', 'Persons without observation period', 'must be 0', count(*)
    from cdm.person p left join cdm.observation_period o on p.person_id = o.person_id
    where o.person_id is null;

    /* duplicated keys */
    insert into work.dq
    select 'Duplicates', 'Duplicated visit_occurrence_id', 'must be 0',
           count(*) - count(distinct visit_occurrence_id) from cdm.visit_occurrence;

    insert into work.dq
    select 'Duplicates', 'Duplicated condition_occurrence_id', 'must be 0',
           count(*) - count(distinct condition_occurrence_id) from cdm.condition_occurrence;

    insert into work.dq
    select 'Duplicates', 'Duplicated drug_exposure_id', 'must be 0',
           count(*) - count(distinct drug_exposure_id) from cdm.drug_exposure;

    insert into work.dq
    select 'Duplicates', 'Visits per encounter: more than 1', 'must be 0',
           count(*) - count(distinct visit_source_value) from cdm.visit_occurrence;

    /* CDM must not have more rows than raw */
    insert into work.dq
    select 'Row counts', 'Condition rows in CDM minus raw (must be <= 0)', 'must be 0',
           max(0, (select count(*) from cdm.condition_occurrence)
                - (select count(*) from raw.conditions))
    from (select 1 as x from raw.patients(obs=1));

    insert into work.dq
    select 'Row counts', 'Drug rows in CDM minus raw (must be <= 0)', 'must be 0',
           max(0, (select count(*) from cdm.drug_exposure)
                - (select count(*) from raw.medications))
    from (select 1 as x from raw.patients(obs=1));

    /* temporal logic */
    insert into work.dq
    select 'Dates', 'Visits where end_date < start_date', 'must be 0', count(*)
    from cdm.visit_occurrence where visit_end_date < visit_start_date;

    insert into work.dq
    select 'Dates', 'Conditions where end_date < start_date', 'must be 0', count(*)
    from cdm.condition_occurrence
    where condition_end_date is not null and condition_end_date < condition_start_date;

    insert into work.dq
    select 'Dates', 'Drugs where end_date < start_date', 'must be 0', count(*)
    from cdm.drug_exposure
    where drug_exposure_end_date < drug_exposure_start_date;

    insert into work.dq
    select 'Dates', 'Observation periods where end < start', 'must be 0', count(*)
    from cdm.observation_period
    where observation_period_end_date < observation_period_start_date;

    /* known Synthea data-quality finding: records dated after the death date */
    insert into work.dq
    select 'Synthea finding', 'Visits dated after the death date', 'info', count(*)
    from cdm.visit_occurrence v inner join cdm.death d on v.person_id = d.person_id
    where v.visit_start_date > d.death_date;

    insert into work.dq
    select 'Synthea finding', 'Conditions dated after the death date', 'info', count(*)
    from cdm.condition_occurrence c inner join cdm.death d on c.person_id = d.person_id
    where c.condition_start_date > d.death_date;

    insert into work.dq
    select 'Synthea finding', 'Drugs dated after the death date', 'info', count(*)
    from cdm.drug_exposure x inner join cdm.death d on x.person_id = d.person_id
    where x.drug_exposure_start_date > d.death_date;

    /* anything outside the observation period that is NOT explained by death */
    insert into work.dq
    select 'Observation period', 'Visits outside period, person not deceased', 'must be 0', count(*)
    from cdm.visit_occurrence v
    inner join cdm.observation_period o on v.person_id = o.person_id
    where (v.visit_start_date < o.observation_period_start_date
        or v.visit_start_date > o.observation_period_end_date)
      and v.person_id not in (select person_id from cdm.death);
quit;

title "B3: data quality checks";
proc sql;
    select check_group, check_description, expected, violations,
           case when expected = 'info' then 'INFO'
                when violations = 0 then 'PASS' else 'FAIL' end as status length=6
    from work.dq;
quit;

title "B4: visits by Synthea encounter class (wellness is a sensitivity analysis in script 09)";
proc sql;
    select encounter_class, count(*) as visits,
           calculated visits / (select count(*) from vocab.visit_class) as share format=percent8.1
    from vocab.visit_class
    group by encounter_class
    order by visits desc;
quit;

title;
