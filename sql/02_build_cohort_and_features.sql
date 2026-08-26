-- ============================================================================
-- Neonatal Mortality Cohort & Feature Dataset -- MIMIC-IV
-- ============================================================================
-- Reconstructs, from a locally-loaded MIMIC-IV Postgres instance, the schema
-- objects queried by libraries/database.py and used by
-- notebooks/newborn_models_v5.ipynb.
--
-- This file contains ONLY schema/table-building logic, SQL functions, and a
-- code->category classification (ICD code -> diagnosis group). It contains
-- NO patient-level data of any kind (no subject_id/hadm_id/stay_id values).
-- Running it against your own credentialed, locally-loaded copy of MIMIC-IV
-- reconstructs the tables; it does not redistribute any MIMIC-IV data.
--
-- Prerequisite: the raw MIMIC-IV schema must already be loaded into a
-- `mimiciv` Postgres schema (see sql/01_load_mimic_iv_schema/ in this repo,
-- or https://github.com/MIT-LCP/mimic-code).
--
-- Validated: executed end-to-end with `psql -v ON_ERROR_STOP=1` against a
-- fresh Postgres 16 instance loaded only with the official MIMIC-IV table
-- definitions (no patient rows) -- completes with no errors and produces a
-- cohort_newborn_dataset table whose columns match exactly what
-- database.get_newborn_cohort_query() selects.
-- ============================================================================

SET search_path TO mimiciv, public;


-- ============================================================================
-- SECTION 1 -- Cohort definition, diagnoses table, and ICD -> diagnosis-group
-- (GDG) classification (86 expert-defined groups)
-- ============================================================================

--------------------
-- Newborn Cohort
--------------------

-- Pregnant women admitted to Beth Israel Deaconess Medical Center (BIDMC) within 45 days 
-- of their child's birth, and whose delivery occurred within BIDMC facilities between 2008 and 2019.

-- Only the Subject Id and Hadm_id fields are present. Stay Id appears where applicable.
create table mimiciv.cohort_newborn as
select X.subject_id
       , X.hadm_id
       , (
	   		select min(i.stay_id)
		    from   mimiciv.icustays i 
          	where  i.subject_id = X.subject_id
          	and    i.hadm_id    = X.hadm_id
          	and    DATE_PART('day', date_trunc('day',i.intime) - X.dob) between -45 and 0
         ) as stay_id
       , (
          case when a3.deathtime is null 
          then (
                case when (
                 			select min(a5.deathtime)
                			from   mimiciv.admissions a5
                			where  a5.subject_id = a3.subject_id
                			and    a5.deathtime is not null
               			  ) is not null 
               	     then 1
               	     else 0
               	end
               	)
          else 1
          end
         ) outcome           
from 
(
	select p.subject_id
		   , p.dob
	       , (		          
	          case when (
	       			   		select count(1) 
				        	from   mimiciv.admissions a2
				        	join   mimiciv.icustays icu2
				        	on     a2.subject_id  = icu2.subject_id
				        	and    a2.hadm_id     = icu2.hadm_id					        	
				        	where  icu2.subject_id = p.subject_id	
				        	and    TO_CHAR(a2.admittime, 'YYYYMM') >= '210912' 
				  	 		and    TO_CHAR(a2.admittime, 'YYYYMM')  <= '221410'
				  	 		and    DATE_PART('day', date_trunc('day',a2.admittime) - p.dob) between -45 and 0	
				        	and    DATE_PART('day', date_trunc('day',icu2.intime) - p.dob) between -45 and 0	
	       			  	) > 0
	               Then (
			         		select max(a2.hadm_id)
		          	 		from   mimiciv.admissions a2 
		          	 		where  a2.subject_id = p.subject_id
		          	 		and    TO_CHAR(a2.admittime, 'YYYYMM') >= '210912' 
				  	 		and    TO_CHAR(a2.admittime, 'YYYYMM')  <= '221410'
				  	 		and    DATE_PART('day', date_trunc('day',a2.admittime) - p.dob) between -45 and 0	
				  	 		and    (
						          	select count(1) 
						          	from   mimiciv.icustays icu2
						          	where  icu2.subject_id = a2.subject_id 
						          	and    icu2.hadm_id    = a2.hadm_id  
						          	and    DATE_PART('day', date_trunc('day',icu2.intime) - p.dob) between -45 and 0	
							   		) > 0
				    	)
				   else (
							select max(a2.hadm_id)
		          	 		from   mimiciv.admissions a2 
		          	 		where  a2.subject_id = p.subject_id
		          	 		and    TO_CHAR(a2.admittime, 'YYYYMM') >= '210912' 
				  	 		and    TO_CHAR(a2.admittime, 'YYYYMM')  <= '221410'
				  	 		and    DATE_PART('day', date_trunc('day', a2.admittime) - p.dob) between -45 and 0						
						)
			 end
      		) as hadm_id	         
	from   mimiciv.patients p 
	where  p.dob is not null
	and    TO_CHAR(p.dob, 'YYYYMM')  >= '211001' 
	and    TO_CHAR(p.dob, 'YYYYMM')  <= '221410'	
) X
join mimiciv.admissions a3
on   a3.subject_id  = X.subject_id
and  a3.hadm_id     = X.hadm_id
where X.hadm_id is not null;

-- Create primary key in Cohort_newboarn
alter table mimiciv.cohort_newborn add constraint pk_cohort_newborn primary key (subject_id, hadm_id);

-- Create table to have every diagnosis of the newborn cohort
create table mimiciv.cohort_newborn_diagnoses as
select di.icd_code
           , di.icd_version
	       , did.long_title
	       , count(1) diagnoses
	       , sum(case when cn.outcome = 0 then 1 else 0 End) no_death
	       , sum(case when cn.outcome = 1 then 1 else 0 End) death	       
from   mimiciv.diagnoses_icd di
join   mimiciv.d_icd_diagnoses did 
on     di.icd_code = did.icd_code
and    di.icd_version = did.icd_version 
join   mimiciv.cohort_newborn cn 
on     cn.subject_id = di.subject_id
and    cn.hadm_id    = di.hadm_id
where  di.seq_num <= 4
group by di.icd_code, di.icd_version, did.long_title;

-- Add a column diganoses_group to the table to clasify diagnoses by groups
alter table mimiciv.cohort_newborn_diagnoses add column diagnoses_group varchar(300);
alter table mimiciv.cohort_newborn_diagnoses add column diagnoses_group_alt varchar(300);
alter table mimiciv.cohort_newborn_diagnoses add column have_diagnoses int4;

-- Add primary key to the table cohort_newborn_diagnoses
alter table mimiciv.cohort_newborn_diagnoses add constraint pk_cn_diagnoses primary key(icd_code, icd_version);

-- GDG_01 - Intestinal infection
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_01' Where icd_code = '00845' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_01' Where icd_code = '0088' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_01' Where icd_code = 'A048' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_01' Where icd_code = 'A049' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_01' Where icd_code = 'A084' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_01' Where icd_code = 'A088' and icd_version = 10;

-- GDG_02 - Malignant neoplasm of liver
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = '1550' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = '1551' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = '1552' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = '1561' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = '1568' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = '1977' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = '2353' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = 'C228' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = 'C229' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = 'C240' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_02' Where icd_code = 'C787' and icd_version = 10;

-- GDG_03 - Malignant neoplasm of bronchus and/or lung
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = '1622' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = '1623' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = '1624' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = '1625' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = '1628' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = '1629' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = '1970' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3400' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3401' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3402' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3410' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3411' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3412' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C342' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3431' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3432' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3481' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3482' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3490' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3491' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C3492' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C7800' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C7801' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_03' Where icd_code = 'C7802' and icd_version = 10;

-- GDG_04 - Ischemia/Vascular insufficiency/Hemorrhage intestine
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = '5570' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = '5571' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = '5579' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = '5789' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = 'K55011' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = 'K55012' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = 'K55019' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = 'K55031' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = 'K55032' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = 'K55039' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = 'K55059' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_04' Where icd_code = 'K922' and icd_version = 10;

-- GDG_05 - Diabetes mellitus without mention of complication
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = '24900' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = '24911' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = '25000' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = '25001' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = '25002' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E0810' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E0865' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1010' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1022' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1042' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1052' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E10641' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E10649' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1065' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1069' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1100' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1110' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1121' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1122' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E11319' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1140' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1142' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1151' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1152' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E11610' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E11621' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E11622' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E11641' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E11649' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1165' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1169' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E118' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E119' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E1310' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_05' Where icd_code = 'E139' and icd_version = 10;

-- GDG_06 - Delirium due to known physiological condition
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_06' Where icd_code = '2930' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_06' Where icd_code = 'F05' and icd_version = 10;

-- GDG_07 - Hydrocephalus
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = '3313' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = '3314' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = '3315' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = 'G910' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = 'G911' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = 'G912' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = 'G913' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = 'G918' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_07' Where icd_code = 'G919' and icd_version = 10;

-- GDG_08 - Septicemia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '0380' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '03810' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '03811' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '03812' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '03819' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '0382' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '0383' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '03840' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '03842' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '03843' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '03849' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '0388' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '0389' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '78552' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '99591' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = '99592' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A400' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A401' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A403' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A408' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A409' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A4101' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A4102' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A411' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A412' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A4150' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A4151' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A4152' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A4159' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A4181' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A4189' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'A419' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'R6520' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'R6521' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_08' Where icd_code = 'T8144XA' and icd_version = 10;

-- GDG_09 - Subendocardial infarction
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_09' Where icd_code = '41071' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_09' Where icd_code = '41072' and icd_version = 9;

-- GDG_10 - Coronary atherosclerosis of native coronary artery
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = '41400' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = '41401' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = '41402' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = '41405' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = '4142' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I2510' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I25110' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I25111' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I25118' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I25119' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I2542' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I25718' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I25720' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I25810' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'I2582' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_10' Where icd_code = 'Z9861' and icd_version = 10;

-- GDG_11 - Ventricular tachycardia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_11' Where icd_code = '4271' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_11' Where icd_code = 'I472' and icd_version = 10;

-- GDG_12 - Atrial fibrillation
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = '42731' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = 'I480' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = 'I481' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = 'I4811' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = 'I4819' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = 'I482' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = 'I4820' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = 'I4821' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_12' Where icd_code = 'I4891' and icd_version = 10;

-- GDG_13 - Diastolic heart failure
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = '42830' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = '42831' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = '42832' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = '42833' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = '42840' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = '42841' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = '42842' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = '42843' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = 'I5030' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = 'I5031' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = 'I5032' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = 'I5033' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = 'I5041' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = 'I5042' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_13' Where icd_code = 'I5043' and icd_version = 10;

-- GDG_14 - Malignant neoplasm of other specified sites
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1410' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1418' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1429' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1452' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1459' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1468' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1478' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1479' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1490' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1510' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1512' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1513' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1514' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1518' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1519' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1520' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1521' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1530' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1532' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1533' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1534' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1535' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1536' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1537' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1538' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1539' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1540' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1541' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1543' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1548' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1560' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1562' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1569' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1598' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1603' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1611' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1620' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1640' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1701' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1710' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1713' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1714' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1715' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1716' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1733' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1744' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1748' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1749' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '179' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1808' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1809' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1820' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1840' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1844' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '185' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1885' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1888' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1889' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1890' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1892' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1906' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1910' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1911' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1912' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1913' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1914' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1915' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1929' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '193' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1940' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1943' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1950' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1953' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1960' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1961' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1962' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1963' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1965' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1966' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1968' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1969' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1971' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1973' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1974' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1975' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1978' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1980' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1981' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1982' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1984' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1987' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '19882' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '19889' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1990' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '1991' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = '20293' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C01' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C028' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C029' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C049' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C069' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C07' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C099' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C108' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C109' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C119' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C12' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C139' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C160' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C161' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C162' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C163' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C164' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C165' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C166' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C168' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C169' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C170' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C179' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C180' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C182' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C183' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C184' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C186' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C187' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C189' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C19' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C20' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C210' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C211' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C218' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C23' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C241' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C248' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C249' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C269' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C300' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C320' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C321' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C328' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C329' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C37' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C383' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C413' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C44590' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C470' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C4722' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C479' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C4911' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C4921' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C4922' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C494' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C495' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C499' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C50312' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C50411' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C50412' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C50911' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C50912' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C50919' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C518' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C519' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C52' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C530' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C539' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C541' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C549' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C55' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C563' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C5700' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C5701' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C577' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C578' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C579' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C61' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C6290' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C6291' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C641' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C642' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C649' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C652' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C661' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C662' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C672' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C674' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C678' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C679' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C689' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C701' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C710' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C711' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C712' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C713' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C714' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C715' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C716' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C73' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C7491' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C760' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_14' Where icd_code = 'C763' and icd_version = 10;

-- GDG_15 - Nontraumatic intracerebral/subarachnoid hemorrhage
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '430' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '431' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '4320' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '4321' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '4329' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '85200' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '85201' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '85202' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '85203' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '85205' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = '85206' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6010' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6011' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6012' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I602' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6031' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6032' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I604' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6052' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I606' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I607' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I608' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I609' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I610' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I611' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I612' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I613' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I614' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I615' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I616' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I618' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I619' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6200' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6201' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6202' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I6203' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I629' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I69128' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I69151' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I69154' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I69198' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I69251' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_15' Where icd_code = 'I69254' and icd_version = 10;

-- GDG_16 - Cerebral infarction
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43301' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43310' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43311' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43321' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43330' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43331' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43381' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43401' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43410' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43411' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '43491' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = '99702' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6300' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63012' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63013' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6302' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63031' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63032' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6309' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6310' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63111' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6312' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63131' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63132' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63133' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63139' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6319' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63211' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63212' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63213' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6322' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63231' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63232' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63233' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6329' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6330' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63311' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63312' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63319' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63321' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63331' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63333' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63349' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6339' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6340' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63411' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63412' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63413' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63421' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63422' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63431' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63432' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63433' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63439' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63441' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63442' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63443' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63449' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6349' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6350' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63511' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63512' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63513' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63521' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63522' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63529' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63531' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63532' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63533' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63541' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63542' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63543' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I63549' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6359' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I638' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6381' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I6389' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I639' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69318' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69320' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69328' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69341' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69351' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69354' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69391' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69392' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I69398' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I97820' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_16' Where icd_code = 'I97821' and icd_version = 10;

-- GDG_17 - Perforation of intestine / Peritonitis
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '5400' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '5670' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '56721' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '56723' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '56729' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '56781' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '56789' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '5679' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '56983' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = '6145' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = 'K3532' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = 'K3533' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = 'K631' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = 'K650' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = 'K652' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = 'K653' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = 'K658' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_17' Where icd_code = 'K659' and icd_version = 10;

-- GDG_18 - EPOC / Bronchitis
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_18' Where icd_code = '4660' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_18' Where icd_code = '490' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_18' Where icd_code = '49120' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_18' Where icd_code = '49121' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_18' Where icd_code = '49122' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_18' Where icd_code = 'J440' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_18' Where icd_code = 'J441' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_18' Where icd_code = 'J449' and icd_version = 10;

-- GDG_19 - Myocardial infarction
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41001' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41011' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41021' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41031' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41040' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41041' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41051' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41081' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41091' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '41092' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = '412' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I2101' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I2102' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I2109' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I2111' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I2119' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I2121' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I2129' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I213' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I214' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I219' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I21A1' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I21A9' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I220' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I222' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I232' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_19' Where icd_code = 'I252' and icd_version = 10;

-- GDG_20 - Hepatic encephalopathy
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_20' Where icd_code = '5722' and icd_version = 9;

-- GDG_21 - Ventricular fibrillation
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_21' Where icd_code = '42741' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_21' Where icd_code = 'I4901' and icd_version = 10;

-- GDG_22 - Pressure ulcer on the lower back
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_22' Where icd_code = '70702' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_22' Where icd_code = '70703' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_22' Where icd_code = 'L89100' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_22' Where icd_code = 'L89103' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_22' Where icd_code = 'L89104' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_22' Where icd_code = 'L89109' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_22' Where icd_code = 'L89120' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_22' Where icd_code = 'L89122' and icd_version = 10;

-- GDG_23 - Intestinal obstruction
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = '56081' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = '56089' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = '5609' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K50912' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K565' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K5650' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K5651' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K5652' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K5660' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K56600' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K56601' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K56609' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K5669' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K56690' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K56691' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K56699' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_23' Where icd_code = 'K913' and icd_version = 10;

-- GDG_24 - Atrioventricular block
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_24' Where icd_code = '4260' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_24' Where icd_code = '42611' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_24' Where icd_code = '42612' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_24' Where icd_code = '42613' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_24' Where icd_code = 'I441' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_24' Where icd_code = 'I442' and icd_version = 10;

-- GDG_25 - Liver cell carcinoma
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_25' Where icd_code = 'C220' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_25' Where icd_code = 'C221' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_25' Where icd_code = 'C227' and icd_version = 10;

-- GDG_26 - Malignant neoplasm of peritoneum
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = '1580' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = '1588' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = '1589' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = '1976' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = 'C480' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = 'C481' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = 'C482' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = 'C488' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_26' Where icd_code = 'C786' and icd_version = 10;

-- GDG_27 - Portal hypertension
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_27' Where icd_code = '5723' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_27' Where icd_code = 'K766' and icd_version = 10;

-- GDG_28 - Malignant neoplasm of brain
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = '1917' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = '1918' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = '1919' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = '1983' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = '2375' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = '2396' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = 'C718' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = 'C719' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_28' Where icd_code = 'C7931' and icd_version = 10;

-- GDG_29 - Malignant neoplasm of bone
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = '1700' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = '1706' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = '1707' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = '1985' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = 'C4022' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = 'C410' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = 'C414' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = 'C419' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = 'C7951' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = 'C7952' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_29' Where icd_code = 'D492' and icd_version = 10;

-- GDG_30 - Acute posthemorrhagic anemia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_30' Where icd_code = '2851' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_30' Where icd_code = 'D62' and icd_version = 10;

-- GDG_31 - Defibrination syndrome
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_31' Where icd_code = '2866' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_31' Where icd_code = 'D65' and icd_version = 10;

-- GDG_32 - Malnutrition of mild/moderate degree
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = '262' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = '2630' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = '2631' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = '2638' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = '2639' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = 'E43' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = 'E440' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = 'E441' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_32' Where icd_code = 'E46' and icd_version = 10;

-- GDG_33 - Hyperosmolality and/or hypernatremia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_33' Where icd_code = '2760' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_33' Where icd_code = '2761' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_33' Where icd_code = 'E870' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_33' Where icd_code = 'E871' and icd_version = 10;

-- GDG_34 - Abdominal/Thoracic  aneurysm
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = '4411' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = '4412' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = '4413' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = '4414' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = '4416' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = '4417' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = 'I711' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = 'I712' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = 'I713' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = 'I714' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = 'I715' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_34' Where icd_code = 'I716' and icd_version = 10;

-- GDG_35 - Acidosis
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_35' Where icd_code = '2762' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_35' Where icd_code = 'E872' and icd_version = 10;

-- GDG_36 - Toxic Encephalopathy
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_36' Where icd_code = '34982' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_36' Where icd_code = 'G92' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_36' Where icd_code = 'G928' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_36' Where icd_code = 'G929' and icd_version = 10;

-- GDG_37 - Unspecified encephalopathy
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_37' Where icd_code = '34830' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_37' Where icd_code = '34839' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_37' Where icd_code = 'G9340' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_37' Where icd_code = 'G9349' and icd_version = 10;

-- GDG_38 - Metabolic encephalopathy
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_38' Where icd_code = '34831' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_38' Where icd_code = 'G9341' and icd_version = 10;

-- GDG_39 - Compression brain
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_39' Where icd_code = '3484' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_39' Where icd_code = 'G935' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_39' Where icd_code = 'S06A0XA' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_39' Where icd_code = 'S06A1XA' and icd_version = 10;

-- GDG_40 - Cerebral edema
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_40' Where icd_code = '3485' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_40' Where icd_code = 'G936' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_40' Where icd_code = 'S061X0A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_40' Where icd_code = 'S061X7A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_40' Where icd_code = 'S061X8A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_40' Where icd_code = 'S061X9A' and icd_version = 10;

-- GDG_41 - Essential hypertension
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_41' Where icd_code = '4010' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_41' Where icd_code = '4011' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_41' Where icd_code = '4019' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_41' Where icd_code = 'I10' and icd_version = 10;

-- GDG_42 - Hypertensive heart and chronic kidney disease
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40291' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40301' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40310' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40311' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40390' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40391' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40411' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40491' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '40493' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '5853' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '5854' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = '5859' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = 'I110' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = 'I120' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = 'I129' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = 'I130' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = 'I1310' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = 'I132' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_42' Where icd_code = 'N184' and icd_version = 10;

-- GDG_43 - Pulmonary edema
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_43' Where icd_code = 'J810' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_43' Where icd_code = 'J811' and icd_version = 10;

-- GDG_44 - Pulmonary embolism
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = '41511' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = '41512' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = '41519' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = '4162' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = 'I2601' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = 'I2609' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = 'I2690' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = 'I2693' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = 'I2699' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_44' Where icd_code = 'I2782' and icd_version = 10;

-- GDG_45 - Cardiac arrest
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_45' Where icd_code = '4275' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_45' Where icd_code = 'I462' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_45' Where icd_code = 'I468' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_45' Where icd_code = 'I469' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_45' Where icd_code = 'I97120' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_45' Where icd_code = 'I97121' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_45' Where icd_code = 'I97710' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_45' Where icd_code = 'I97711' and icd_version = 10;

-- GDG_46 - Systolic heart failure
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_46' Where icd_code = '42820' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_46' Where icd_code = '42821' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_46' Where icd_code = '42822' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_46' Where icd_code = '42823' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_46' Where icd_code = 'I5020' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_46' Where icd_code = 'I5021' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_46' Where icd_code = 'I5022' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_46' Where icd_code = 'I5023' and icd_version = 10;

-- GDG_47 - Congestive heart failure
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_47' Where icd_code = '4280' and icd_version = 9;

-- GDG_48 - Bacteremia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_48' Where icd_code = '7907' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_48' Where icd_code = 'R7881' and icd_version = 10;

-- GDG_49 - Portal vein thrombosis
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_49' Where icd_code = '452' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_49' Where icd_code = 'I81' and icd_version = 10;

-- GDG_50 - Pneumonía Viral / COVID 19
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = '4801' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = '4802' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = '4808' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = '4870' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = '48801' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = '48881' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'B012' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J09X1' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J1000' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J1001' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J1008' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J1100' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J1108' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J121' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J122' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J1281' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J1282' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J1289' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'J129' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_50' Where icd_code = 'U071' and icd_version = 10;

-- GDG_51 - Pneumonía Unspecified
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_51' Where icd_code = '485' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_51' Where icd_code = '486' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_51' Where icd_code = '5070' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_51' Where icd_code = 'J180' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_51' Where icd_code = 'J181' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_51' Where icd_code = 'J189' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_51' Where icd_code = 'J690' and icd_version = 10;

-- GDG_52 - Acute respiratory failure with hypoxia or hypercapnia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = '5118' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = '51881' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = '51884' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'I2723' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J80' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J918' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J948' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9600' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9601' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9602' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9610' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9611' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9612' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9620' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9621' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9622' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9690' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9691' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_52' Where icd_code = 'J9692' and icd_version = 10;

-- GDG_53 - Pleural effusion
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_53' Where icd_code = '51181' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_53' Where icd_code = '5119' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_53' Where icd_code = 'J90' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_53' Where icd_code = 'J910' and icd_version = 10;

-- GDG_54 - Pancreatitis
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = '5770' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = '5771' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8500' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K851' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8510' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8511' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8512' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8520' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8521' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8530' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8580' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8582' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K859' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8590' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8591' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K8592' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_54' Where icd_code = 'K861' and icd_version = 10;

-- GDG_55 - Cirrhosis (Alcoholic, Biliary)
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_55' Where icd_code = '5712' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_55' Where icd_code = '5715' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_55' Where icd_code = '5716' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_55' Where icd_code = 'K7030' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_55' Where icd_code = 'K7031' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_55' Where icd_code = 'K743' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_55' Where icd_code = 'K7460' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_55' Where icd_code = 'K7469' and icd_version = 10;

-- GDG_56 - Hepatic failure
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = '570' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = '5734' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = 'K7040' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = 'K7041' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = 'K7110' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = 'K7111' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = 'K7200' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = 'K7201' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = 'K7290' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_56' Where icd_code = 'K7291' and icd_version = 10;

-- GDG_57 - Hepatorenal syndrome
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_57' Where icd_code = '5724' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_57' Where icd_code = 'K767' and icd_version = 10;

-- GDG_58 - Obstruction of bile duct
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = '57431' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = '57441' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = '57451' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = '57461' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = '57471' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = '57481' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = '5762' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = 'K8031' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = 'K8033' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = 'K8051' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = 'K8063' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_58' Where icd_code = 'K831' and icd_version = 10;

-- GDG_59 - Acute kidney failure with tubular necrosis
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_59' Where icd_code = '5845' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_59' Where icd_code = 'N170' and icd_version = 10;

-- GDG_60 - Acute kidney failure, unspecified
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_60' Where icd_code = '5848' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_60' Where icd_code = '5849' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_60' Where icd_code = 'N178' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_60' Where icd_code = 'N179' and icd_version = 10;

-- GDG_61 - End stage renal disease
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_61' Where icd_code = '5856' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_61' Where icd_code = 'N186' and icd_version = 10;

-- GDG_62 - Urinary tract infection, site not specified
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_62' Where icd_code = '5990' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_62' Where icd_code = 'N390' and icd_version = 10;

-- GDG_63 - Ascites
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_63' Where icd_code = '78951' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_63' Where icd_code = '78959' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_63' Where icd_code = 'R180' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_63' Where icd_code = 'R188' and icd_version = 10;

-- GDG_64 - Cardiogenic shock
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_64' Where icd_code = '78551' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_64' Where icd_code = '99801' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_64' Where icd_code = 'R570' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_64' Where icd_code = 'T8111XA' and icd_version = 10;

-- GDG_65 - Traumatic intracerebral/subarachnoid hemorrhage
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80020' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80021' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80025' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80026' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80075' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80120' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80121' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80122' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80125' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80126' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80129' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80131' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80135' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80136' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80171' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80175' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80176' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80322' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80325' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80326' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80331' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80332' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80375' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '80421' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85220' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85221' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85222' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85223' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85225' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85226' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85230' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85231' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85232' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85235' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85240' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85241' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85245' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85300' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85301' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85302' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85304' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85305' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85306' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '85309' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '8602' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '8603' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = '8604' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'G062' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06340A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06349A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06350A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06359A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06360A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06369A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06370A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06377A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S06379A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S065X0A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S065X1A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S065X6A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S065X7A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S065X8A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S065X9A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S066X0A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S066X1A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S066X6A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S066X7A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S066X8A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S066X9A' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S271XXA' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_65' Where icd_code = 'S272XXA' and icd_version = 10;

-- GDG_66 - Cachexia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_66' Where icd_code = '7994' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_66' Where icd_code = 'R64' and icd_version = 10;

-- GDG_67 - Palliative care
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_67' Where icd_code = 'V667' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_67' Where icd_code = 'Z515' and icd_version = 10;

-- GDG_68 - Hemiplegia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34200' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34201' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34202' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34210' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34280' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34281' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34282' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34290' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34291' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '34292' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '3431' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '43820' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '43821' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = '43822' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = 'G8101' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = 'G8104' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = 'G8114' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = 'G8191' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = 'G8194' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = 'I69851' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = 'I69951' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_68' Where icd_code = 'I69954' and icd_version = 10;

-- GDG_69 - Cholecystitis / Cholangitis
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57400' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57410' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57411' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57420' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57440' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57450' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57460' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57491' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '5750' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57511' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '57512' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = '5761' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8000' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8001' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8010' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8012' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8030' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8032' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8040' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8050' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8071' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K810' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K811' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K82A2' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K830' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8301' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_69' Where icd_code = 'K8309' and icd_version = 10;

-- GDG_70 - Hepatitis C / Hepatitis B / Hepatitis A / Hepatitis Alcohólica
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '0700' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07020' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07022' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07030' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07031' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07032' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07033' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07041' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07044' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07049' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07054' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07070' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '07071' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '5711' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = '5733' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B159' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B169' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B1710' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B178' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B179' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B181' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B182' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B1910' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B1920' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'B1921' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'K7010' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'K7011' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_70' Where icd_code = 'K712' and icd_version = 10;

-- GDG_71 - VIH
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_71' Where icd_code = '042' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_71' Where icd_code = 'B20' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_71' Where icd_code = 'V08' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_71' Where icd_code = 'Z21' and icd_version = 10;

-- GDG_72 - Tachycardia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_72' Where icd_code = '4270' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_72' Where icd_code = '7850' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_72' Where icd_code = 'I471' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_72' Where icd_code = 'R000' and icd_version = 10;

-- GDG_73 - Pneumonía bacterial
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '481' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '4820' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '4821' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '4822' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '48230' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '48232' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '48239' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '48249' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '48282' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '48283' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '48284' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '48289' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '4829' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '4838' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '4841' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '4846' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = '4847' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'B961' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J13' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J14' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J150' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J151' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J1520' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J1529' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J153' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J154' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J155' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J156' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J158' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J159' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J168' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J188' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J84116' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J851' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_73' Where icd_code = 'J852' and icd_version = 10;

-- GDG_74 - Anemia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_74' Where icd_code = '2859' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_74' Where icd_code = 'D649' and icd_version = 10;

-- GDG_75 - Alkalosis
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_75' Where icd_code = '2763' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_75' Where icd_code = 'E873' and icd_version = 10;

-- GDG_76 - Malignant neoplasm in pancreas
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = '1570' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = '1571' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = '1572' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = '1573' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = '1578' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = '1579' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = 'C250' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = 'C251' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = 'C252' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = 'C253' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = 'C254' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = 'C257' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = 'C258' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_76' Where icd_code = 'C259' and icd_version = 10;

-- GDG_77 - Malignant neoplasm in esophagus
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = '1502' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = '1503' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = '1504' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = '1505' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = '1508' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = '1509' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = 'C153' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = 'C154' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = 'C155' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = 'C158' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = 'C159' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_77' Where icd_code = 'V1003' and icd_version = 9;

-- GDG_78 - Malignant neoplasm of pleura
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_78' Where icd_code = '1638' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_78' Where icd_code = '1639' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_78' Where icd_code = '1972' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_78' Where icd_code = 'C384' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_78' Where icd_code = 'C782' and icd_version = 10;

-- GDG_79 - Malignant neoplasm of ovary
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_79' Where icd_code = '1830' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_79' Where icd_code = '1986' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_79' Where icd_code = 'C561' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_79' Where icd_code = 'C562' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_79' Where icd_code = 'C569' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_79' Where icd_code = 'C7960' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_79' Where icd_code = 'C7962' and icd_version = 10;

-- GDG_80 - Dehydration
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_80' Where icd_code = '27651' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_80' Where icd_code = 'E860' and icd_version = 10;

-- GDG_81 - Pancytopenia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_81' Where icd_code = '2841' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_81' Where icd_code = '28411' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_81' Where icd_code = '28412' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_81' Where icd_code = '28419' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_81' Where icd_code = 'D61810' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_81' Where icd_code = 'D61811' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_81' Where icd_code = 'D61818' and icd_version = 10;

-- GDG_82 - Hypotension
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = '4580' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = '45821' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = '45829' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = '4589' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = 'I951' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = 'I952' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = 'I953' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = 'I9581' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = 'I9589' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_82' Where icd_code = 'I959' and icd_version = 10;

-- GDG_83 - Thrombocytopenia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_83' Where icd_code = '28730' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_83' Where icd_code = '2874' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_83' Where icd_code = '28749' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_83' Where icd_code = '2875' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_83' Where icd_code = '28984' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_83' Where icd_code = 'D7582' and icd_version = 10;

-- GDG_84 - Myeloid Leukemia
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = '20500' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = '20501' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = '20502' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = '20510' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = '20511' and icd_version = 9;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C9200' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C9201' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C9202' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C9210' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C9240' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C9250' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C92A0' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C92Z0' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C92Z2' and icd_version = 10;
update mimiciv.cohort_newborn_diagnoses set diagnoses_group ='GDG_84' Where icd_code = 'C9310' and icd_version = 10;

-- Marcar los diagnósticos que tienen grupo de expertos
update mimiciv.cohort_newborn_diagnoses
set    have_diagnoses = 1
where  diagnoses_group is not null;

-- Marcar los diagnósticos que no tienen grupo de expertos
update mimiciv.cohort_newborn_diagnoses
set    have_diagnoses = 0
where  diagnoses_group is null;


-- ============================================================================
-- SECTION 2 -- Helper functions used by libraries/database.py
-- ============================================================================

CREATE OR REPLACE FUNCTION mimiciv.get_have_diagnoses_group(p_subject_id INT4, p_hadm_id INT4, p_diagnoses_group VARCHAR)
RETURNS BOOLEAN AS $$

DECLARE
	have_diagnoses_group BOOLEAN;
BEGIN

	select (case when (X.reg >= 1) then true else false end)
	into   have_diagnoses_group
	from   
	(
		select count(1) reg
		from   mimiciv.diagnoses_icd di
		Where  di.subject_id = p_subject_id
		and    di.hadm_id    = p_hadm_id
		and    (di.icd_code, di.icd_version) in (select cnd.icd_code, cnd.icd_version 
		                                         from   mimiciv.cohort_newborn_diagnoses cnd
		                                         where  diagnoses_group like p_diagnoses_group
											   )
	) X;
 
    return have_diagnoses_group;

END;
$$ LANGUAGE plpgsql;

-- Create function to update the features of diagnoses in dataset 
CREATE OR REPLACE FUNCTION mimiciv.update_feature_diagnoses_cohort_newborn_dataset()
RETURNS void AS $$
DECLARE
	fila RECORD;
BEGIN
  FOR fila IN SELECT subject_id, hadm_id 
			  FROM   cohort_newborn_dataset 
  LOOP
		UPDATE 	cohort_newborn_dataset
        SET    	gdg_01 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_01')
			   	, gdg_02 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_02')
			   	, gdg_03 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_03')
				, gdg_04 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_04')
				, gdg_05 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_05')
				, gdg_06 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_06')
				, gdg_07 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_07')
				, gdg_08 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_08')
				, gdg_09 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_09')
				, gdg_10 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_10')
				, gdg_11 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_11')
				, gdg_12 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_12')
				, gdg_13 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_13')
				, gdg_14 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_14')
				, gdg_15 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_15')
				, gdg_16 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_16')
				, gdg_17 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_17')
				, gdg_18 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_18')
				, gdg_19 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_19')
				, gdg_20 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_20')
				, gdg_21 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_21')
				, gdg_22 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_22')
				, gdg_23 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_23')
				, gdg_24 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_24')
				, gdg_25 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_25')
				, gdg_26 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_26')
				, gdg_27 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_27')
				, gdg_28 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_28')
				, gdg_29 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_29')
				, gdg_30 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_30')
				, gdg_31 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_31')
				, gdg_32 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_32')
				, gdg_33 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_33')
				, gdg_34 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_34')
				, gdg_35 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_35')
				, gdg_36 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_36')
				, gdg_37 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_37')
				, gdg_38 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_38')
				, gdg_39 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_39')
				, gdg_40 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_40')
				, gdg_41 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_41')
				, gdg_42 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_42')
				, gdg_43 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_43')
				, gdg_44 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_44')
				, gdg_45 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_45')
				, gdg_46 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_46')
				, gdg_47 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_47')
				, gdg_48 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_48')
				, gdg_49 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_49')
				, gdg_50 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_50')
				, gdg_51 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_51')
				, gdg_52 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_52')
				, gdg_53 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_53')
				, gdg_54 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_54')
				, gdg_55 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_55')
				, gdg_56 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_56')
				, gdg_57 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_57')
				, gdg_58 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_58')
				, gdg_59 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_59')
				, gdg_60 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_60')
				, gdg_61 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_61')
				, gdg_62 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_62')
				, gdg_63 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_63')
				, gdg_64 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_64')
				, gdg_65 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_65')
				, gdg_66 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_66')
				, gdg_67 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_67')
				, gdg_68 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_68')
				, gdg_69 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_69')
				, gdg_70 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_70')
				, gdg_71 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_71')
			    , gdg_72 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_72')
				, gdg_73 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_73')
                , gdg_74 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_74')
				, gdg_75 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_75')
				, gdg_76 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_76')
				, gdg_77 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_77')
				, gdg_78 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_78')
				, gdg_79 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_79')
				, gdg_80 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_80')
				, gdg_81 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_81')
				, gdg_82 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_82')
				, gdg_83 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_83')
				, gdg_84 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_84')
				, gdg_85 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_85')
				, gdg_86 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_86')
				, gdg_87 = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'GDG_87')
				, gdg_death_atypical = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'death_atypical')
				, gdg_diagnoses_excluded = mimiciv.get_have_diagnoses_group(fila.subject_id, fila.hadm_id, 'diagnoses_excluded')

		WHERE  subject_id = fila.subject_id
		AND    hadm_id    = fila.hadm_id;
	END LOOP;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- SECTION 3 -- Chartevents item dictionary subset (MIMIC-IV metadata only)
-- ============================================================================

-- Create table to clasify chartevents features
 create table mimiciv.cohort_newborn_chartevents_items as
 select i.itemid, i.label, i.lownormalvalue, i.highnormalvalue, null as column_dataset
 from   mimiciv.d_items i 
 where  itemid in (220045, 220210, 220277, 220181, 220179, 220180, 223761, 226512, 220621, 220228, 220645, 227442, 225625, 220635, 220602, 227443, 225677, 220615, 220545, 225668, 223876, 220739, 223900, 223901, 228096, 220339, 226730, 227073);
 
-- Add primary key to the table cohort_newborn_chartevents_items
alter table mimiciv.cohort_newborn_chartevents_items add constraint pk_cn_chartevents_items primary key (itemid);

-- Add column to determine if the chartevents item apply to the Newborn Dataset
alter table mimiciv.cohort_newborn_chartevents_items add apply_newborn_dataset varchar(1);

-- Update chartevents item that applies to The newborn Dataset
update mimiciv.cohort_newborn_chartevents_items set apply_newborn_dataset = 'S'
where  itemid in (220045, 220210, 220277, 220181, 220179, 220180, 223761, 226512, 220621, 220228, 220645, 227442, 225625, 220635, 220602, 227443, 225677, 220615, 220545, 225668, 223876, 220739, 223900, 223901, 228096, 220339, 226730, 227073);
 


-- ============================================================================
-- SECTION 4 -- Neonatal cohort feature-extraction table
-- ============================================================================

-- Newborn Dataset
-- Include: 
-- * General Features
-- * Hospital Care Features
-- * ChartEvents Features (Min Date)
-- Not include:
-- * Feature Diagnoses

create table mimiciv.cohort_newborn_dataset as
select K.*
from 
(
	select Y.subject_id
	       , Y.hadm_id
	       , Y.stay_id	       
	       , Y.dob
	       , Y.gender
	       , Y.admission_count
	       , Y.ethnicity
	       , Y.insurance 
	       , Y.language
	       , Y.admission_type
	       , Y.admission_location
	       , Y.icu_stay
	       , Y.icu_stay_count
	       , Y.diagnoses_count
	       , Y.deathtime
	       , Y.outcome	       
		   , (
			    select max(c.valuenum)
			    from   mimiciv.chartevents c
			    where  c.subject_id = Y.subject_id
			    and    c.hadm_id    = Y.hadm_id
			    and    c.stay_id    = Y.stay_id
			    and    c.itemid     = 220045   
			    and    c.valuenum is not null
			    and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220045
								     and    c2.valuenum is not null
								    )
			 ) as heart_rate			 
		   , (
            	select max(c.valuenum)
           	 	from   mimiciv.chartevents c
            	where  c.subject_id = Y.subject_id
            	and    c.hadm_id    = Y.hadm_id
            	and    c.stay_id    = Y.stay_id
            	and    c.itemid     = 220210
            	and    c.valuenum is not null
            	and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220210  
								     and    c2.valuenum is not null
								    )
           	 ) as  Respiratory_rate
           , (
            	select max(c.valuenum)
            	from   mimiciv.chartevents c
            	where  c.subject_id = Y.subject_id
            	and    c.hadm_id    = Y.hadm_id
            	and    c.stay_id    = Y.stay_id
            	and    c.itemid     = 220277
            	and    c.valuenum is not null
            	and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220277   
								     and    c2.valuenum is not null
								    )
           	 ) as  O2_Saturation
           , (
            	select max(c.valuenum)
            	from   mimiciv.chartevents c
            	where  c.subject_id = Y.subject_id
            	and    c.hadm_id    = Y.hadm_id
            	and    c.stay_id    = Y.stay_id
            	and    c.itemid     = 220181
            	and    c.valuenum is not null
            	and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220181    
								     and    c2.valuenum is not null
								    )
             ) as Pressure_blood_mean
            , (
            	select max(c.valuenum)
            	from   mimiciv.chartevents c
            	where  c.subject_id = Y.subject_id
            	and    c.hadm_id    = Y.hadm_id
            	and    c.stay_id    = Y.stay_id
            	and    c.itemid     = 220179
            	and    c.valuenum is not null
            	and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220179    
								     and    c2.valuenum is not null
								    )
             ) as Pressure_blood_Systolic 
            , (
            	select max(c.valuenum)
            	from   mimiciv.chartevents c
            	where  c.subject_id = Y.subject_id
            	and    c.hadm_id    = Y.hadm_id
            	and    c.stay_id    = Y.stay_id
            	and    c.itemid     = 220180  
            	and    c.valuenum is not null
            	and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220180    
								     and    c2.valuenum is not null
								    )
             ) as Pressure_blood_Diastolic 
             , (
            	select max(c.valuenum)
            	from   mimiciv.chartevents c
            	where  c.subject_id = Y.subject_id
            	and    c.hadm_id    = Y.hadm_id
            	and    c.stay_id    = Y.stay_id
            	and    c.itemid     = 223761  
            	and    c.valuenum is not null
            	and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 223761   
								     and    c2.valuenum is not null
								    )
           	   ) as temperature_fahrenheit 
           	 , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 226512  
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 226512    
								     and    c2.valuenum is not null
								    )
	           ) as weight_admission 
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220621  
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220621   
								     and    c2.valuenum is not null
								    )
	           ) as glucose   
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220228  
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220228 
								     and    c2.valuenum is not null
								    )
	           ) as hemoglobine
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220645 
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220645
								     and    c2.valuenum is not null
								    )
	           ) as sodium
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 227442
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 227442  
								     and    c2.valuenum is not null
								    )
	           ) as potassium  
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 225625
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 225625
								     and    c2.valuenum is not null
								    )
	           ) as noionized_calcium   
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220635
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220635
								     and    c2.valuenum is not null
								    )
	           ) as magnesium    	         
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220602
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220602
								     and    c2.valuenum is not null
								    )
	           ) as chloride    
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 227443
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 227443
								     and    c2.valuenum is not null
								    )
	           ) as bicarbonate
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 225677
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 225677
								     and    c2.valuenum is not null
								    )
	           ) as phosphorus   
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220615
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220615
								     and    c2.valuenum is not null
								    )
	           ) as creatine 
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220545 
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220545
								     and    c2.valuenum is not null
								    )
	           ) as hematrocit
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 225668
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 225668
								     and    c2.valuenum is not null
								    )
	           ) as lactic_acid
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 223876
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 223876
								     and    c2.valuenum is not null
								    )
	           ) as apnea_interval
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220739
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220739
								     and    c2.valuenum is not null
								    )
	           ) as gcs_eye_opening
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 223900
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 223900
								     and    c2.valuenum is not null
								    )
	           ) as gcs_verbal_response 
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 223901
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 223901  
								     and    c2.valuenum is not null
								    )
	           ) as gcs_motor_response
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 228096
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 228096
								     and    c2.valuenum is not null
								    )
	           ) as richmond_ras_scale
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 220339
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 220339 
								     and    c2.valuenum is not null
								    )
	           ) as peep_set
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 226730
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 226730
								     and    c2.valuenum is not null
								    )
	           ) as height
	         , (
	            select max(c.valuenum)
	            from   mimiciv.chartevents c
	            where  c.subject_id = Y.subject_id
	            and    c.hadm_id    = Y.hadm_id
	            and    c.stay_id    = Y.stay_id
	            and    c.itemid     = 227073
	            and    c.valuenum is not null
	            and    c.charttime = (
			    					 select min(c2.charttime)
			                         from   mimiciv.chartevents c2
								     where  c2.subject_id = c.subject_id
								     and    c2.hadm_id    = c.hadm_id
								     and    c2.stay_id    = c.stay_id
								     and    c2.itemid     = 227073
								     and    c2.valuenum is not null
								    )
	           ) as anion_gap
	from   
	(
		select X.subject_id
		       , X.hadm_id
		       , X.dob
		       , X.gender
		       , X.admission_count
		       , a3.ethnicity
		       , a3.insurance 
		       , a3.language
		       , a3.admission_type
		       , a3.admission_location
		       , (
		          case when (
				          	select count(1)
				          	from   mimiciv.icustays i 
				          	where  i.subject_id = X.subject_id
				          	and    i.hadm_id    = X.hadm_id
				          	and    DATE_PART('day', date_trunc('day',i.intime) - X.dob) between -45 and 0
				          	) > 0
				      then  1
				      else  0
				  end
				 ) as icu_stay
			   , (
			   		select min(i.stay_id)
				    from   mimiciv.icustays i 
		          	where  i.subject_id = X.subject_id
		          	and    i.hadm_id    = X.hadm_id
		          	and    DATE_PART('day', date_trunc('day',i.intime) - X.dob) between -45 and 0
		         ) as stay_id	 
			   , (
			   		select count(1)
				    from   mimiciv.icustays i 
		          	where  i.subject_id = X.subject_id
		          	and    i.hadm_id    = X.hadm_id
		          	and    DATE_PART('day', date_trunc('day',i.intime) - X.dob) between -45 and 0
		         ) as icu_stay_count
		       , (
		       		select count(1)
		       		from   mimiciv.diagnoses_icd di 
		       		where  di.subject_id = X.subject_id
		       		and    di.hadm_id    = X.hadm_id
		         ) as diagnoses_count	         
		       , (
		          case when a3.deathtime is null 
		          then (
		                select min(a5.deathtime)
		                from   mimiciv.admissions a5
		                where  a5.subject_id = a3.subject_id
		                and    a5.deathtime is not null
		               )
		          else a3.deathtime
		          end
		         ) deathtime   
		       , (
		          case when a3.deathtime is null 
		          then (
		                case when (
		                 			select min(a5.deathtime)
		                			from   mimiciv.admissions a5
		                			where  a5.subject_id = a3.subject_id
		                			and    a5.deathtime is not null
		               			  ) is not null 
		               	     then 1
		               	     else 0
		               	end
		               	)
		          else 1
		          end
		         ) outcome
		from 
		(
			select p.subject_id
			       , p.dob
			       , p.gender
			       , (
			       		select Count(1)
			         	from   mimiciv.admissions a1
			         	where  a1.subject_id = p.subject_id
			         	and    TO_CHAR(a1.admittime, 'YYYYMM') >= '210912' 
				  	 	and    TO_CHAR(a1.admittime, 'YYYYMM')  <= '221410'
			         	and    DATE_PART('day', date_trunc('day',a1.admittime) - p.dob) between -45 and 0
			         ) as admission_count
			       , (		          
			          case when (
			       			   		select count(1) 
						        	from   mimiciv.admissions a2
						        	join   mimiciv.icustays icu2
						        	on     a2.subject_id  = icu2.subject_id
						        	and    a2.hadm_id     = icu2.hadm_id					        	
						        	where  icu2.subject_id = p.subject_id	
						        	and    TO_CHAR(a2.admittime, 'YYYYMM') >= '210912' 
						  	 		and    TO_CHAR(a2.admittime, 'YYYYMM')  <= '221410'
						  	 		and    DATE_PART('day', date_trunc('day',a2.admittime) - p.dob) between -45 and 0	
						        	and    DATE_PART('day', date_trunc('day',icu2.intime) - p.dob) between -45 and 0	
			       			  	) > 0
			               Then (
					         		select max(a2.hadm_id)
				          	 		from   mimiciv.admissions a2 
				          	 		where  a2.subject_id = p.subject_id
				          	 		and    TO_CHAR(a2.admittime, 'YYYYMM') >= '210912' 
						  	 		and    TO_CHAR(a2.admittime, 'YYYYMM')  <= '221410'
						  	 		and    DATE_PART('day', date_trunc('day',a2.admittime) - p.dob) between -45 and 0	
						  	 		and    (
								          	select count(1) 
								          	from   mimiciv.icustays icu2
								          	where  icu2.subject_id = a2.subject_id 
								          	and    icu2.hadm_id    = a2.hadm_id  
								          	and    DATE_PART('day', date_trunc('day',icu2.intime) - p.dob) between -45 and 0	
									   		) > 0
						    	)
						   else (
									select max(a2.hadm_id)
				          	 		from   mimiciv.admissions a2 
				          	 		where  a2.subject_id = p.subject_id
				          	 		and    TO_CHAR(a2.admittime, 'YYYYMM') >= '210912' 
						  	 		and    TO_CHAR(a2.admittime, 'YYYYMM')  <= '221410'
						  	 		and    DATE_PART('day', date_trunc('day', a2.admittime) - p.dob) between -45 and 0						
								)
					 end
		      		) as hadm_id	         
			from   mimiciv.patients p 
			where  p.dob is not null
			and    TO_CHAR(p.dob, 'YYYYMM')  >= '211001' 
			and    TO_CHAR(p.dob, 'YYYYMM')  <= '221410'	
		) X
		join mimiciv.admissions a3
		on   a3.subject_id = X.subject_id
		and  a3.hadm_id    = X.hadm_id 
		where X.hadm_id is not null
	) Y
) K;

-- Add primary key to the table: 
-- Add primary key to the table
alter table mimiciv.cohort_newborn_dataset add constraint pk_cn_dataset primary key (subject_id, hadm_id);

-- NOTE: the original working script also contained several ad-hoc data-quality
-- exploration queries here (row counts, dob-vs-admittime checks) and a separate,
-- unused CREATE OR REPLACE VIEW cohort_newborn_uci, both scratch work not required
-- to reproduce cohort_newborn_dataset (already fully built above) -- omitted for clarity.



-- ============================================================================
-- SECTION 5 -- Add the 86 diagnosis-group boolean columns to the dataset
-- ============================================================================

-- Create feature in Dataset
alter table mimiciv.cohort_newborn_dataset add column gdg_01 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_02 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_03 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_04 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_05 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_06 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_07 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_08 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_09 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_10 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_11 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_12 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_13 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_14 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_15 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_16 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_17 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_18 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_19 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_20 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_21 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_22 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_23 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_24 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_25 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_26 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_27 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_28 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_29 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_30 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_31 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_32 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_33 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_34 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_35 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_36 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_37 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_38 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_39 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_40 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_41 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_42 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_43 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_44 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_45 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_46 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_47 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_48 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_49 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_50 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_51 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_52 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_53 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_54 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_55 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_56 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_57 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_58 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_59 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_60 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_61 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_62 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_63 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_64 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_65 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_66 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_67 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_68 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_69 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_70 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_71 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_72 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_73 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_74 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_75 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_76 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_77 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_78 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_79 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_80 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_81 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_82 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_83 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_84 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_85 boolean; 
alter table mimiciv.cohort_newborn_dataset add column gdg_86 boolean; 




-- ============================================================================
-- After running the sections above, populate the gdg_01..gdg_86 columns by
-- calling the function created in Section 2 (this is also done automatically
-- by the notebook, cell 10, via libraries/database.update_feature_diagnoses_dataset):
--
--   SELECT mimiciv.update_feature_diagnoses_cohort_newborn_dataset();
-- ============================================================================
