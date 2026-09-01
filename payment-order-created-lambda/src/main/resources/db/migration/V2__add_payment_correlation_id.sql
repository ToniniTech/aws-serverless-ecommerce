ALTER TABLE payments ADD COLUMN correlation_id VARCHAR(128);
UPDATE payments SET correlation_id = source_event_id WHERE correlation_id IS NULL;
ALTER TABLE payments ALTER COLUMN correlation_id SET NOT NULL;
