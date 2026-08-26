# Step 1 — Load the raw MIMIC-IV schema into a local Postgres instance

These scripts rebuild the official MIMIC-IV table structure in your own
Postgres database. They contain **no patient data** — only table
definitions, indexes, and the public MIMIC-IV lab-item dictionary
(`d_labitems`: standard test names such as "Hemoglobin" or "Creatinine",
with no patient information attached).

Run them in this order, against your own credentialed, locally-loaded copy
of MIMIC-IV:

1. `mimic_create_database.sql` — creates the `mimiciv` schema and all base
   tables (admissions, patients, icustays, chartevents, labevents,
   diagnoses_icd, etc.), plus the `d_labitems` dictionary rows.
2. Download the official MIMIC-IV CSV export from PhysioNet (requires your
   own credentialed access, see the main README) and place the files under
   `postgres_data/csv/hosp/` and `postgres_data/csv/icu/`, matching the
   volume mount in `docker-compose.yml`. The `powershell_csv_prep/` scripts
   in this folder are optional Windows helpers used to merge/order
   multi-part CSV exports for a couple of large tables before loading —
   adjust the paths inside them to your own environment, or skip them if
   your CSV export is already a single file per table.
3. `mimic_load_data_upgrade.sql` — loads the CSVs into the tables created
   in step 1 (server-side `COPY`, so paths are relative to the Postgres
   *container's* filesystem, per the `docker-compose.yml` volume mount).
4. `mimic_add_indexes.sql` — adds the indexes used by the cohort-extraction
   queries in `sql/02_build_cohort_and_features.sql`.

All three `.sql` files were validated end-to-end (`psql -v ON_ERROR_STOP=1`)
against a fresh Postgres 16 instance loaded with the official table
definitions — steps 1 and 4 with no data, step 3 with empty header-only CSV
stand-ins to confirm every `COPY` statement is syntactically correct.

An alternative, official tool for this same step is
[MIT-LCP/mimic-code](https://github.com/MIT-LCP/mimic-code), if you prefer
its build scripts to the ones here.
