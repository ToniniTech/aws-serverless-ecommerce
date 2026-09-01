CREATE TABLE saga_inventory_products (
    product_id VARCHAR(128) PRIMARY KEY,
    product_name VARCHAR(255) NOT NULL,
    available_stock INTEGER NOT NULL CHECK (available_stock >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO saga_inventory_products (product_id, product_name, available_stock) VALUES
    ('prod-001', 'Mechanical Keyboard', 10),
    ('prod-002', 'Wireless Mouse', 25)
ON CONFLICT (product_id) DO NOTHING;

CREATE TABLE saga_stock_reservations (
    reservation_id UUID PRIMARY KEY,
    saga_id VARCHAR(128) NOT NULL UNIQUE,
    order_id VARCHAR(128) NOT NULL UNIQUE,
    product_id VARCHAR(128) NOT NULL REFERENCES saga_inventory_products(product_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    status VARCHAR(16) NOT NULL CHECK (status IN ('RESERVED', 'COMPENSATED')),
    compensation_reason VARCHAR(128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE saga_payments (
    payment_id UUID PRIMARY KEY,
    saga_id VARCHAR(128) NOT NULL UNIQUE REFERENCES saga_stock_reservations(saga_id),
    order_id VARCHAR(128) NOT NULL UNIQUE,
    amount NUMERIC(19, 2) NOT NULL CHECK (amount > 0),
    currency VARCHAR(3) NOT NULL,
    status VARCHAR(16) NOT NULL CHECK (status IN ('COMPLETED', 'FAILED')),
    failure_code VARCHAR(64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_saga_payment_failure CHECK (
        (status = 'COMPLETED' AND failure_code IS NULL) OR
        (status = 'FAILED' AND failure_code IS NOT NULL)
    )
);

CREATE TABLE saga_orders (
    saga_id VARCHAR(128) PRIMARY KEY REFERENCES saga_stock_reservations(saga_id),
    order_id VARCHAR(128) NOT NULL UNIQUE,
    status VARCHAR(16) NOT NULL CHECK (status = 'CONFIRMED'),
    confirmed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_saga_reservations_status_created
    ON saga_stock_reservations (status, created_at);
