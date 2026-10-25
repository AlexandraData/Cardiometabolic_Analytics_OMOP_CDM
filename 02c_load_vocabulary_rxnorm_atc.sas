/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  02c_load_vocabulary_rxnorm_atc.sas
* Purpose: Load the OMOP vocabulary files downloaded from ATHENA (RxNorm and ATC)
*          into SAS datasets in the VOCAB library. Run once, before 06.
* Inputs:  vocab/CONCEPT.csv, vocab/CONCEPT_ANCESTOR.csv,
*          vocab/CONCEPT_RELATIONSHIP.csv   (tab-delimited)
* Output:  vocab.concept, vocab.concept_ancestor, vocab.maps_to
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";
libname vocab "&project_path/vocab";   /* also add this line to 00_setup_libraries.sas */

/* Fields are read with SCAN(..., 'm') so empty fields stay empty and quote    */
/* characters inside concept names cannot break the parsing.                  */

/* 1a. CONCEPT: keep only the two vocabularies we need */
data vocab.concept;
    infile "&project_path/vocab/CONCEPT.csv" lrecl=32767 firstobs=2 truncover termstr=LF;
    input;
    length concept_id 8 concept_name $255 vocabulary_id $20 concept_class_id $20
           standard_concept $1 concept_code $50 invalid_reason $1;
    vocabulary_id = scan(_infile_, 4, '09'x, 'm');
    if vocabulary_id in ('RxNorm', 'ATC');
    concept_id       = input(scan(_infile_, 1, '09'x, 'm'), best32.);
    concept_name     = scan(_infile_, 2, '09'x, 'm');
    concept_class_id = scan(_infile_, 5, '09'x, 'm');
    standard_concept = scan(_infile_, 6, '09'x, 'm');
    concept_code     = strip(scan(_infile_, 7, '09'x, 'm'));
    invalid_reason   = compress(scan(_infile_, 10, '09'x, 'm'), '0D'x);
run;

/* 1b. CONCEPT_ANCESTOR: ancestor_concept_id, descendant_concept_id (columns 1-2) */
data vocab.concept_ancestor;
    infile "&project_path/vocab/CONCEPT_ANCESTOR.csv" lrecl=32767 firstobs=2 truncover termstr=LF;
    input;
    ancestor_concept_id   = input(scan(_infile_, 1, '09'x, 'm'), best32.);
    descendant_concept_id = input(scan(_infile_, 2, '09'x, 'm'), best32.);
run;

/* 1c. CONCEPT_RELATIONSHIP: keep only valid 'Maps to' links */
data vocab.maps_to;
    infile "&project_path/vocab/CONCEPT_RELATIONSHIP.csv" lrecl=32767 firstobs=2 truncover termstr=LF;
    input;
    length relationship_id $40 invalid_reason $20;
    relationship_id = scan(_infile_, 3, '09'x, 'm');
    if relationship_id = 'Maps to';
    invalid_reason = compress(scan(_infile_, 6, '09'x, 'm'), '0D'x);
    if invalid_reason = '';
    concept_id_1 = input(scan(_infile_, 1, '09'x, 'm'), best32.);
    concept_id_2 = input(scan(_infile_, 2, '09'x, 'm'), best32.);
    keep concept_id_1 concept_id_2;
run;

/* 1d. Sanity checks: expect 'ATC 1st' ... 'ATC 5th' and RxNorm 'Ingredient' rows */
title "Check 1: concepts loaded by vocabulary and class";
proc sql;
    select vocabulary_id, concept_class_id, count(*) as n
    from vocab.concept
    group by vocabulary_id, concept_class_id
    order by vocabulary_id, concept_class_id;
    select count(*) as ancestor_rows from vocab.concept_ancestor;
    select count(*) as maps_to_rows  from vocab.maps_to;
quit;
title;
