/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  02b_load_vocabulary_snomed.sas
* Purpose: Load the SNOMED part of the OMOP vocabulary (ATHENA download, filtered
*          with filter_snomed.py) into SAS datasets in the VOCAB library.
*          Run once, after 02_import_raw and before 05_transform_condition.
* Inputs:  vocab/snomed/CONCEPT.csv  (SNOMED rows only)
*          vocab/snomed/CONCEPT_RELATIONSHIP.csv  ('Maps to' rows only)
*          Both are tab-delimited.
* Output:  vocab.snomed_concept (keeps domain_id), vocab.snomed_maps_to
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* 1a. SNOMED concepts, with the domain_id column the drug import does not need */
data vocab.snomed_concept;
    infile "&project_path/vocab/snomed/CONCEPT.csv" lrecl=32767 firstobs=2 truncover termstr=LF;
    input;
    length concept_id 8 concept_name $255 domain_id $20 vocabulary_id $20
           concept_class_id $30 standard_concept $1 concept_code $50 invalid_reason $1;
    vocabulary_id = scan(_infile_, 4, '09'x, 'm');
    if vocabulary_id = 'SNOMED';
    concept_id       = input(scan(_infile_, 1, '09'x, 'm'), best32.);
    concept_name     = scan(_infile_, 2, '09'x, 'm');
    domain_id        = scan(_infile_, 3, '09'x, 'm');
    concept_class_id = scan(_infile_, 5, '09'x, 'm');
    standard_concept = scan(_infile_, 6, '09'x, 'm');
    concept_code     = strip(scan(_infile_, 7, '09'x, 'm'));
    invalid_reason   = compress(scan(_infile_, 10, '09'x, 'm'), '0D'x);
    keep concept_id concept_name domain_id concept_class_id standard_concept
         concept_code invalid_reason;
run;

/* 1b. Valid 'Maps to' links */
data vocab.snomed_maps_to;
    infile "&project_path/vocab/snomed/CONCEPT_RELATIONSHIP.csv" lrecl=32767 firstobs=2 truncover termstr=LF;
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

/* 1c. Checks: row counts and the domains present */
title "Check 1: SNOMED concepts by domain and standard flag";
proc sql;
    select domain_id, standard_concept, count(*) as concepts
    from vocab.snomed_concept
    group by domain_id, standard_concept
    order by concepts desc;
    select count(*) as snomed_concepts from vocab.snomed_concept;
    select count(*) as maps_to_rows    from vocab.snomed_maps_to;
quit;
title;
