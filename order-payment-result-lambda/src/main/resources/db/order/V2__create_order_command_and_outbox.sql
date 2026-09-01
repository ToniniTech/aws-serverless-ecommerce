ALTER TABLE orders ADD COLUMN customer_id VARCHAR(128);
ALTER TABLE orders ADD COLUMN customer_email VARCHAR(320);
ALTER TABLE orders ADD COLUMN idempotency_key VARCHAR(128);
ALTER TABLE orders ADD COLUMN total_amount NUMERIC(19, 2);
ALTER TABLE orders ADD COLUMN currency VARCHAR(3);

UPDATE orders SET
    customer_id = 'legacy-phase-4',
    customer_email = 'legacy@example.invalid',
    idempotency_key = 'legacy-' || order_id,
    total_amount = 0,
    currency = 'USD'
WHERE customer_id IS NULL;

ALTER TABLE orders ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE orders ALTER COLUMN customer_email SET NOT NULL;
ALTER TABLE orders ALTER COLUMN idempotency_key SET NOT NULL;
ALTER TABLE orders ALTER COLUMN total_amount SET NOT NULL;
ALTER TABLE orders ALTER COLUMN currency SET NOT NULL;
ALTER TABLE orders ADD CONSTRAINT uk_orders_idempotency_key UNIQUE (idempotency_key);
ALTER TABLE orders ADD CONSTRAINT ck_orders_total_amount CHECK (total_amount >= 0);
ALTER TABLE orders ADD CONSTRAINT ck_orders_currency CHECK (currency = UPPER(currency));

CREATE TABLE order_items (
    id UUID PRIMARY KEY,
    order_id VARCHAR(128) NOT NULL,
    product_id VARCHAR(128) NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(19, 2) NOT NULL CHECK (unit_price >= 0),
    subtotal NUMERIC(19, 2) NOT NULL CHECK (subtotal >= 0),
    CONSTRAINT fk_order_items_order FOREIGN KEY (order_id) REFERENCES orders (order_id),
    CONSTRAINT uk_order_items_order_product UNIQUE (order_id, product_id)
);

CREATE INDEX idx_order_items_order_id ON order_items (order_id);

CREATE TABLE order_outbox (
    id UUID PRIMARY KEY,
    event_id VARCHAR(128) NOT NULL UNIQUE,
    event_type VARCHAR(64) NOT NULL CHECK (event_type = 'OrderCreated'),
    aggregate_id VARCHAR(128) NOT NULL,
    payload JSONB NOT NULL,
    status VARCHAR(16) NOT NULL CHECK (status IN ('PENDING', 'PROCESSING', 'PUBLISHED')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL,
    claimed_at TIMESTAMPTZ,
    published_at TIMESTAMPTZ,
    last_error VARCHAR(1000),
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_order_outbox_order FOREIGN KEY (aggregate_id) REFERENCES orders (order_id),
    CONSTRAINT ck_order_outbox_state CHECK (
        (status = 'PENDING' AND published_at IS NULL)
        OR (status = 'PROCESSING' AND claimed_at IS NOT NULL AND published_at IS NULL)
        OR (status = 'PUBLISHED' AND published_at IS NOT NULL)
    )
);

CREATE INDEX idx_order_outbox_status_next_created
    ON order_outbox (status, next_attempt_at, created_at);
