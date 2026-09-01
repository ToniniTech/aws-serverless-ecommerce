CREATE TABLE payments (
    id UUID PRIMARY KEY,
    payment_id VARCHAR(64) NOT NULL,
    order_id VARCHAR(128) NOT NULL,
    source_event_id VARCHAR(128) NOT NULL,
    gateway_idempotency_key VARCHAR(128) NOT NULL,
    customer_id VARCHAR(128) NOT NULL,
    customer_email VARCHAR(320) NOT NULL,
    amount NUMERIC(19, 2) NOT NULL CHECK (amount > 0),
    currency VARCHAR(3) NOT NULL CHECK (currency = UPPER(currency)),
    status VARCHAR(16) NOT NULL CHECK (status IN ('PROCESSING', 'COMPLETED', 'FAILED')),
    gateway_transaction_id VARCHAR(128),
    failure_code VARCHAR(64),
    failure_reason VARCHAR(512),
    processing_started_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uk_payments_payment_id UNIQUE (payment_id),
    CONSTRAINT uk_payments_order_id UNIQUE (order_id),
    CONSTRAINT uk_payments_source_event_id UNIQUE (source_event_id),
    CONSTRAINT uk_payments_gateway_idempotency_key UNIQUE (gateway_idempotency_key),
    CONSTRAINT uk_payments_gateway_transaction_id UNIQUE (gateway_transaction_id),
    CONSTRAINT ck_payments_terminal_details CHECK (
        (status = 'PROCESSING' AND processed_at IS NULL)
        OR (status = 'COMPLETED' AND gateway_transaction_id IS NOT NULL AND processed_at IS NOT NULL)
        OR (status = 'FAILED' AND failure_code IS NOT NULL AND failure_reason IS NOT NULL AND processed_at IS NOT NULL)
    )
);

CREATE INDEX idx_payments_status_created_at ON payments (status, created_at);

CREATE TABLE processed_events (
    event_id VARCHAR(128) PRIMARY KEY,
    payment_id UUID NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    order_id VARCHAR(128) NOT NULL,
    outcome VARCHAR(32) NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_processed_events_payment
        FOREIGN KEY (payment_id) REFERENCES payments (id),
    CONSTRAINT uk_processed_events_payment_event UNIQUE (payment_id, event_id)
);

CREATE INDEX idx_processed_events_order_id ON processed_events (order_id);
CREATE INDEX idx_processed_events_processed_at ON processed_events (processed_at);
