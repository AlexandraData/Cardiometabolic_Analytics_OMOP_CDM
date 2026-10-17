
/* Import Patients */
proc import datafile="&project_path/raw/patients.csv"
    out=raw.patients
    dbms=csv
    replace;
    guessingrows=max;
run;

/* Import Encounters */
proc import datafile="&project_path/raw/encounters.csv"
    out=raw.encounters
    dbms=csv
    replace;
    guessingrows=max;
run;

/* Import Conditions */
proc import datafile="&project_path/raw/conditions.csv"
    out=raw.conditions
    dbms=csv
    replace;
    guessingrows=max;
run;

/* Import Medications */
proc import datafile="&project_path/raw/medications.csv"
    out=raw.medications
    dbms=csv
    replace;
    guessingrows=max;
run;