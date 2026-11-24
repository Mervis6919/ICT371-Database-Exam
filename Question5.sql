-- Question 5: Hostel Room Allocation

-- (a) Database and seed data
CREATE TABLE Students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE Rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE Allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES Students(student_id),
    room_id INT NOT NULL REFERENCES Rooms(room_id),
    allocated_on DATE NOT NULL DEFAULT CURRENT_DATE,
    released_on DATE,
    status VARCHAR(10) NOT NULL,
    CONSTRAINT chk_status CHECK (status IN ('ACTIVE', 'ENDED')),
    -- ACTIVE requires released_on NULL; ENDED requires a release date
    CONSTRAINT chk_dates CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL REFERENCES Rooms(room_id),
    occupied_beds INT NOT NULL,
    free_beds INT NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- Seed data
INSERT INTO Students (student_number, full_name) VALUES 
('S001', 'Alice'), ('S002', 'Bob'), ('S003', 'Charlie');

INSERT INTO Rooms (room_number, capacity) VALUES 
('Room A', 2), -- Will be full
('Room B', 3), -- Will be partly occupied
('Room C', 1); -- Will be empty

INSERT INTO Allocations (student_id, room_id, allocated_on, status) VALUES
(1, 1, CURRENT_DATE - 10, 'ACTIVE'),
(2, 1, CURRENT_DATE - 5, 'ACTIVE'), -- Room A is now full (2/2)
(3, 2, CURRENT_DATE - 2, 'ACTIVE'); -- Room B is partly occupied (1/3)

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT) RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_used INT;
BEGIN
  SELECT capacity INTO v_cap FROM Rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;

  SELECT COUNT(*) INTO v_used
  FROM Allocations WHERE room_id = p_room_id AND status = 'ACTIVE';

  RETURN v_cap - v_used;
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(
  p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM Students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;

  PERFORM 1 FROM Rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;

  IF p_allocated_on IS NULL THEN RAISE EXCEPTION 'allocated_on is required'; END IF;

  IF EXISTS (SELECT 1 FROM Allocations
              WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;

  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % has no free beds', p_room_id;
  END IF;

  INSERT INTO Allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END; $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_allocation_rules() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_used INT;
BEGIN
  IF NEW.status <> 'ACTIVE' THEN RETURN NEW; END IF;

  SELECT capacity INTO v_cap FROM Rooms WHERE room_id = NEW.room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', NEW.room_id; END IF;

  -- Exclude the row being updated from the count
  SELECT COUNT(*) INTO v_used
  FROM Allocations
  WHERE room_id = NEW.room_id AND status = 'ACTIVE'
    AND allocation_id <> COALESCE(NEW.allocation_id, -1);

  IF v_used + 1 > v_cap THEN
    RAISE EXCEPTION 'Room % is full (% of % beds in use)', NEW.room_id, v_used, v_cap;
  END IF;

  IF EXISTS (SELECT 1 FROM Allocations
              WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                AND allocation_id <> COALESCE(NEW.allocation_id, -1)) THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
  END IF;

  RETURN NEW;
END; $$;

CREATE TRIGGER trg_allocation_rules_biu
BEFORE INSERT OR UPDATE ON Allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_rules();

-- (e) View
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_number,
       r.capacity,
       COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
FROM Rooms r
LEFT JOIN Allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Index
CREATE INDEX idx_alloc_active_room ON Allocations (room_id) WHERE status = 'ACTIVE';

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE,
         r.room_id,
         COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE'),
         r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')
  FROM Rooms r
  LEFT JOIN Allocations a ON a.room_id = r.room_id
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END; $$;

-- Note: requires pg_cron extension
-- SELECT cron.schedule('nightly-occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);
