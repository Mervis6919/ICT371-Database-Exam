-- Question 9: Farmer Cooperative Maize Deliveries

-- (a) Database and seed data
CREATE TABLE farmers (
  farmer_id SERIAL PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
  delivery_id SERIAL PRIMARY KEY,
  farmer_id INT NOT NULL REFERENCES farmers(farmer_id),
  grade VARCHAR(1) NOT NULL,
  weight_kg NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
  unit_rate NUMERIC(10,2) NOT NULL,
  total_value NUMERIC(12,2) NOT NULL,
  delivered_on DATE NOT NULL,
  is_paid BOOLEAN NOT NULL DEFAULT FALSE,
  CONSTRAINT chk_grade CHECK (grade IN ('A','B','C'))
);

CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_value  NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- Seed data
INSERT INTO farmers (farmer_number, full_name) VALUES 
('F001', 'Alice Mwansa'),
('F002', 'Bob Chanda'),
('F003', 'Charlie Zulu');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT) RETURNS NUMERIC(10,2)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_grade IS NULL THEN RAISE EXCEPTION 'Grade is required'; END IF;

  CASE UPPER(TRIM(p_grade))
    WHEN 'A' THEN RETURN 5;
    WHEN 'B' THEN RETURN 4;
    WHEN 'C' THEN RETURN 3;
    ELSE RAISE EXCEPTION 'Unsupported grade %', p_grade;
  END CASE;
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
  p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown farmer %', p_farmer_id; END IF;

  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be a positive number';
  END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Delivery date is required'; END IF;

  -- Trigger supplies unit_rate and total_value
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, UPPER(TRIM(p_grade)), p_weight, p_date, FALSE);
END; $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_delivery_pricing() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'weight_kg must be positive (got %)', NEW.weight_kg;
  END IF;

  -- Ensure direct SQL follows the same pricing rule
  NEW.grade      := UPPER(TRIM(NEW.grade));
  NEW.unit_rate  := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_deliveries_pricing_biu
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_pricing();

-- Loading 6 deliveries through the procedure AFTER the trigger is installed
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 2); -- Unpaid
CALL pr_receive_delivery(1, 'B', 50, CURRENT_DATE - 1);  -- Unpaid
CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE - 1); -- Unpaid
CALL pr_receive_delivery(2, 'A', 80, CURRENT_DATE);      -- Unpaid
CALL pr_receive_delivery(3, 'B', 120, CURRENT_DATE);     -- Unpaid
-- Direct SQL insert to demonstrate trigger logic works on raw SQL too
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) 
VALUES (1, 'C', 300, CURRENT_DATE, TRUE);                -- Paid

-- (e) View
-- Include farmers with no unpaid deliveries and show 0
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN (ANALYZE)
SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'p_day is required'; END IF;

  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg),0), COALESCE(SUM(total_value),0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END; $$;

-- Note: requires pg_cron extension
-- SELECT cron.schedule('daily-purchases', '30 1 * * *', $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
