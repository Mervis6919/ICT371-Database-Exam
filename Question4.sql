-- Question 4: Clinic Appointment Scheduling

-- (a) Database and seed data
CREATE TABLE Patients (
    patient_id SERIAL PRIMARY KEY, 
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE Doctors (
    doctor_id SERIAL PRIMARY KEY, 
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE Appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INT NOT NULL REFERENCES Patients(patient_id),
    doctor_id INT NOT NULL REFERENCES Doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL,
    status VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT chk_slot CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00'))
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL DEFAULT 0,
    attended_count INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
);

-- Seed data
INSERT INTO Patients (full_name) VALUES ('John Doe'), ('Jane Smith'), ('Sam Brown');
INSERT INTO Doctors (full_name) VALUES ('Dr. Adams'), ('Dr. Baker'), ('Dr. Clark');

INSERT INTO Appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
(1, 1, CURRENT_DATE, '09:00', 'BOOKED'),
(2, 1, CURRENT_DATE, '10:00', 'BOOKED'),
(3, 2, CURRENT_DATE, '09:00', 'BOOKED'),
(1, 2, CURRENT_DATE + 1, '11:00', 'CANCELLED'),
(2, 3, CURRENT_DATE + 1, '09:00', 'BOOKED'),
(3, 3, CURRENT_DATE + 1, '12:00', 'BOOKED');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE v_cnt INT;
BEGIN
  PERFORM 1 FROM Doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;

  SELECT COUNT(*) INTO v_cnt
  FROM Appointments
  WHERE doctor_id = p_doctor_id
    AND appointment_day = p_day
    AND status <> 'CANCELLED';

  RETURN v_cnt;
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(
  p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM Patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient %', p_patient_id; END IF;

  PERFORM 1 FROM Doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor %', p_doctor_id; END IF;

  IF p_day IS NULL OR p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Appointment date must be today or later';
  END IF;

  IF p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
    RAISE EXCEPTION 'Unsupported slot %', p_slot;
  END IF;

  INSERT INTO Appointments (patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED'); 
END; $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_appt_no_clash() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' AND EXISTS (
    SELECT 1 FROM Appointments a
    WHERE a.doctor_id = NEW.doctor_id
      AND a.appointment_day = NEW.appointment_day
      AND a.slot_time = NEW.slot_time
      AND a.status <> 'CANCELLED'
      AND a.appointment_id <> COALESCE(NEW.appointment_id, -1)
  ) THEN
    RAISE EXCEPTION 'Slot % on % is already taken for doctor %',
                    NEW.slot_time, NEW.appointment_day, NEW.doctor_id;
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_appt_no_clash_biu
BEFORE INSERT OR UPDATE ON Appointments
FOR EACH ROW EXECUTE FUNCTION trg_appt_no_clash();

-- (e) View
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM Appointments a
JOIN Patients p ON p.patient_id = a.patient_id
JOIN Doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- (f) Index
CREATE INDEX idx_appt_day_doctor ON Appointments (appointment_day, doctor_id);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'p_day is required'; END IF;

  INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM Appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END; $$;

-- Note: requires pg_cron extension
-- SELECT cron.schedule('daily-clinic-summary', '0 1 * * *', $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
