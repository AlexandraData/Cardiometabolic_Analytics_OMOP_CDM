/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  10_export_to_powerbi.sas   (version 2)
* Purpose: Export the CDM tables, the analysis tables and the lookup tables to
*          CSV files for Power BI.
* Needs:   03 ... 09 run first (09 and 06c create the tables in the results library).
* Output:  omop_project/export/*.csv  (the folder is created if it is missing)
*
* Why version 2:
*   - The old script exported work.analytic_full and work.hru_raw, which disappear
*     when the SAS session ends; they now come from the results library.
*   - Added: death, observation_period, care_site, provider (Power BI had empty
*     provider and organization tables), the condition flags, drug class and
*     visit class lookups, and the cohort attrition table.
*   - Dates are written as 2026-10-24 and datetimes as 2026-10-24T00:00:00, so
*     Power BI reads them as dates without a conversion step.
*   - The log shows the number of rows written to each file.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

options dlcreatedir;
libname expdir "&project_path/export";   /* creates the folder if needed */

%macro export_csv(dataset=, filename=);
    %local lib mem dvars dtvars nobs;
    %let lib = %upcase(%scan(&dataset, 1, .));
    %let mem = %upcase(%scan(&dataset, 2, .));

    proc sql noprint;
        select name into :dvars separated by ' '
        from dictionary.columns
        where libname = "&lib" and memname = "&mem"
          and upcase(format) like 'DATE%' and upcase(format) not like 'DATETIME%';

        select name into :dtvars separated by ' '
        from dictionary.columns
        where libname = "&lib" and memname = "&mem"
          and upcase(format) like 'DATETIME%';

        select count(*) into :nobs trimmed from &dataset;
    quit;

    data work._export;
        set &dataset;
        %if %length(&dvars)  %then %do; format &dvars yymmdd10.; %end;
        %if %length(&dtvars) %then %do; format &dtvars e8601dt19.; %end;
    run;

    proc export data=work._export
        outfile="&project_path/export/&filename..csv"
        dbms=csv
        replace;
    run;

    %put NOTE: &filename..csv written with &nobs rows (from &dataset);
%mend export_csv;

/* 1. OMOP CDM tables */
%export_csv(dataset=cdm.person,               filename=cdm_person);
%export_csv(dataset=cdm.death,                filename=cdm_death);
%export_csv(dataset=cdm.observation_period,   filename=cdm_observation_period);
%export_csv(dataset=cdm.care_site,            filename=cdm_care_site);
%export_csv(dataset=cdm.provider,             filename=cdm_provider);
%export_csv(dataset=cdm.visit_occurrence,     filename=cdm_visit_occurrence);
%export_csv(dataset=cdm.condition_occurrence, filename=cdm_condition_occurrence);
%export_csv(dataset=cdm.drug_exposure,        filename=cdm_drug_exposure);

/* 2. Cardiometabolic cohort (script 09) */
%export_csv(dataset=results.analytic_full,    filename=fact_cardio_cohort);
%export_csv(dataset=results.hru_raw,           filename=fact_hru_utilization);
%export_csv(dataset=results.hru_long,          filename=fact_hru_long);
%export_csv(dataset=results.cohort_attrition,  filename=fact_cohort_attrition);

/* 3. Condition flags (script 06c) */
%export_csv(dataset=results.patient_condition_flags,  filename=fact_condition_flags);
%export_csv(dataset=results.patient_condition_events, filename=fact_condition_events);
%export_csv(dataset=results.condition_group_dim,      filename=dim_condition_group);

/* 4. Lookups */
%export_csv(dataset=vocab.drug_class_map,     filename=dim_drug_class);
%export_csv(dataset=vocab.visit_class,        filename=dim_visit_class);

/* 5. Type 2 diabetes study (script 08) */
%export_csv(dataset=results.t2dm_attrition,   filename=fact_t2dm_attrition);
%export_csv(dataset=results.t2dm_cohort,      filename=fact_t2dm_cohort);
%export_csv(dataset=results.t2dm_hru,         filename=fact_t2dm_hru);

proc datasets library=work nolist;
    delete _export;
quit;
