CREATE TABLE orders (
    id UUID PRIMARY KEY,
    order_id VARCHAR(128) NOT NULL UNIQUE,
    status VARCHAR(16) NOT NULL CHECK (status IN ('PENDING', 'PAID', 'FAILED')),
    payment_id VARCHAR(64) UNIQUE,
    payment_failure_code VARCHAR(64),
    payment_failure_reason VARCHAR(512),
    version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_order_payment_result CHECK (
        (status = 'PENDING' AND payment_id IS NULL)
        OR (status = 'PAID' AND payment_id IS NOT NULL AND payment_failure_code IS NULL)
        OR (status = 'FAILED' AND payment_id IS NOT NULL AND payment_failure_code IS NOT NULL)
    )
);

CREATE INDEX idx_orders_status_updated_at ON orders (status, updated_at);

CREATE TABLE order_processed_events (
    event_id VARCHAR(128) PRIMARY KEY,
    event_type VARCHAR(64) NOT NULL CHECK (event_type IN ('PaymentProcessed', 'PaymentFailed')),
    order_id VARCHAR(128) NOT NULL,
    payment_id VARCHAR(64) NOT NULL,
    resulting_status VARCHAR(16) NOT NULL CHECK (resulting_status IN ('PAID', 'FAILED')),
    outcome VARCHAR(32) NOT NULL CHECK (outcome IN ('APPLIED', 'ALREADY_APPLIED')),
    processed_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT fk_order_processed_event_order FOREIGN KEY (order_id) REFERENCES orders (order_id),
    CONSTRAINT uk_order_processed_event_payment_event UNIQUE (payment_id, event_id)
);

CREATE INDEX idx_order_processed_events_order_id ON order_processed_events (order_id);
CREATE INDEX idx_order_processed_events_processed_at ON order_processed_events (processed_at);
