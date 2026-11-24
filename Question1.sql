-- Question 1: Pharmacy Stock and Daily Sales

-- (a) Database and seed data
CREATE TABLE medicines (
  medicine_id   SERIAL PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
  sale_id     SERIAL PRIMARY KEY,
  medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
  quantity    INTEGER NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
  audit_id    SERIAL PRIMARY KEY,
  medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INTEGER NOT NULL,
  new_qty     INTEGER NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INTEGER NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Seed data: at least three medicines
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg',  2.50, 100),
 ('Amoxicillin 250mg', 12.00,  40),
 ('Ibuprofen 200mg',    3.75,   8);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be a positive integer (got %)', p_quantity;
  END IF;

  SELECT unit_price INTO v_price
    FROM medicines WHERE medicine_id = p_medicine_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
  END IF;

  RETURN v_price * p_quantity;
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_stock INT; v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be positive';
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'sold_on is required';
  END IF;

  SELECT stock_qty, unit_price INTO v_stock, v_price
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
  END IF;

  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock for medicine %: % available, % requested',
                    p_medicine_id, v_stock, p_quantity;
  END IF;

  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

  UPDATE medicines
     SET stock_qty = stock_qty - p_quantity
   WHERE medicine_id = p_medicine_id;
END; $$;

-- Loading 6 valid sales through the procedure (as required in part a)
CALL pr_record_sale(1, 5, CURRENT_DATE - 1);
CALL pr_record_sale(2, 2, CURRENT_DATE - 1);
CALL pr_record_sale(3, 1, CURRENT_DATE - 1);
CALL pr_record_sale(1, 3, CURRENT_DATE);
CALL pr_record_sale(2, 1, CURRENT_DATE);
CALL pr_record_sale(3, 2, CURRENT_DATE);

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_medicines_stock_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_medicines_au
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_medicines_stock_audit();

-- (e) View
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

-- (f) Index
CREATE INDEX idx_sales_medicine_soldon ON sales (medicine_id, sold_on);

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'p_day is required'; END IF;

  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity),0), COALESCE(SUM(quantity * unit_price),0)
  FROM sales
  WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END; $$;

-- Note: requires pg_cron extension (uncomment to schedule)
-- SELECT cron.schedule('daily-sales-refresh', '15 0 * * *', $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
