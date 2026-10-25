/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  06c_build_condition_groups.sas   (version 4)
* Purpose: Flag, for every patient, 16 cardiometabolic conditions, each belonging
*          to one of three major groups, so Power BI can show them.
*
*   Cardiovascular Diseases:
*     Heart Attack (MI), Cardiac Arrest, Stroke, Coronary Artery Disease, Heart Failure
*   Metabolic Disorders:
*     Type 2 Diabetes, Insulin Resistance, Obesity, Diabetic Complications
*     (retinopathy, neuropathy), Hyperglycemia, plus Prediabetes (part of the
*     cohort definition) and Metabolic Syndrome (nearest code to insulin resistance)
*   Related Cardiometabolic Conditions:
*     Hypertension, Dyslipidemia, NAFLD, Kidney Disease
*
* Needs:   05_transform_condition (vocab.condition_crosswalk, cdm.condition_occurrence)
*          and the folder omop_project/results.
* Output:  vocab.condition_group_map        source code -> condition and major group
*          results.condition_group_dim      the groups, with their number of codes
*          results.patient_condition_events one row per patient and condition
*                                           (first date, number of records)  [long]
*          results.patient_condition_flags  one row per patient: a 0/1 flag and a
*                                           first date per condition, and a 0/1
*                                           flag per major group              [wide]
*
* Method:  Each SNOMED code that script 05 loaded is assigned to a condition by
*          text rules on its OMOP standard concept name (Synthea description if
*          the code has no standard concept). The rules are in the table below
*          and are easy to change. Kidney complications of diabetes ("Disorder of
*          kidney due to diabetes mellitus") belong to Kidney Disease, not to
*          Diabetic Complications.
*          Heart attack, cardiac arrest and heart failure are three separate
*          conditions, each on its own line.
*          Reviews 1-4 show what was assigned, what is empty and what is left.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";
libname results "&project_path/results";

/* ========================================================================== */
/* Step 1: Rules. Columns: order ~ major group ~ condition ~ words to include  */
/* ~ words to exclude (regular expressions, not case sensitive, with | )       */
/* ========================================================================== */

data work.group_rules;
    infile datalines dlm='~' dsd truncover;
    input group_order major_group :$40. condition_group :$50. include_pattern :$300. exclude_pattern :$300.;
datalines;
1~Cardiovascular Diseases~Heart Attack (MI)~myocardial infarction|heart attack~old myocardial|history of
2~Cardiovascular Diseases~Cardiac Arrest~cardiac arrest~history of
3~Cardiovascular Diseases~Stroke~stroke|cerebral infarction|cerebrovascular accident~history of
4~Cardiovascular Diseases~Coronary Artery Disease~coronary arteriosclerosis|coronary heart disease|coronary atherosclerosis|coronary artery disease|ischemic heart disease~history of|bypass|graft
5~Cardiovascular Diseases~Heart Failure~heart failure|cardiac failure~history of
6~Metabolic Disorders~Type 2 Diabetes~^type 2 diabetes mellitus$~
7~Metabolic Disorders~Insulin Resistance~insulin resistance~
8~Metabolic Disorders~Obesity~obes~history of
9~Metabolic Disorders~Diabetic Complications~retinopathy|neuropathy|macular edema~
10~Metabolic Disorders~Hyperglycemia~hyperglycemi~
11~Metabolic Disorders~Prediabetes~prediabetes~
12~Metabolic Disorders~Metabolic Syndrome~metabolic syndrome~
13~Related Cardiometabolic Conditions~Hypertension~hypertension|hypertensive~pulmonary|pregnan|gestation|eclampsia|ocular|intracranial|portal|history of|kidney|renal
14~Related Cardiometabolic Conditions~Dyslipidemia~hyperlipid|dyslipid|hypercholesterol|hypertriglycerid|lipidemia~
15~Related Cardiometabolic Conditions~NAFLD~fatty liver|steatohepatitis|nonalcoholic|non-alcoholic~
16~Related Cardiometabolic Conditions~Kidney Disease~kidney disease|disorder of kidney|renal disease|nephropathy|renal failure|kidney failure|end-stage renal|end stage renal|renal impairment|albuminuria|proteinuria|glomerul|nephrotic~acute|stone|infection|history of
;
run;

/* ========================================================================== */
/* Step 2: Assign each loaded code to its condition(s)                         */
/* ========================================================================== */

proc sql;
    create table work.cond_text as
    select source_code,
           coalescec(std_concept_name, description) as match_text length=255
    from vocab.condition_crosswalk
    where load_flag = 1;

    create table work.group_hits as
    select t.source_code, r.group_order, r.major_group, r.condition_group
    from work.cond_text t, work.group_rules r
    where prxmatch(cats('/', strip(r.include_pattern), '/i'), t.match_text) > 0
      and (r.exclude_pattern = ''
           or prxmatch(cats('/', strip(r.exclude_pattern), '/i'), t.match_text) = 0);
quit;

/* The seven cohort codes always keep their condition, whatever the wording */
data work.cohort_group_codes;
    length source_code $20;
    input source_code $ group_order;
datalines;
44054006 6
15777000 11
38341003 13
59621000 13
53741008 4
55822004 14
302870006 14
;
run;

proc sql;
    create table work.forced_hits as
    select c.source_code, r.group_order, r.major_group, r.condition_group
    from work.cohort_group_codes c
    inner join work.group_rules r on c.group_order = r.group_order;

    create table vocab.condition_group_map as
    select distinct source_code, group_order, major_group, condition_group
    from (select * from work.group_hits
          union all
          select * from work.forced_hits)
    order by group_order, source_code;

    create table results.condition_group_dim as
    select r.group_order, r.major_group, r.condition_group,
           count(distinct m.source_code) as codes_in_group
    from work.group_rules r
    left join vocab.condition_group_map m on r.group_order = m.group_order
    group by r.group_order, r.major_group, r.condition_group
    order by r.group_order;
quit;

/* ========================================================================== */
/* Step 3: Patient-level tables                                                */
/* ========================================================================== */

proc sql;
    /* long: one row per patient and condition */
    create table results.patient_condition_events as
    select o.person_id,
           m.group_order,
           m.major_group,
           m.condition_group,
           min(o.condition_start_date) as first_date format=date9.,
           count(*) as records
    from cdm.condition_occurrence o
    inner join vocab.condition_group_map m
        on o.condition_source_value = m.source_code
    group by o.person_id, m.group_order, m.major_group, m.condition_group;
quit;

/* wide: one row per patient (all 1,163): flag + first date per condition,
   and a flag per major group. Column names follow the order above. */
%let flag_names = heart_attack cardiac_arrest stroke coronary_artery_disease heart_failure
                  type2_diabetes insulin_resistance obesity diabetic_complications
                  hyperglycemia prediabetes metabolic_syndrome
                  hypertension dyslipidemia nafld kidney_disease;

%macro build_flags;
    %local i n nm;
    %let n = %sysfunc(countw(&flag_names));
    proc sql;
        create table results.patient_condition_flags as
        select p.person_id
        %do i = 1 %to &n;
            %let nm = %scan(&flag_names, &i);
            , max(case when e.group_order = &i then 1 else 0 end) as &nm
        %end;
        %do i = 1 %to &n;
            %let nm = %scan(&flag_names, &i);
            , min(case when e.group_order = &i then e.first_date end) as &nm._date format=date9.
        %end;
        , max(case when e.major_group = 'Cardiovascular Diseases' then 1 else 0 end)
              as any_cardiovascular
        , max(case when e.major_group = 'Metabolic Disorders' then 1 else 0 end)
              as any_metabolic
        , max(case when e.major_group = 'Related Cardiometabolic Conditions' then 1 else 0 end)
              as any_related
        , count(distinct e.group_order) as n_conditions
        from cdm.person p
        left join results.patient_condition_events e
            on p.person_id = e.person_id
        group by p.person_id;
    quit;
%mend build_flags;
%build_flags

/* ========================================================================== */
/* Reviews                                                                     */
/* ========================================================================== */

title "Review 1: codes assigned to each condition (check every line makes clinical sense)";
proc sql;
    select m.group_order, m.condition_group, m.source_code,
           coalescec(x.std_concept_name, x.description) as concept_name length=70,
           count(o.person_id) as records,
           count(distinct o.person_id) as patients
    from vocab.condition_group_map m
    inner join vocab.condition_crosswalk x on m.source_code = x.source_code
    left join cdm.condition_occurrence o on o.condition_source_value = m.source_code
    group by m.group_order, m.condition_group, m.source_code, calculated concept_name
    order by m.group_order, patients desc;
quit;

title "Review 2: patients per condition (a condition with 0 codes has no matching code in this dataset)";
proc sql;
    select d.group_order, d.major_group, d.condition_group, d.codes_in_group,
           (select count(distinct e.person_id) from results.patient_condition_events e
            where e.group_order = d.group_order) as patients,
           calculated patients / (select count(*) from cdm.person) as prevalence format=percent8.1
    from results.condition_group_dim d
    order by d.group_order;
quit;

title "Review 2b: patients with at least one condition in each major group";
proc sql;
    select count(*) as patients,
           sum(any_cardiovascular) as cardiovascular,
           sum(any_metabolic)      as metabolic,
           sum(any_related)        as related,
           sum(n_conditions = 0)   as none_of_them
    from results.patient_condition_flags;
quit;

title "Review 3: loaded codes NOT in any condition, most frequent first (look for missed cardiometabolic conditions)";
proc sql;
    create table work.unassigned_codes as
    select o.condition_source_value as source_code,
           coalescec(x.std_concept_name, x.description) as concept_name length=70,
           count(distinct o.person_id) as patients
    from cdm.condition_occurrence o
    inner join vocab.condition_crosswalk x on o.condition_source_value = x.source_code
    where o.condition_source_value not in (select source_code from vocab.condition_group_map)
    group by o.condition_source_value, calculated concept_name
    order by patients desc;
quit;
proc print data=work.unassigned_codes(obs=60) noobs; run;

title "Review 4: loaded codes NOT in any condition whose name contains a cardiometabolic keyword";
proc sql;
    select o.condition_source_value as source_code,
           coalescec(x.std_concept_name, x.description) as concept_name length=70,
           count(distinct o.person_id) as patients
    from cdm.condition_occurrence o
    inner join vocab.condition_crosswalk x on o.condition_source_value = x.source_code
    where o.condition_source_value not in (select source_code from vocab.condition_group_map)
      and prxmatch('/diab|glyc|insulin|renal|kidney|nephr|cardi|heart|coronary|angina|athero|vascular|liver|hepat|lipid|cholest|obes|weight|stroke|infarct|ischem|hypert|hypot|thrombo|embol|aneurysm/i',
                   calculated concept_name) > 0
    group by o.condition_source_value, calculated concept_name
    order by patients desc;
quit;
title;
