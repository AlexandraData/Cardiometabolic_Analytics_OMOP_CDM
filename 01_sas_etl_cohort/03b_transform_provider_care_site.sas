/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  03b_transform_provider_care_site.sas
* Purpose: Load CDM.CARE_SITE (Synthea organizations.csv) and CDM.PROVIDER
*          (Synthea providers.csv).
* Needs:   01_create_tables and 02_import_raw run first.
* Order:   Run BEFORE 04: visits take provider_id and care_site_id from these
*          two tables.
* Notes:   IDs are numbered in order of the Synthea Id, so the same input always
*          gives the same IDs. The Synthea UUID is kept in *_source_value.
*          Place of service and specialty are not mapped to concepts (0).
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* ========================================================================== */
/* CARE_SITE                                                                   */
/* ========================================================================== */

proc sort data=raw.organizations out=work.org_sorted;
    by Id;
run;

data work.care_site_stage;
    length care_site_name $255 care_site_source_value $50
           place_of_service_source_value $50;
    set work.org_sorted;
    care_site_id                  = _n_;
    care_site_name                = strip(name);
    place_of_service_concept_id   = 0;
    location_id                   = .;
    care_site_source_value        = strip(Id);
    place_of_service_source_value = '';
    keep care_site_id care_site_name place_of_service_concept_id location_id
         care_site_source_value place_of_service_source_value;
run;

proc sql;
    delete from cdm.care_site;
quit;

proc append base=cdm.care_site data=work.care_site_stage force;
run;

/* ========================================================================== */
/* PROVIDER (care_site_id comes from the provider's organization)              */
/* ========================================================================== */

proc sql;
    create table work.provider_join as
    select strip(p.Id)         as provider_source_value length=50,
           strip(p.name)       as provider_name length=255,
           c.care_site_id,
           strip(p.gender)     as gender_source_value length=50,
           strip(p.speciality) as specialty_source_value length=50
    from raw.providers p
    left join cdm.care_site c
        on strip(p.organization) = c.care_site_source_value
    order by calculated provider_source_value;
quit;

data work.provider_stage;
    length npi $20 dea $20;
    set work.provider_join;
    provider_id = _n_;
    npi = '';
    dea = '';
    specialty_concept_id = 0;
    year_of_birth = .;
    select (upcase(strip(gender_source_value)));
        when ('M') gender_concept_id = 8507;   /* MALE */
        when ('F') gender_concept_id = 8532;   /* FEMALE */
        otherwise  gender_concept_id = 0;
    end;
    specialty_source_concept_id = 0;
    gender_source_concept_id    = 0;
    keep provider_id provider_name npi dea specialty_concept_id care_site_id
         year_of_birth gender_concept_id provider_source_value
         specialty_source_value specialty_source_concept_id
         gender_source_value gender_source_concept_id;
run;

proc sql;
    delete from cdm.provider;
quit;

proc append base=cdm.provider data=work.provider_stage force;
run;

/* ========================================================================== */
/* Checks                                                                      */
/* ========================================================================== */

title "Check 1: row counts (cdm must equal raw)";
proc sql;
    select (select count(*) from raw.organizations) as raw_organizations,
           (select count(*) from cdm.care_site)     as cdm_care_sites,
           (select count(*) from raw.providers)     as raw_providers,
           (select count(*) from cdm.provider)      as cdm_providers
    from (select 1 as x from raw.patients(obs=1));
quit;

title "Check 2: all three must be 0";
proc sql;
    select (select count(*) from cdm.provider where care_site_id is missing)
               as providers_without_care_site,
           (select count(*) - count(distinct provider_source_value) from cdm.provider)
               as duplicated_provider_ids,
           (select count(*) - count(distinct care_site_source_value) from cdm.care_site)
               as duplicated_care_site_ids
    from (select 1 as x from raw.patients(obs=1));
quit;

title "Check 3: first 10 care sites (names come from the Synthea file)";
proc print data=cdm.care_site(obs=10) noobs;
    var care_site_id care_site_name;
run;
title;
