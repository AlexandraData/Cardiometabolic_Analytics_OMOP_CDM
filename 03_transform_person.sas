proc sql;
    /* Clear any existing data in target */
    delete from cdm.person;

    /* Insert transformed records into cdm.person */
    insert into cdm.person (
        person_id,
        gender_concept_id,
        year_of_birth,
        month_of_birth,
        day_of_birth,
        birth_datetime,
        race_concept_id,
        ethnicity_concept_id,
        person_source_value,
        gender_source_value,
        gender_source_concept_id,
        race_source_value,
        race_source_concept_id,
        ethnicity_source_value,
        ethnicity_source_concept_id
    )
    select 
        monotonic() as person_id,
        case upcase(gender)
            when 'M' then 8507
            when 'F' then 8532
            else 0
        end as gender_concept_id,
        year(birthdate)  as year_of_birth,
        month(birthdate) as month_of_birth,
        day(birthdate)   as day_of_birth,
        dhms(birthdate, 0, 0, 0) as birth_datetime,
        case lowcase(race)
            when 'white' then 8527
            when 'black' then 8516
            when 'asian' then 8515
            else 0
        end as race_concept_id,
        case lowcase(ethnicity)
            when 'hispanic'    then 38003563
            when 'nonhispanic' then 38003564
            else 0
        end as ethnicity_concept_id,
        Id        as person_source_value,
        gender    as gender_source_value,
        0         as gender_source_concept_id,
        race      as race_source_value,
        0         as race_source_concept_id,
        ethnicity as ethnicity_source_value,
        0         as ethnicity_source_concept_id
    from raw.patients;
quit;

proc print data=cdm.person(obs=10);
    var person_id gender_concept_id year_of_birth month_of_birth race_concept_id person_source_value;
run;