import os
import sqlalchemy as alchemy

# Optional: load variables from a local .env file if python-dotenv is installed.
# This keeps credentials out of source control -- see .env.example for the
# variables this module expects.
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# Query to get Newborn Cohort Dataset
def get_newborn_cohort_query():
    query = """SELECT subject_id, hadm_id, stay_id, dob, deathtime, outcome
                      , gender, ethnicity, insurance, language
                      , admission_type, admission_location, admission_count
                      , icu_stay, icu_stay_count, diagnoses_count, heart_rate
                      , respiratory_rate, o2_saturation, pressure_blood_mean
                      , pressure_blood_systolic, pressure_blood_diastolic
                      , temperature_fahrenheit, weight_admission, glucose
                      , hemoglobine, sodium, potassium, noionized_calcium
                      , magnesium, chloride, bicarbonate, phosphorus, creatine
                      , hematrocit, lactic_acid, apnea_interval, gcs_eye_opening
                      , gcs_verbal_response,gcs_motor_response, richmond_ras_scale
                      , peep_set, height, anion_gap
                      , gdg_01, gdg_02, gdg_03, gdg_04, gdg_05, gdg_06, gdg_07
                      , gdg_08, gdg_09, gdg_10, gdg_11, gdg_12, gdg_13, gdg_14
                      , gdg_15, gdg_16, gdg_17, gdg_18, gdg_19, gdg_20, gdg_21
                      , gdg_22, gdg_23, gdg_24, gdg_25, gdg_26, gdg_27, gdg_28
                      , gdg_29, gdg_30, gdg_31, gdg_32, gdg_33, gdg_34, gdg_35
                      , gdg_36, gdg_37, gdg_38, gdg_39, gdg_40, gdg_41, gdg_42
                      , gdg_43, gdg_44, gdg_45, gdg_46, gdg_47, gdg_48, gdg_49
                      , gdg_50, gdg_51, gdg_52, gdg_53, gdg_54, gdg_55, gdg_56
                      , gdg_57, gdg_58, gdg_59, gdg_60, gdg_61, gdg_62, gdg_63
                      , gdg_64, gdg_65, gdg_66, gdg_67, gdg_68, gdg_69, gdg_70
                      , gdg_71, gdg_72, gdg_73, gdg_74, gdg_75, gdg_76, gdg_77
                      , gdg_78, gdg_79, gdg_80, gdg_81, gdg_82, gdg_83, gdg_84
                      , gdg_85, gdg_86
                FROM mimiciv.cohort_newborn_dataset;
            """
    return query

def get_newborn_diagnoses_query(version):

    if version == 1:
        query = "SELECT icd_code, icd_version, long_title, diagnoses, no_death, death"
        query += " FROM  mimiciv.cohort_newborn_diagnoses_20251125"
        query += " WHERE  (diagnoses_group is null or diagnoses_group in ('death_atypical','diagnoses_excluded'))"
    else:
        query = "SELECT icd_code, icd_version, long_title, diagnoses, no_death, death"
        query += " FROM  mimiciv.cohort_newborn_diagnoses"
        query += " WHERE diagnoses_group is null "

    return query;

def get_newborn_cohort_feature_chartevent_query():
    query = "SELECT itemid, label, lownormalvalue, highnormalvalue, column_dataset"
    query = query + " FROM mimiciv.cohort_newborn_chartevents_items;"
    return query

# Get a connection to postgreSql Database
#
# All connection parameters are read from environment variables so that no
# real credential is ever committed to source control. Copy .env.example to
# .env, fill in your own local Postgres password, and either export the
# variables yourself or install python-dotenv (`pip install python-dotenv`)
# so this module loads them automatically.
#
# MIMICIV_DB_PASSWORD has no default on purpose: get_connect_database()
# raises a clear error instead of silently connecting with a guessed value.
def get_connect_database():

    driver   = "postgresql+psycopg2"
    user     = os.getenv("MIMICIV_DB_USER", "postgres")
    password = os.getenv("MIMICIV_DB_PASSWORD")
    server   = os.getenv("MIMICIV_DB_HOST", "localhost")
    port     = os.getenv("MIMICIV_DB_PORT", "5433")
    database = os.getenv("MIMICIV_DB_NAME", "mimiciv")

    if not password:

        texto = "MIMICIV_DB_PASSWORD is not set. Copy .env.example to .env, set " 
        texto = texto + "your local Postgres password there, and make sure it is loaded " 
        texto = texto + "(via python-dotenv, or by exporting the variable yourself) "
        texto = texto + "before calling get_connect_database()."
        print(password)
        raise RuntimeError(texto)
            

    string_conection = driver +"://"+user+":"+password+"@"+server+":"+port+"/"+database
    engine = alchemy.create_engine(string_conection)

    return engine

# Disconnect a connection to postgreSql Database
def disconnect_database(engine):
    engine.dispose()


def update_diagnoses_group_cluster(engine, df):

    # Mapeo de cluster k-means → grupo diagnóstico
    cluster_map = {
        0: "GDG_85",
        1: "GDG_86"
    }

    sql = alchemy.text("""
        UPDATE mimiciv.cohort_newborn_diagnoses
        SET    diagnoses_group = :group_name
        WHERE  icd_code    = :icd_code
        AND    icd_version = :icd_version
    """)

    updated = 0
    errors  = 0

    with engine.connect() as conn:
        for _, row in df.iterrows():
            group_name = cluster_map.get(int(row["cluster"]))
            if group_name is None:
                print(f"Cluster desconocido: {row['cluster']} — fila omitida")
                continue
            try:
                result = conn.execute(sql, {
                    "group_name" : group_name,
                    "icd_code"   : str(row["icd_code"]),
                    "icd_version": int(row["icd_version"])
                })
                updated += result.rowcount
            except Exception as e:
                print(f"Error en icd_code={row['icd_code']} v{row['icd_version']}: {e}")
                errors += 1

        conn.commit()

    print(f"Actualizados: {updated} registros | Errores: {errors}")

def update_feature_diagnoses_dataset(engine):
    sql = alchemy.text("SELECT mimiciv.update_feature_diagnoses_cohort_newborn_dataset()")
    with engine.connect() as conn:
        conn.execute(sql)
    print("Procedimiento ejecutado correctamente.")

def reset_diagnoses_group_cluster(engine):
    sql = alchemy.text("""
        UPDATE mimiciv.cohort_newborn_diagnoses
        SET    diagnoses_group = NULL
        WHERE  have_diagnoses  = 0
    """)
    with engine.connect() as conn:
        result = conn.execute(sql)
        conn.commit();

    print(f"Registros actualizados: {result.rowcount}")
