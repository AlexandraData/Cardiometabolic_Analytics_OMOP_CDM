/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  06a_build_drug_class_map.sas   (version 4)
* Purpose: Build VOCAB.DRUG_CLASS_MAP from the OMOP vocabulary (ATHENA download):
*          Synthea RxNorm product code -> standard OMOP concept -> RxNorm
*          ingredient -> ATC class. Keeps drugs in ATC groups A10, B01, C01-C10
*          (C05 excluded: vasoprotectives such as haemorrhoid creams).
* Run order: 02c_load_vocabulary_rxnorm_atc -> 06_transform_drug -> 06a (this script).
* Inputs:  vocab.concept, vocab.concept_ancestor, vocab.drug_crosswalk, cdm.drug_exposure
* Output:  vocab.drug_class_map  (one row per Synthea drug code)
* Changes v2: ATC code chosen by ingredient-name match (fixes verapamil),
*          C05 excluded, short dashboard label added (drug_class), official ATC
*          4th-level name kept (atc_class), insulin premix override,
*          Review 4 (ATC candidates) and diagnostic for captopril.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";
libname vocab "&project_path/vocab";   /* also add this line to 00_setup_libraries.sas */

/* ========================================================================== */
/* STEPS 1-3: moved out of this script.                                        */
/* - Vocabulary import:  02c_load_vocabulary_rxnorm_atc.sas                               */
/* - Code -> standard concept crosswalk (incl. captopril fix): 06_transform_   */
/*   drug.sas, stored in vocab.drug_crosswalk. Here we only add patient counts. */
/* ========================================================================== */

proc sql;
    create table work.src_codes as
    select strip(drug_source_value) as source_code length=20,
           count(distinct person_id) as patients
    from cdm.drug_exposure
    group by calculated source_code;

    create table work.code_to_std as
    select x.source_code, x.description,
           coalesce(s.patients, 0) as patients,
           x.source_concept_id, x.std_concept_id
    from vocab.drug_crosswalk x
    left join work.src_codes s
        on x.source_code = s.source_code;
quit;

/* ========================================================================== */
/* STEP 4: ATC 5th-level candidates for each product, in the selected groups   */
/* Selected groups: A10, B01, C01-C10 except C05.                              */
/* The ancestor table links every product to its ingredient and ATC classes.   */
/* ========================================================================== */

proc sql;
    create table work.code_atc as
    select t.source_code, t.std_concept_id,
           a5.concept_code as atc_code length=8,
           a5.concept_name as atc_name length=255
    from work.code_to_std t
    inner join vocab.concept_ancestor a
        on a.descendant_concept_id = t.std_concept_id
    inner join vocab.concept a5
        on  a5.concept_id = a.ancestor_concept_id
        and a5.vocabulary_id = 'ATC'
        and a5.concept_class_id = 'ATC 5th'
    where substr(a5.concept_code, 1, 3) in ('A10', 'B01')
       or (substr(a5.concept_code, 1, 1) = 'C'
           and substr(a5.concept_code, 2, 2) between '01' and '10'
           and substr(a5.concept_code, 2, 2) ne '05');
quit;

/* ========================================================================== */
/* STEP 5: RxNorm ingredient for each product                                  */
/* n_ingredients > 1 = combination product (e.g. insulin 70/30): review.       */
/* ========================================================================== */

proc sql;
    create table work.code_ingr as
    select t.source_code,
           min(i.concept_id) as ingredient_concept_id,
           count(distinct i.concept_id) as n_ingredients
    from (select distinct source_code, std_concept_id from work.code_atc) t
    inner join vocab.concept_ancestor a
        on a.descendant_concept_id = t.std_concept_id
    inner join vocab.concept i
        on  i.concept_id = a.ancestor_concept_id
        and i.vocabulary_id = 'RxNorm'
        and i.concept_class_id = 'Ingredient'
        and i.standard_concept = 'S'
    group by t.source_code;
quit;

/* ========================================================================== */
/* STEP 5b: Choose ONE ATC code per product                                    */
/* A product can sit under several ATC codes (e.g. verapamil, nitroglycerin).  */
/* Rule: prefer the ATC code whose name matches the ingredient name (ATC names */
/* look like 'verapamil; oral'), otherwise the lowest code.                    */
/* ========================================================================== */

proc sql;
    create table work.code_atc_rank as
    select x.source_code, x.std_concept_id, x.atc_code, x.atc_name,
           (lowcase(strip(scan(x.atc_name, 1, ';'))) = lowcase(strip(ing.concept_name)))
               as name_match
    from work.code_atc x
    left join work.code_ingr g
        on x.source_code = g.source_code
    left join vocab.concept ing
        on ing.concept_id = g.ingredient_concept_id;

    create table work.n_atc as
    select source_code, count(distinct atc_code) as n_atc
    from work.code_atc
    group by source_code;
quit;

proc sort data=work.code_atc_rank;
    by source_code descending name_match atc_code;
run;

data work.code_atc_pick;
    set work.code_atc_rank;
    by source_code;
    if first.source_code;
    /* manual override: 70/30 insulin premix is two ingredients (verify in WHO ATC index) */
    if source_code = '106892' then atc_code = 'A10AD01';
    keep source_code std_concept_id atc_code;
run;

proc sql;
    create table work.code_atc_one as
    select p.source_code, p.std_concept_id, p.atc_code, n.n_atc
    from work.code_atc_pick p
    left join work.n_atc n
        on p.source_code = n.source_code;
quit;

/* ========================================================================== */
/* STEP 6: Assemble the map                                                    */
/* atc_class = official ATC 4th-level name; drug_class = short dashboard label */
/* ========================================================================== */

proc sql;
    create table work.map_build as
    select a.source_code, t.description, t.patients, a.std_concept_id,
           g.ingredient_concept_id, g.n_ingredients,
           ing.concept_name as ingredient length=100,
           ing.concept_code as rxnorm_ingredient_code length=20,
           a.atc_code, a.n_atc,
           c4.concept_code as atc_l4_code length=5,
           c4.concept_name as atc_class length=100
    from work.code_atc_one a
    inner join work.code_to_std t
        on a.source_code = t.source_code
    left join work.code_ingr g
        on a.source_code = g.source_code
    left join vocab.concept ing
        on ing.concept_id = g.ingredient_concept_id
    left join vocab.concept c4
        on  c4.vocabulary_id = 'ATC'
        and c4.concept_class_id = 'ATC 4th'
        and c4.concept_code = substr(a.atc_code, 1, 5);
quit;

/* Flags:
   - Every row is a drug in the selected ATC groups.
   - core_flag = 1 marks the classes used to define INITIAL TREATMENT for
     diabetes / hypertension / coronary disease. Other rows (loop diuretics,
     anticoagulants, glycosides, antiarrhythmics, acute-care drugs...) stay in
     the map for comparison but are not counted as initial treatment.
   - class_priority: lower number wins a same-day tie (99 = not core).
   Adjust the lists below if you decide differently. */
data vocab.drug_class_map;
    set work.map_build;
    length p3 $3 p4 $4 p5 $5 drug_class $30;
    p3 = substr(atc_code, 1, 3);
    p4 = substr(atc_code, 1, 4);
    p5 = substr(atc_code, 1, 5);

    if      p3 = 'A10'                 then class_priority = 1;   /* diabetes drugs */
    else if p4 in ('C09A', 'C09B')     then class_priority = 2;   /* ACE inhibitors */
    else if p4 in ('C09C', 'C09D')     then class_priority = 3;   /* ARBs */
    else if p3 = 'C08'                 then class_priority = 4;   /* calcium channel blockers */
    else if p4 in ('C03A', 'C03B')     then class_priority = 5;   /* thiazide and thiazide-like */
    else if p3 = 'C07'                 then class_priority = 6;   /* beta blockers */
    else if p3 = 'C10'                 then class_priority = 7;   /* lipid-modifying (statins) */
    else if p5 = 'B01AC'               then class_priority = 8;   /* antiplatelets */
    else if p5 = 'C01DA'               then class_priority = 9;   /* nitrates */
    else if p3 = 'C02'                 then class_priority = 10;  /* other antihypertensives */
    else                                    class_priority = 99;

    core_flag = (class_priority < 99);

    /* readable ingredient labels for the two combination products */
    if source_code = '106892'  then ingredient = 'insulin human (isophane + regular)';
    if source_code = '1656354' then ingredient = 'sacubitril + valsartan';

    select (class_priority);
        when (1)  drug_class = 'Diabetes drugs';
        when (2)  drug_class = 'ACE inhibitors';
        when (3)  drug_class = 'ARBs';
        when (4)  drug_class = 'Calcium channel blockers';
        when (5)  drug_class = 'Thiazide diuretics';
        when (6)  drug_class = 'Beta blockers';
        when (7)  drug_class = 'Statins';
        when (8)  drug_class = 'Antiplatelets';
        when (9)  drug_class = 'Nitrates';
        when (10) drug_class = 'Other antihypertensives';
        otherwise drug_class = 'Other cardiovascular';
    end;
    drop p3 p4 p5;
run;

proc sort data=vocab.drug_class_map;
    by class_priority ingredient source_code;
run;

/* ========================================================================== */
/* STEP 7: Review (send these outputs back to check before using the map)      */
/* ========================================================================== */

title "Review 1: Synthea drug codes with NO standard RxNorm concept";
proc sql outobs=100;
    select source_code, description, patients
    from work.code_to_std
    where std_concept_id is missing
    order by patients desc;
quit;

title "Review 2: Drug codes kept in the selected ATC groups";
proc print data=vocab.drug_class_map noobs;
    var source_code description ingredient atc_code atc_class drug_class
        core_flag class_priority n_ingredients n_atc patients;
run;

title "Review 3: Mapped codes in NO selected ATC group (confirm nothing cardiometabolic is missing)";
proc sql outobs=100;
    select t.source_code, t.description, t.patients
    from work.code_to_std t
    left join vocab.drug_class_map m
        on t.source_code = m.source_code
    where m.source_code is missing
      and t.std_concept_id is not missing
    order by t.patients desc;
quit;

title "Review 4: Products with several ATC candidates (the first row per code is the one kept)";
proc sql;
    select r.source_code, t.description, r.atc_code, r.atc_name, r.name_match
    from work.code_atc_rank r
    inner join work.code_to_std t
        on r.source_code = t.source_code
    where r.source_code in (select source_code from work.n_atc where n_atc > 1)
    order by r.source_code, r.name_match desc, r.atc_code;
quit;

/* Review 5: code/description mismatch check for ALL Synthea drug codes.
   A code is flagged when none of the RxNorm ingredients of its standard concept
   (first word of the ingredient name) appears in Synthea's description.
   Brand packs such as 'Jolivette 28 Day Pack' are expected false positives. */
proc sql;
    create table work.qc_names as
    select t.source_code, t.description, t.patients,
           c.concept_name as rxnorm_name length=255,
           max(case when i.concept_id is not missing
                     and index(lowcase(t.description),
                               strip(lowcase(scan(i.concept_name, 1, ' ,/')))) > 0
                    then 1 else 0 end) as ingredient_found
    from work.code_to_std t
    inner join vocab.concept c
        on c.concept_id = t.std_concept_id
    left join vocab.concept_ancestor a
        on a.descendant_concept_id = t.std_concept_id
    left join vocab.concept i
        on  i.concept_id = a.ancestor_concept_id
        and i.vocabulary_id = 'RxNorm'
        and i.concept_class_id = 'Ingredient'
    group by t.source_code, t.description, t.patients, c.concept_name;
quit;

title "Review 5: Synthea description does not contain the RxNorm ingredient (possible code mismatch)";
proc sql outobs=100;
    select source_code, description as synthea_description, rxnorm_name, patients
    from work.qc_names
    where ingredient_found = 0
    order by patients desc;
quit;
title;

/* ========================================================================== */
/* STEP 8 (only if needed): Diagnostic for captopril (code 833036)             */
/* Captopril was mapped to a standard concept but found no ATC group.          */
/* ========================================================================== */

title "Diagnostic 1: standard concept used for Synthea code 833036";
proc sql;
    select t.source_code, t.std_concept_id, c.concept_name, c.concept_class_id,
           c.vocabulary_id, c.standard_concept
    from work.code_to_std t
    left join vocab.concept c
        on c.concept_id = t.std_concept_id
    where t.source_code = '833036';
quit;

title "Diagnostic 2: all ATC and ingredient ancestors of that concept";
proc sql;
    select c.vocabulary_id, c.concept_class_id, c.concept_code, c.concept_name
    from vocab.concept_ancestor a
    inner join vocab.concept c
        on c.concept_id = a.ancestor_concept_id
    where a.descendant_concept_id in
          (select std_concept_id from work.code_to_std where source_code = '833036')
    order by c.vocabulary_id, c.concept_class_id;
quit;
title;

/* Using the map in 09 (initial-drug step): replace work.drug_class_map with
   vocab.drug_class_map and keep the condition  m.core_flag = 1  */
