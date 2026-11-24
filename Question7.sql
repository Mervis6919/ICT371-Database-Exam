-- Question 7: Water Meter Readings and Billing

-- (a) Database and seed data
CREATE TABLE customers (
  customer_id SERIAL PRIMARY KEY, 
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
  reading_id SERIAL PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers(customer_id),
  reading_month DATE NOT NULL,
  previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
  CONSTRAINT uq_cust_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
  bill_id SERIAL PRIMARY KEY,
  reading_id INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  due_on DATE NOT NULL,
  CONSTRAINT chk_paid CHECK (amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- Seed data: 3 customers, 6 readings (zero, exactly 10, and above 10 units)
INSERT INTO customers (full_name) VALUES 
('John Doe'), 
('Jane Smith'), 
('Mike Johnson');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
(1, '2024-01-01', 100, 100), -- 0 units
(1, '2024-02-01', 100, 110), -- 10 units
(2, '2024-01-01', 50, 65),   -- 15 units
(2, '2024-02-01', 65, 70),   -- 5 units
(3, '2024-01-01', 200, 215), -- 15 units
(3, '2024-02-01', 215, 215); -- 0 units

-- (b) Function
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE v_charge NUMERIC(12,2);
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Consumption must be a non-negative number';
  END IF;

  IF p_units <= 10 THEN
    v_charge := p_units * 5;
  ELSE
    v_charge := 10 * 5 + (p_units - 10) * 8; -- Band 2
  END IF;

  RETURN ROUND(v_charge, 2); -- Zero consumption returns 0.00
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_units NUMERIC(12,2);
BEGIN
  IF p_due_on IS NULL THEN RAISE EXCEPTION 'due_on is required'; END IF;

  SELECT current_reading - previous_reading INTO v_units
  FROM readings WHERE reading_id = p_reading_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading %', p_reading_id; END IF;

  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;

  INSERT INTO bills (reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END; $$;

-- Generating bills for the seed data to demonstrate functionality
CALL pr_generate_bill(1, CURRENT_DATE + 30); -- 0 units = K0.00
CALL pr_generate_bill(2, CURRENT_DATE - 5);  -- 10 units = K50.00 (Overdue)
CALL pr_generate_bill(3, CURRENT_DATE - 2);  -- 15 units = K90.00 (Overdue)

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_reading_validate() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.previous_reading < 0 OR NEW.current_reading < 0 THEN
    RAISE EXCEPTION 'Meter values cannot be negative';
  END IF;
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                    NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW; -- If rejected, row is never stored
END; $$;

CREATE TRIGGER trg_readings_biu BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_validate();

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- (f) Index
-- Partial index restricted to unpaid bills
CREATE INDEX idx_bills_due_unpaid ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN (ANALYZE)
SELECT * FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot (snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
  FROM bills WHERE amount_paid < charge
  ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END; $$;

-- Note: requires pg_cron extension
-- SELECT cron.schedule('daily-receivables', '30 0 * * *', $$CALL pr_refresh_receivables()$$);
