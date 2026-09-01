CREATE INDEX idx_payment_outbox_outstanding_created_at
    ON payment_outbox (created_at)
    WHERE status IN ('PENDING', 'PROCESSING');
