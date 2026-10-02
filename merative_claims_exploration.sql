-- =========================================================================
-- PROJECT DAYBREAK - BH SERVICE PERCENTILE PULL
-- Source:  HAT_MERATIVE_DB.DBO.MEDICAL_CLAIMS (claim-line level)
-- Scope:   CA, CO, TX, IL, WI, PA, MN | 21 procedure codes in 14 groups |
--          service year 2024 | all ages
-- Grain:   State x Year x Proc Code x POS x Rev Code x INN/OON
-- Metrics: P25 / P50 / P75 of per-unit allowed, unit count, claim line count
--
-- Rules:
--   1) Exclude claim lines with allowed <= 0
--   2) If a line bills more than 1 unit, divide allowed by units before
--      running percentiles
--   3) Line level, not claim level

-- Unit handling:
--   - per_unit_allowed = allowed / units only when units > 1; else allowed
--   - unit_count sums units; values below 1 (0, null, negative, 0.01) count as 1
--   - Lines with more than 24 units per service day are excluded as data
--     errors. No code in scope bills in increments smaller than one hour,
--     so this only catches clearly impossible values.
-- =========================================================================

USE ROLE HAT_ANALYST;
USE WAREHOUSE HAT_WH;


-- =========================================================================
-- STEP 1: LOOKUP TABLES (built once, reused by STEPS 2-4)
-- =========================================================================

-- 1a. Procedure groups -  descriptions from Sarit's email
CREATE OR REPLACE TEMPORARY TABLE DAYBREAK_PROC_GROUPS AS
SELECT column1 AS proc_code, column2 AS proc_code_group
FROM VALUES
    ('H0010', 'Residential / withdrawal management'),
    ('H0011', 'Residential / withdrawal management'),
    ('H0018', 'Short-term residential'),
    ('H0019', 'Long-term residential'),
    ('H2034', 'Lower-intensity residential'),
    ('H2036', 'Medically monitored residential'),
    ('H0015', 'IOP – SUD'),
    ('S9480', 'IOP – psychiatric'),
    ('H0035', 'PHP – mental health'),
    ('H2035', 'PHP / SUD'),
    ('S0201', 'PHP / SUD'),
    ('90791', 'Psychiatric assessment'),
    ('90792', 'Psychiatric assessment'),
    ('90832', 'Individual psychotherapy'),
    ('90834', 'Individual psychotherapy'),
    ('90837', 'Individual psychotherapy'),
    ('90833', 'Psychotherapy + E/M'),
    ('90836', 'Psychotherapy + E/M'),
    ('90838', 'Psychotherapy + E/M'),
    ('90853', 'Group psychotherapy'),
    ('90785', 'Interactive complexity');

-- 1b. CMS place-of-service codes
CREATE OR REPLACE TEMPORARY TABLE DAYBREAK_POS_LOOKUP AS
SELECT column1 AS pos_code, column2 AS pos_description
FROM VALUES
    ('01', 'Pharmacy'),
    ('02', 'Telehealth Provided Other than in Patient''s Home'),
    ('03', 'School'),
    ('04', 'Homeless Shelter'),
    ('09', 'Prison / Correctional Facility'),
    ('10', 'Telehealth Provided in Patient''s Home'),
    ('11', 'Office'),
    ('12', 'Home'),
    ('13', 'Assisted Living Facility'),
    ('14', 'Group Home'),
    ('15', 'Mobile Unit'),
    ('16', 'Temporary Lodging'),
    ('17', 'Walk-in Retail Health Clinic'),
    ('18', 'Place of Employment / Worksite'),
    ('19', 'Off Campus-Outpatient Hospital'),
    ('20', 'Urgent Care Facility'),
    ('21', 'Inpatient Hospital'),
    ('22', 'On Campus-Outpatient Hospital'),
    ('23', 'Emergency Room - Hospital'),
    ('24', 'Ambulatory Surgical Center'),
    ('25', 'Birthing Center'),
    ('26', 'Military Treatment Facility'),
    ('27', 'Outreach Site / Street'),
    ('31', 'Skilled Nursing Facility'),
    ('32', 'Nursing Facility'),
    ('33', 'Custodial Care Facility'),
    ('34', 'Hospice'),
    ('41', 'Ambulance - Land'),
    ('42', 'Ambulance - Air or Water'),
    ('49', 'Independent Clinic'),
    ('50', 'Federally Qualified Health Center'),
    ('51', 'Inpatient Psychiatric Facility'),
    ('52', 'Psychiatric Facility-Partial Hospitalization'),
    ('53', 'Community Mental Health Center'),
    ('54', 'Intermediate Care Facility / Individuals with Intellectual Disabilities'),
    ('55', 'Residential Substance Abuse Treatment Facility'),
    ('56', 'Psychiatric Residential Treatment Center'),
    ('57', 'Non-residential Substance Abuse Treatment Facility'),
    ('58', 'Non-residential Opioid Treatment Facility'),
    ('60', 'Mass Immunization Center'),
    ('61', 'Comprehensive Inpatient Rehabilitation Facility'),
    ('62', 'Comprehensive Outpatient Rehabilitation Facility'),
    ('65', 'End-Stage Renal Disease Treatment Facility'),
    ('66', 'PACE Center'),
    ('71', 'Public Health Clinic'),
    ('72', 'Rural Health Clinic'),
    ('81', 'Independent Laboratory'),
    ('95', 'Unassigned code (not a valid CMS POS)'),
    ('98', 'Unassigned code (not a valid CMS POS)'),
    ('99', 'Other Place of Service');

-- 1c. UB-04 revenue codes (covers codes with ~100+ lines in STEP 0a;
--     STEP 4a lists any remaining low-volume codes)
CREATE OR REPLACE TEMPORARY TABLE DAYBREAK_REV_LOOKUP AS
SELECT column1 AS rev_code, column2 AS rev_description
FROM VALUES
    ('0100', 'All-inclusive room & board plus ancillary'),
    ('0101', 'All-inclusive room & board'),
    ('0114', 'Room & board - private - psychiatric'),
    ('0116', 'Room & board - private - detoxification'),
    ('0118', 'Room & board - private - rehabilitation'),
    ('0124', 'Room & board - semi-private - psychiatric'),
    ('0126', 'Room & board - semi-private - detoxification'),
    ('0128', 'Room & board - semi-private - rehabilitation'),
    ('0129', 'Room & board - semi-private - other'),
    ('0134', 'Room & board - 3 & 4 beds - psychiatric'),
    ('0136', 'Room & board - 3 & 4 beds - detoxification'),
    ('0144', 'Room & board - deluxe private - psychiatric'),
    ('0150', 'Room & board - ward - general'),
    ('0154', 'Room & board - ward - psychiatric'),
    ('0156', 'Room & board - ward - detoxification'),
    ('0158', 'Room & board - ward - rehabilitation'),
    ('0169', 'Other room & board - other'),
    ('0240', 'All-inclusive ancillary - general'),
    ('0450', 'Emergency room - general'),
    ('0459', 'Emergency room - other'),
    ('0490', 'Ambulatory surgical care - general'),
    ('0510', 'Clinic - general'),
    ('0513', 'Clinic - psychiatric'),
    ('0519', 'Clinic - other'),
    ('0520', 'Freestanding clinic - general'),
    ('0521', 'Freestanding clinic - clinic visit by member to RHC / FQHC'),
    ('0529', 'Freestanding clinic - other'),
    ('0761', 'Treatment or observation room - treatment room'),
    ('0780', 'Telemedicine - general'),
    ('0900', 'Behavioral health treatment / services - general'),
    ('0901', 'Behavioral health - electroshock treatment'),
    ('0902', 'Behavioral health - milieu therapy'),
    ('0903', 'Behavioral health - play therapy'),
    ('0904', 'Behavioral health - activity therapy'),
    ('0905', 'Intensive outpatient services - psychiatric'),
    ('0906', 'Intensive outpatient services - chemical dependency'),
    ('0907', 'Community behavioral health program (day treatment)'),
    ('0911', 'Behavioral health - rehabilitation'),
    ('0912', 'Partial hospitalization - less intensive'),
    ('0913', 'Partial hospitalization - intensive'),
    ('0914', 'Behavioral health - individual therapy'),
    ('0915', 'Behavioral health - group therapy'),
    ('0916', 'Behavioral health - family therapy'),
    ('0917', 'Behavioral health - biofeedback'),
    ('0918', 'Behavioral health - testing'),
    ('0919', 'Behavioral health - other'),
    ('0929', 'Other diagnostic services - other'),
    ('0940', 'Other therapeutic services - general'),
    ('0942', 'Other therapeutic services - education / training'),
    ('0944', 'Other therapeutic services - drug rehabilitation'),
    ('0945', 'Other therapeutic services - alcohol rehabilitation'),
    ('0953', 'Other therapeutic services - chemical dependency (drug and alcohol)'),
    ('0960', 'Professional fees - general'),
    ('0961', 'Professional fees - psychiatric'),
    ('1000', 'Behavioral health accommodations - general'),
    ('1001', 'Residential treatment - psychiatric'),
    ('1002', 'Residential treatment - chemical dependency'),
    ('1003', 'Supervised living'),
    ('1004', 'Halfway house'),
    ('1005', 'Group home');


-- =========================================================================
-- STEP 2: BH LINE COHORT
-- 2-pass build: BH_LINES_ALL keeps everything (for the exclusion checks),
-- BH_LINES applies the exclusions and feeds the output.
-- This is the only step that reads MEDICAL_CLAIMS columns.
-- =========================================================================
CREATE OR REPLACE TEMPORARY TABLE BH_LINES_ALL AS
WITH src AS (
    SELECT
        c.MEMBER_ID,
        c.CLAIM_ID,
        c.CLAIM_LINE_ID,
        TRIM(c.EGEOLOC)                                                   AS state,   -- member state
        YEAR(c.SERVICE_FROM_DATE)                                         AS service_year,
        UPPER(TRIM(c.PROCEDURE_CODE))                                     AS proc_code,
        LPAD(TO_VARCHAR(c.PLACE_OF_SERVICE_CODE), 2, '0')                 AS pos_code,
        LPAD(NULLIF(TRIM(c.REVENUE_CODE), ''), 4, '0')                    AS rev_code,
        c.IN_PLAN_NETWORK_INDICATOR                                       AS inn_oon_raw,
        c.SERVICE_UNITS_QUANTITY                                          AS service_units_raw,
        GREATEST(DATEDIFF('day', c.SERVICE_FROM_DATE,
                          COALESCE(c.SERVICE_TO_DATE, c.SERVICE_FROM_DATE)) + 1, 1)
                                                                          AS service_days,
        c.ALLOWED_AMOUNT                                                  AS allowed_amount,
        c.CLAIM_STATUS                                                    AS claim_status,
        c.DATATYP                                                         AS datatyp
    FROM HAT_MERATIVE_DB.DBO.MEDICAL_CLAIMS c
    WHERE c.SERVICE_FROM_DATE BETWEEN '2024-01-01' AND '2024-12-31'
      AND c.ALLOWED_AMOUNT > 0                                            
      AND UPPER(TRIM(c.EGEOLOC)) IN (
            'CALIFORNIA', 'COLORADO', 'TEXAS', 'ILLINOIS',
            'WISCONSIN', 'PENNSYLVANIA', 'MINNESOTA')
)
SELECT
    s.*,
    g.proc_code_group,
    CASE s.inn_oon_raw
        WHEN 'Y' THEN 'INN'
        WHEN 'N' THEN 'OON'
        ELSE 'Unknown'
    END                                                                   AS inn_oon_flag,
    CASE WHEN s.service_units_raw > 24 * s.service_days THEN 1 ELSE 0 END AS units_suspect_flag,
    CASE WHEN s.service_units_raw >= 1 THEN s.service_units_raw ELSE 1 END AS units_for_count,
    CASE
        WHEN s.service_units_raw > 1 THEN s.allowed_amount / s.service_units_raw
        ELSE s.allowed_amount
    END                                                                   AS per_unit_allowed  
FROM src s
JOIN DAYBREAK_PROC_GROUPS g
    ON s.proc_code = g.proc_code;
 
CREATE OR REPLACE TEMPORARY TABLE BH_LINES AS
SELECT *
FROM BH_LINES_ALL
WHERE COALESCE(claim_status, '') <> 'REVERSED CLAIM'
  AND units_suspect_flag = 0; 
 
-- 2a. Exclusion waterfall - how many lines each rule removes
SELECT
    COUNT(*)                                                              AS lines_in_scope,
    SUM(CASE WHEN claim_status = 'REVERSED CLAIM' THEN 1 ELSE 0 END)      AS excl_reversed,
    SUM(CASE WHEN COALESCE(claim_status, '') <> 'REVERSED CLAIM'
              AND units_suspect_flag = 1 THEN 1 ELSE 0 END)               AS excl_suspect_units,
    (SELECT COUNT(*) FROM BH_LINES)                                       AS lines_kept
FROM BH_LINES_ALL;
 

 
-- What the suspect-units rule is catching (aggregated)
SELECT proc_code_group, service_units_raw, service_days, COUNT(*) AS lines
FROM BH_LINES_ALL
WHERE units_suspect_flag = 1
GROUP BY 1, 2, 3
ORDER BY lines DESC
LIMIT 50;
 
-- Lines by state and group - all 7 states should appear
SELECT state, proc_code_group, COUNT(*) AS line_count, COUNT(DISTINCT proc_code) AS distinct_procs
FROM BH_LINES
GROUP BY state, proc_code_group
ORDER BY state, proc_code_group;
 


-- =========================================================================
-- STEP 3: OUTPUT TABLE
-- =========================================================================

CREATE OR REPLACE TEMPORARY TABLE DAYBREAK_BH_PERCENTILES AS
SELECT
    b.state                                                           AS state,
    b.service_year                                                    AS year,
    b.proc_code                                                       AS proc_code,
    b.proc_code_group                                                 AS proc_code_group,
    b.pos_code                                                        AS pos_code,
    CASE WHEN b.pos_code IS NULL THEN 'No POS on line'
         ELSE COALESCE(p.pos_description, 'Not in lookup') END        AS pos_code_description,
    b.rev_code                                                        AS rev_code,
    CASE WHEN b.rev_code IS NULL THEN 'No rev code on line'
         ELSE COALESCE(r.rev_description, 'Not in lookup') END        AS rev_code_description,
    b.inn_oon_flag                                                    AS inn_oon_flag,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY b.per_unit_allowed), 2) AS p25,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY b.per_unit_allowed), 2) AS p50,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY b.per_unit_allowed), 2) AS p75,
    SUM(b.units_for_count)                                            AS unit_count,
    COUNT(*)                                                          AS claim_line_count
FROM BH_LINES b
LEFT JOIN DAYBREAK_POS_LOOKUP p ON b.pos_code = p.pos_code
LEFT JOIN DAYBREAK_REV_LOOKUP r ON b.rev_code = r.rev_code
GROUP BY
    b.state, b.service_year, b.proc_code, b.proc_code_group,
    b.pos_code, p.pos_description, b.rev_code, r.rev_description,
    b.inn_oon_flag;

-- 3a. Final output
SELECT *
FROM DAYBREAK_BH_PERCENTILES
ORDER BY state, year, proc_code_group, proc_code, pos_code, rev_code, inn_oon_flag;

