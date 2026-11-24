-- Question 2: University Fee Payments

-- (a) Database and seed data
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
  payment_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
  audit_id   SERIAL PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL DEFAULT 0,
  total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Seed data: 3 students, different fee balances
INSERT INTO students (student_number, full_name, fee_due) VALUES
('ST001', 'John Doe', 5000.00),
('ST002', 'Jane Smith', 4500.00),
('ST003', 'Mike Johnson', 6000.00); -- This student will initially have no payments

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT) RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE v_due NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
  SELECT fee_due INTO v_due FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;

  SELECT COALESCE(SUM(amount),0) INTO v_paid
    FROM payments WHERE student_id = p_student_id;

  RETURN v_due - v_paid;
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero';
  END IF;
  IF p_paid_on IS NULL THEN RAISE EXCEPTION 'paid_on is required'; END IF;

  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;

  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;

  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);
END; $$;

-- Loading 6 valid payments through the procedure
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 5);
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 4);
CALL pr_receive_payment(2, 4500.00, CURRENT_DATE - 3); -- Fully settles Jane Smith
CALL pr_receive_payment(1, 2500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 100.00, CURRENT_DATE - 1); -- This will fail (overpayment)
CALL pr_receive_payment(2, -50.00, CURRENT_DATE - 1); -- This will fail (negative)
CALL pr_receive_payment(1, 0.00, CURRENT_DATE);       -- This will fail (zero)

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_payment_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_payments_ai AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount),0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount),0) > 0;

-- (f) Index
CREATE INDEX idx_payments_student_paided ON payments (student_id, paid_on);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'p_day is required'; END IF;

  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount),0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END; $$;

-- Note: requires pg_cron extension (uncomment to schedule)
-- SELECT cron.schedule('daily-collections', '0 1 * * *', $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
