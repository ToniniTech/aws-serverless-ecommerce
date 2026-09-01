CREATE TABLE payment_outbox (
    id UUID PRIMARY KEY,
    event_id VARCHAR(128) NOT NULL UNIQUE,
    event_type VARCHAR(64) NOT NULL CHECK (event_type IN ('PaymentProcessed', 'PaymentFailed')),
    aggregate_id VARCHAR(128) NOT NULL,
    payment_record_id UUID NOT NULL,
    payload JSONB NOT NULL,
    status VARCHAR(16) NOT NULL CHECK (status IN ('PENDING', 'PROCESSING', 'PUBLISHED')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL,
    claimed_at TIMESTAMPTZ,
    published_at TIMESTAMPTZ,
    last_error VARCHAR(1000),
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_payment_outbox_payment FOREIGN KEY (payment_record_id) REFERENCES payments (id),
    CONSTRAINT ck_payment_outbox_state CHECK (
        (status = 'PENDING' AND published_at IS NULL)
        OR (status = 'PROCESSING' AND claimed_at IS NOT NULL AND published_at IS NULL)
        OR (status = 'PUBLISHED' AND published_at IS NOT NULL)
    )
);

CREATE INDEX idx_payment_outbox_status_next_created
    ON payment_outbox (status, next_attempt_at, created_at);
