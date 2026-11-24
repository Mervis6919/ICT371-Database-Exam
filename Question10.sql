-- Question 10: Scholarship Application Assessment

-- (a) Database and seed data
CREATE TABLE students (
  student_id SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
  application_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on DATE NOT NULL DEFAULT CURRENT_DATE,
  status VARCHAR(10) NOT NULL DEFAULT 'PENDING',
  CONSTRAINT chk_app_status CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
  audit_id SERIAL PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status VARCHAR(10), 
  new_status VARCHAR(10),
  changed_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Seed data
INSERT INTO students (student_number, full_name) VALUES 
('S001', 'Alice Banda'), 
('S002', 'Bob Phiri'), 
('S003', 'Charlie Mumba');

-- Six PENDING applications covering qualifying, non-qualifying, and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
(1, 20, 2500, 85, CURRENT_DATE - 10, 'PENDING'), -- Qualifies
(1, 18, 3000, 70, CURRENT_DATE - 9, 'PENDING'),  -- Boundary (Qualifies exactly)
(2, 26, 2000, 90, CURRENT_DATE - 8, 'PENDING'),  -- Non-qualifying (Age too high)
(2, 22, 3500, 80, CURRENT_DATE - 7, 'PENDING'),  -- Non-qualifying (Income too high)
(3, 23, 1500, 65, CURRENT_DATE - 6, 'PENDING'),  -- Non-qualifying (Mark too low)
(3, 19, 2999, 71, CURRENT_DATE - 5, 'PENDING');  -- Qualifies

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'All three inputs are required';
  END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive (got %)', p_age; END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income cannot be negative'; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be between 0 and 100'; END IF;

  RETURN p_age BETWEEN 18 AND 25          -- Inclusive bounds
     AND p_income <= 3000
     AND p_mark >= 70;
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE r applications%ROWTYPE; v_eligible BOOLEAN;
BEGIN
  SELECT * INTO r FROM applications
   WHERE application_id = p_application_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown application %', p_application_id;
  END IF;
  IF r.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % has already been assessed (% )',
                    p_application_id, r.status;
  END IF;

  v_eligible := fn_scholarship_eligible(r.age_at_application, r.monthly_income, r.average_mark);

  UPDATE applications
     SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
   WHERE application_id = p_application_id;
END; $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_applications_au AFTER UPDATE OF status ON applications
FOR EACH ROW EXECUTE FUNCTION trg_decision_audit();

-- (e) View (Income deliberately omitted)
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a 
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index
CREATE INDEX idx_apps_status_submitted ON applications (status, submitted_on);

EXPLAIN (ANALYZE)
SELECT * FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications
            WHERE status = 'PENDING' ORDER BY application_id LOOP
    BEGIN
      CALL pr_assess_application(r.application_id);   -- Only PENDING gets assessed
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Application % skipped: %', r.application_id, SQLERRM;
    END;
  END LOOP;
END; $$;

-- Note: requires pg_cron extension
-- SELECT cron.schedule('weekly-assess-pending', '0 8 * * 1', $$CALL pr_assess_pending()$$);
