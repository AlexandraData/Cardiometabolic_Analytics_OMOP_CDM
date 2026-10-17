%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

title1 "==================================================";
title2 "       OMOP CDM v5.4 DATA QUALITY REPORT          ";
title3 "==================================================";

/* Check 1: Record counts across Target Tables */
proc sql;
    title4 "1. Table Row Counts";
    select 'cdm.person' as table_name, count(*) as total_records from cdm.person
    union all
    select 'cdm.visit_occurrence', count(*) from cdm.visit_occurrence
    union all
    select 'cdm.condition_occurrence', count(*) from cdm.condition_occurrence
    union all
    select 'cdm.drug_exposure', count(*) from cdm.drug_exposure;
quit;

/* Check 2: Unmapped Standard Concept Rates (Completeness) */
proc sql;
    title4 "2. Unmapped Concepts (concept_id = 0)";
    select 
        'Conditions' as domain,
        count(*) as total_rows,
        sum(case when condition_concept_id = 0 then 1 else 0 end) as unmapped_rows,
        calculated unmapped_rows / calculated total_rows as unmapped_rate format=percent8.2
    from cdm.condition_occurrence
    union all
    select 
        'Drugs' as domain,
        count(*) as total_rows,
        sum(case when drug_concept_id = 0 then 1 else 0 end) as unmapped_rows,
        calculated unmapped_rows / calculated total_rows as unmapped_rate format=percent8.2
    from cdm.drug_exposure;
quit;

/* Check 3: Orphan Key Validation (Foreign Key Integrity) */
proc sql;
    title4 "3. Orphan Key Checks (Must Be 0)";
    select 
        'Visits with invalid person_id' as check_description,
        count(*) as violation_count
    from cdm.visit_occurrence v
    left join cdm.person p on v.person_id = p.person_id
    where p.person_id is null
    union all
    select 
        'Conditions with invalid visit_occurrence_id',
        count(*)
    from cdm.condition_occurrence c
    left join cdm.visit_occurrence v on c.visit_occurrence_id = v.visit_occurrence_id
    where c.visit_occurrence_id is not null and v.visit_occurrence_id is null;
quit;

/* Check 4: Temporal Plausibility (End Date < Start Date) */
proc sql;
    title4 "4. Temporal Logic Checks (Must Be 0)";
    select 
        'Visits where end_date < start_date' as check_description,
        count(*) as violation_count
    from cdm.visit_occurrence
    where visit_end_date < visit_start_date
    union all
    select 
        'Conditions where end_date < start_date',
        count(*)
    from cdm.condition_occurrence
    where condition_end_date is not null and condition_end_date < condition_start_date;
quit;

title;