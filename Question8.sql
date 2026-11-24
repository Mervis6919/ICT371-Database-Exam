-- Question 8: Transport Fleet Maintenance

-- (a) Database and seed data
CREATE TABLE vehicles (
  vehicle_id SERIAL PRIMARY KEY,
  registration VARCHAR(20) NOT NULL UNIQUE,
  current_odometer INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT chk_service CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
  trip_id SERIAL PRIMARY KEY,
  vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT NOT NULL CHECK (end_odometer >= 0),
  CONSTRAINT chk_trip_km CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
  vehicle_id INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on DATE NOT NULL
);

-- Seed data: 3 vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('ABC-123', 10000, 4000), -- 6000 km since service (DUE)
('XYZ-789', 25000, 22000), -- 3000 km since service (NOT DUE)
('DEF-456', 5000, 5000);   -- 0 km since service (NOT DUE)

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE v_km INT;
BEGIN
  SELECT current_odometer - last_service_odometer INTO v_km
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id; END IF;
  
  RETURN v_km >= 5000;
END; $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_trip(
  p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id; END IF;

  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
  END IF;

  -- Trigger checks start against current odometer and advances the odometer
  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END; $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_current INT;
BEGIN
  SELECT current_odometer INTO v_current
  FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', NEW.vehicle_id; END IF;

  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'Trip must start at the vehicle''s current odometer % (got %)',
                    v_current, NEW.start_odometer;
  END IF;
  
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: end (%) <= start (%)',
                    NEW.end_odometer, NEW.start_odometer;
  END IF;

  -- Advances exactly once
  UPDATE vehicles SET current_odometer = NEW.end_odometer 
   WHERE vehicle_id = NEW.vehicle_id;

  RETURN NEW;
END; $$;

CREATE TRIGGER trg_trips_bi BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- Adding 6 trips through the procedure AFTER the trigger is installed (as required)
-- Note: The trigger updates the odometer, so each start must match the previous end.
CALL pr_record_trip(2, CURRENT_DATE - 5, 25000, 25200);
CALL pr_record_trip(2, CURRENT_DATE - 4, 25200, 25500);
CALL pr_record_trip(3, CURRENT_DATE - 3, 5000, 5300);
CALL pr_record_trip(1, CURRENT_DATE - 2, 10000, 10500);
CALL pr_record_trip(2, CURRENT_DATE - 1, 25500, 26000);
CALL pr_record_trip(3, CURRENT_DATE, 5300, 5500);

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- (f) Index
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

EXPLAIN (ANALYZE)
SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  -- Insert or update alerts for vehicles that are due
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;

  -- Remove alerts for vehicles that are no longer due
  DELETE FROM service_alerts sa
  WHERE NOT EXISTS (
    SELECT 1 FROM vehicles v
    WHERE v.vehicle_id = sa.vehicle_id
      AND v.current_odometer - v.last_service_odometer >= 5000
  );
END; $$;

-- Note: requires pg_cron extension
-- SELECT cron.schedule('weekly-service-alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);
