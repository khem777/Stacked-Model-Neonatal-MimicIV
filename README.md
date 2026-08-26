# Stacked Machine Learning Ensemble for Predicting Neonatal Mortality (MIMIC-IV)

Code, SQL, and figures accompanying the manuscript:

> Gutiérrez Jiménez, E.; Márquez Díaz, J.D. **Stacked Machine Learning Ensemble for
> Predicting Neonatal Mortality: A MIMIC-IV-Based Clinical Study.** Submitted to
> *Healthcare* (MDPI), 2026.

This repository is provided as supplementary material for the manuscript's
**Data Availability Statement**. It makes the full modeling pipeline —
cohort extraction, diagnosis classification, feature engineering, and
model training — transparent and reproducible for reviewers and
researchers with their own credentialed access to MIMIC-IV.

**No patient-level data of any kind is included in this repository.**
Every `.sql` file here contains only schema definitions, functions, and a
code-to-category classification (ICD code → diagnosis group) — never a
`subject_id`, `hadm_id`, or `stay_id` value. See "Data access" below.

## Summary

A stacked ensemble (Random Forest, XGBoost, Extra Trees, and a Logistic
Regression meta-learner) is trained on structured EHR data from MIMIC-IV to
predict neonatal in-hospital mortality. The pipeline includes a structured
expert-panel ICD classification process that groups admission diagnosis
codes into 86 clinically named diagnosis-group indicators (`gdg_01`–`gdg_86`)
across nine organ systems, IQR-based outlier removal, skewness-driven
imputation, differential numerical scaling, SHAP-based interpretability, a
threshold-sensitivity analysis, and a three-tier clinical risk stratification
protocol.

The stacked model achieved an AUC of 0.800 and 80.0% accuracy on a held-out
test set of 3,737 admissions, outperforming every individual base learner
(AUC range: 0.783–0.796).

## Repository contents

```
sql/
  01_load_mimic_iv_schema/   Step 1: rebuild the raw MIMIC-IV schema locally
  02_build_cohort_and_features.sql   Step 2: build the neonatal cohort,
                                      diagnosis classification, and the
                                      final feature table
libraries/
  database.py                Connection + query functions used by the notebook
  functions.py                Small statistics helper used by the notebook
notebooks/
  newborn_models_v5.ipynb     Full modeling pipeline (see below)
data/
  ethnicity_groups.xlsx           Code -> category lookup table (ethnicity)
  language_groups.xlsx            Code -> category lookup table (language)
  admission_location_groups.xlsx  Code -> category lookup table (admission location)
figures/                      Figures included in the manuscript
docker-compose.yml             Local Postgres + Jupyter environment
.env.example                   Template for local DB credentials
requirements.txt
```

The three files in `data/` are manual homologation/classification tables built
to group raw MIMIC-IV category codes (ethnicity, language, admission
location) into a smaller set of standardized categories used by the
notebook. They contain **no patient-level data** -- only the category
codes and their group labels -- so they are safe to publish. This is the
only kind of file that belongs in `data/`: any file the notebook *writes*
(e.g. `df_cohort_newborn_dataset.xlsx`) is a derived, patient-level-adjacent
artifact and must never be added here or committed.

`notebooks/newborn_models_v5.ipynb` covers: cohort construction (querying
the tables built by `sql/`), the K-means step that classifies the two
residual diagnosis clusters (GDG_85/GDG_86) not covered by the expert-panel
mapping, preprocessing, base-model tuning (`GridSearchCV`, 5-fold
cross-validation), the stacking ensemble, a threshold-sensitivity analysis,
SHAP interpretability, and subgroup (fairness) evaluation.

## Reproducing the pipeline

1. **Get credentialed access to MIMIC-IV** on PhysioNet (see "Data access"
   below) and download the CSV export.
2. **Load the raw schema locally** — follow `sql/01_load_mimic_iv_schema/README.md`.
   `docker-compose.yml` spins up a local Postgres 13 + Jupyter environment
   matching what this pipeline was developed against. Its `volumes:` entry
   for `db_mimiciv` points at an existing, already-loaded MIMIC-IV data
   directory by absolute path (a bind mount -- nothing is copied or
   duplicated); edit that path to match where your own loaded data lives.
   Only ever run one Postgres container against a given data directory at a
   time.
3. **Build the cohort and feature table** — run
   `sql/02_build_cohort_and_features.sql` against that instance
   (`psql -f sql/02_build_cohort_and_features.sql`, or via your own client).
   This creates `cohort_newborn`, `cohort_newborn_diagnoses` (with the
   86-group ICD classification already applied), the two helper functions,
   and the final `cohort_newborn_dataset` feature table.
4. **Configure your credentials**: copy `.env.example` to `.env` (in the
   project root, next to `docker-compose.yml` -- not inside `notebooks/`)
   and fill in your local Postgres password; the other defaults
   (`MIMICIV_DB_USER=postgres`, `MIMICIV_DB_HOST=localhost`,
   `MIMICIV_DB_PORT=5433`, `MIMICIV_DB_NAME=mimiciv`) already match the
   setup this pipeline was developed against. On Windows, make sure the
   file is actually named `.env` and not `.env.txt` -- enable "File name
   extensions" in File Explorer's View tab to check. `.env` is git-ignored;
   never commit it.
5. **Install dependencies** into a dedicated environment, then point your
   notebook kernel at it:
   ```powershell
   cd Stacked_Model_Neonatal_MimicIV
   python -m venv .venv
   .venv\Scripts\activate        # macOS/Linux: source .venv/bin/activate
   pip install -r requirements.txt
   ```
   This installs `python-dotenv`, which is what makes `libraries/database.py`
   read the `.env` file automatically -- no need to set environment
   variables by hand. In VS Code, open `notebooks/newborn_models_v5.ipynb`,
   click the kernel name in the top-right corner, and select the `.venv`
   interpreter you just created. If the notebook/kernel was already running
   before `.env` existed, restart the kernel (or at least re-run the import
   cell) so it picks up the new file.
6. **Run the notebook**: `notebooks/newborn_models_v5.ipynb`. Cell 3
   connects via `libraries/database.py`; cell 10 populates the `gdg_01..86`
   columns by calling the Postgres function created in step 3
   (equivalent to running `SELECT mimiciv.update_feature_diagnoses_cohort_newborn_dataset();`
   directly in SQL). Use Kernel → Restart, then Run → Run All Cells (rather
   than running a partial range) so every preprocessing step -- including
   the skewness-driven imputation that must run before scaling -- executes
   in order; running cells out of order after a kernel restart is the most
   common cause of `NaN`-related errors during model training.
7. **Enable the SHAP interpretability cells**: the lines that generate the
   SHAP plots are commented out (`#`) by default, because they are heavy
   on CPU/RAM and can freeze the machine if it's already busy with other
   programs. Remove the leading `#` from those lines only when you're
   ready to generate the SHAP figures, and ideally do so right after a
   fresh restart of the computer (not just the kernel), with other
   applications closed, to give the process the most headroom.

## Data access

This repository does **not** include any patient-level data. All analyses
use the **MIMIC-IV** database, which requires credentialed access via
[PhysioNet](https://physionet.org/content/mimiciv/). To reproduce this work
you must:

1. Complete the CITI "Data or Specimens Only Research" training course.
2. Sign the PhysioNet Credentialed Health Data Use Agreement.
3. Request and be granted access to MIMIC-IV on PhysioNet, and download
   your own copy of the CSV export.

See Johnson, A.E.W. et al. *MIMIC-IV, a freely accessible electronic health
record dataset.* Scientific Data **2023**, *10*, 1.
[https://doi.org/10.1038/s41597-022-01899-x](https://doi.org/10.1038/s41597-022-01899-x)

## Citation

If you use this code, please cite the manuscript above. A formal citation
(journal, volume, DOI) will be added here once the article is accepted and
published.

## License

The code in this repository is released under the MIT License (see
`LICENSE`). The manuscript itself, once published, will be distributed
under the *Healthcare* (MDPI) open-access license (CC BY).

## Contact

Emmanuel Gutiérrez Jiménez — egutierrez@fintra.co
