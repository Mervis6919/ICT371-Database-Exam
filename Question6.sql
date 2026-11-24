-- Question 6: Monthly Payroll Processing

-- (a) Database and seed data
CREATE TABLE employees (
  employee_id SERIAL PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
  payroll_id SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month DATE NOT NULL,
  gross_pay NUMERIC(12,2) NOT NULL,
  net_pay   NUMERIC(12,2) NOT NULL,
  CONSTRAINT uq_emp_month UNIQUE (employee_id, pay_month),
  -- Enforce pay_month to be the first day of the month
  CONSTRAINT chk_month_start CHECK (pay_month = date_trunc('month', pay_month)::date)
);

CREATE TABLE salary_audit (
  audit_id SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary NUMERIC(12,2), 
  new_salary NUMERIC(12,2),
  changed_at TIMESTAMP NOT NULL DEFAULT now()
);

-- Seed data (Active and Inactive employees)
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
('Alice Smith', 5000.00, 500.00, 200.00, TRUE),
('Bob Jones', 4000.00, 200.00, 100.00, TRUE),
('Charlie Brown', 6000.00, 0.00, 500.00, FALSE); -- Inactive

-- Data for at least two payroll months (Processed manually for seed)
INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay) VALUES
(1, '2024-01-01', 5500.00, 5300.00),
(2, '2024-01-01', 4200.00, 4100.00),
(1, '2024-02-01', 5500.00, 5300.00);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT) RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE v_net NUMERIC(12,2);
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee %', p_employee_id; END IF;
  
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay calculated for employee % (%)', p_employee_id, v_net;
  END IF;
  
  RETURN v_net;
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC(12,2);
BEGIN
  IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
    RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
  END IF;

  FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees WHERE active ORDER BY employee_id LOOP

    v_net := fn_net_pay(r.employee_id); -- Fails whole call if invalid

    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING; -- Leave existing row unchanged
  END LOOP;
END; $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_employees_au AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW EXECUTE FUNCTION trg_salary_audit();

-- (e) View
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p 
JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index
-- Avoid duplicating UNIQUE (employee_id, pay_month), so just index pay_month
CREATE INDEX idx_payroll_month ON payroll (pay_month);

-- (g) Scheduled job
-- Note: requires pg_cron extension
-- SELECT cron.schedule('monthly-payroll', '0 2 1 * *',
--  $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);
