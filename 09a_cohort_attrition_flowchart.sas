/*******************************************************************************
* Project: OMOP CDM v5.4 Synthea Migration & Analytics
* Script:  09a_cohort_attrition_flowchart.sas
* Purpose: Draw cohort attrition flowcharts (boxes for the patients who remain,
*          boxes on the right for those excluded, Y and N arrows) for the
*          cardiometabolic cohort (script 09) and the type 2 diabetes study (08).
* Needs:   08 and 09 run first (results.cohort_attrition, results.t2dm_attrition).
* Output:  two PNG images in omop_project/export (and in the SAS Results tab).
*
* How it works: PROC SGPLOT draws an empty chart and an annotation data set
*   (SGANNO) adds the rectangles, text and arrows. Each step needs two columns:
*   step_label and n (patients remaining after the step). The excluded number is
*   the difference with the previous step.
*   To add or rename a step, change the data set that feeds the macro.
********************************************************************************/

%let project_path = /home/u63767888/omop_project;
%include "&project_path/scripts/00_setup_libraries.sas";
libname results "&project_path/results";
options dlcreatedir;
libname expdir "&project_path/export";

%macro flowchart(data=, filename=, title=, height=700);
    %local nsteps;
    proc sql noprint;
        select count(*) into :nsteps trimmed from &data;
    quit;

    data work.anno;
        length function $12 label $200 anchor $12 drawspace $14
               textcolor linecolor fillcolor $20 display $8
               widthunit heightunit $12 direction $4;
        set &data(rename=(step_label=txt)) end=last;
        retain prev_n prev_bottom;

        drawspace = 'wallpercent';
        spacing   = 94 / &nsteps;
        bh        = spacing * 0.52;
        ytop      = 98 - (step - 1) * spacing;
        ybot      = ytop - bh;

        /* box for the patients who remain */
        function = 'rectangle'; x1 = 4; y1 = ytop; width = 46; height = bh;
        widthunit = 'percent'; heightunit = 'percent'; anchor = 'topleft';
        linecolor = 'black'; fillcolor = 'white'; display = 'all';
        textcolor = ''; label = ''; output;

        function = 'text'; x1 = 27; y1 = ytop - bh * 0.30; anchor = 'center';
        label = txt; textcolor = 'black'; textsize = 9; textweight = 'normal';
        width = 44; widthunit = 'percent'; height = .; output;

        function = 'text'; x1 = 27; y1 = ytop - bh * 0.74; anchor = 'center';
        label = 'n = ' || strip(put(n, comma10.)); textcolor = 'black';
        textsize = 10; textweight = 'bold'; width = 44; output;

        if step > 1 then do;
            ym   = (prev_bottom + ytop) / 2;
            ebh  = bh * 0.8;

            /* arrow down to this step, marked Y */
            function = 'arrow'; x1 = 27; y1 = prev_bottom; x2 = 27; y2 = ytop;
            direction = 'out'; linecolor = 'black'; linethickness = 1;
            label = ''; width = .; height = .; output;

            function = 'text'; x1 = 29.5; y1 = ym - 2; anchor = 'center';
            label = 'Y'; textcolor = 'black'; textsize = 8; textweight = 'normal';
            width = .; output;

            /* arrow to the box of the excluded, marked N */
            function = 'arrow'; x1 = 27; y1 = ym; x2 = 60; y2 = ym;
            direction = 'out'; linecolor = 'black'; linethickness = 1;
            label = ''; output;

            function = 'text'; x1 = 33; y1 = ym + 3; anchor = 'center';
            label = 'N'; textcolor = 'black'; textsize = 8; width = .; output;

            /* box of the excluded */
            function = 'rectangle'; x1 = 60; y1 = ym + ebh / 2; width = 36; height = ebh;
            widthunit = 'percent'; heightunit = 'percent'; anchor = 'topleft';
            linecolor = 'black'; fillcolor = 'white'; display = 'all';
            label = ''; output;

            function = 'text'; x1 = 78; y1 = ym + ebh * 0.17; anchor = 'center';
            label = 'Excluded'; textcolor = 'black'; textsize = 9; textweight = 'normal';
            width = 34; widthunit = 'percent'; height = .; output;

            function = 'text'; x1 = 78; y1 = ym - ebh * 0.17; anchor = 'center';
            label = 'n = ' || strip(put(prev_n - n, comma10.)); textsize = 10;
            textweight = 'bold'; output;
        end;

        prev_n      = n;
        prev_bottom = ybot;
    run;

    data work.blank;
        x = 0; y = 0;
    run;

    ods graphics / reset width=900px height=&height.px imagename="&filename" imagefmt=png;
    ods listing gpath="&project_path/export";
    title "&title";
    proc sgplot data=work.blank sganno=work.anno noautolegend noborder;
        scatter x=x y=y / markerattrs=(size=0);
        xaxis display=none min=0 max=100;
        yaxis display=none min=0 max=100;
    run;
    title;
    ods listing close;
%mend flowchart;

/* ========================================================================== */
/* Cardiometabolic cohort (script 09). Steps are applied one after the other.  */
/* results.cohort_attrition step 3 is a separate count, so step 4 is used.     */
/* ========================================================================== */

proc sql;
    create table work.flow_cardio as
    select 1 as step,
           'Patients with a cardiometabolic index diagnosis' as step_label length=120,
           patients as n
    from results.cohort_attrition where step = 1
    union all
    select 2, '365+ days of observation before the index date', patients
    from results.cohort_attrition where step = 2
    union all
    select 3, '365+ days of follow-up after the index date (healthcare use analysis)', patients
    from results.cohort_attrition where step = 4
    order by step;
quit;

%flowchart(data=work.flow_cardio, filename=flow_cardiometabolic,
           title=Cardiometabolic cohort: attrition, height=620);

/* ========================================================================== */
/* Type 2 diabetes study (script 08). The counts are already cumulative.       */
/* ========================================================================== */

proc sql;
    create table work.flow_t2dm as
    select step, description as step_label length=120, patients as n
    from results.t2dm_attrition
    order by step;
quit;

%flowchart(data=work.flow_t2dm, filename=flow_type2_diabetes,
           title=Type 2 diabetes study: attrition, height=760);
