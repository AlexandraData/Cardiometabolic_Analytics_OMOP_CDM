%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";

/* Macro to export datasets to CSV */
%macro export_csv(dataset=, filename=);
    proc export data=&dataset
        outfile="&project_path/export/&filename..csv"
        dbms=csv
        replace;
    run;
%mend export_csv;

/* 1. Core OMOP CDM Fact & Dimension Tables */
%export_csv(dataset=cdm.person,               filename=cdm_person);
%export_csv(dataset=cdm.visit_occurrence,     filename=cdm_visit_occurrence);
%export_csv(dataset=cdm.condition_occurrence, filename=cdm_condition_occurrence);
%export_csv(dataset=cdm.drug_exposure,        filename=cdm_drug_exposure);

/* 2. Processed Cohort Analytical Tables */
%export_csv(dataset=work.analytic_full,       filename=fact_cardio_cohort);
%export_csv(dataset=work.hru_raw,             filename=fact_hru_utilization);