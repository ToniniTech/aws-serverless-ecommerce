CREATE INDEX idx_order_outbox_outstanding_created_at
    ON order_outbox (created_at)
    WHERE status IN ('PENDING', 'PROCESSING');
