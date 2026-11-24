-- Question 3: Library Returns and Overdue Fines

-- (a) Database and seed data
CREATE TABLE Books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

CREATE TABLE Loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES Books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES Loans(loan_id),
    old_returned_on DATE, 
    new_returned_on DATE,
    changed_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0,
    total_fine NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Seed data
INSERT INTO Books (title) VALUES 
('The Great Gatsby'), 
('1984'), 
('To Kill a Mockingbird');

-- Six loans: including an open overdue loan, an on-time loan, and a returned loan
INSERT INTO Loans (book_id, borrower_name, borrowed_on, due_on, returned_on) VALUES
(1, 'Alice', CURRENT_DATE - 20, CURRENT_DATE - 5, NULL), -- Open overdue
(2, 'Bob', CURRENT_DATE - 10, CURRENT_DATE + 5, NULL),   -- On-time (not overdue yet)
(3, 'Charlie', CURRENT_DATE - 15, CURRENT_DATE - 2, CURRENT_DATE - 2), -- Returned on due date
(1, 'David', CURRENT_DATE - 30, CURRENT_DATE - 10, CURRENT_DATE - 5),  -- Returned late (5 days)
(2, 'Eve', CURRENT_DATE - 5, CURRENT_DATE + 10, NULL),   -- On-time
(3, 'Frank', CURRENT_DATE - 25, CURRENT_DATE - 15, NULL); -- Open overdue

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE) RETURNS NUMERIC(10,2)
LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE; v_days INT;
BEGIN
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'p_as_of is required'; END IF;

  SELECT due_on, returned_on INTO v_due, v_ret FROM Loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan %', p_loan_id; END IF;

  -- Use earlier of as-of date and return date
  v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));
  -- Minimum of zero days
  v_days := GREATEST(v_end - v_due, 0);      
  RETURN v_days * 2; -- K2 per day
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_ret DATE; v_fine NUMERIC(10,2);
BEGIN
  IF p_returned_on IS NULL THEN RAISE EXCEPTION 'returned_on is required'; END IF;

  SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
    FROM Loans WHERE loan_id = p_loan_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan %', p_loan_id; END IF;
  IF v_ret IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
  END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date % is before borrowed_on %', p_returned_on, v_borrowed;
  END IF;

  v_fine := fn_loan_fine(p_loan_id, p_returned_on);

  UPDATE Loans
     SET returned_on = p_returned_on,
         fine_amount = v_fine
   WHERE loan_id = p_loan_id;
END; $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_loan_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_loans_au AFTER UPDATE OF returned_on ON Loans
FOR EACH ROW EXECUTE FUNCTION trg_loan_audit();

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM Loans l 
JOIN Books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- (f) Index
CREATE INDEX idx_loans_book_open ON Loans (book_id) WHERE returned_on IS NULL;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
DECLARE v_cnt INT; v_sum NUMERIC(12,2);
BEGIN
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'p_as_of is required'; END IF;

  SELECT COUNT(*), COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)),0)
    INTO v_cnt, v_sum
  FROM Loans l
  WHERE (l.returned_on IS NULL OR l.returned_on > p_as_of)
    AND l.due_on < p_as_of;

  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  VALUES (p_as_of, v_cnt, v_sum)
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END; $$;

-- Note: requires pg_cron extension
-- SELECT cron.schedule('daily-overdue', '10 0 * * *', $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
