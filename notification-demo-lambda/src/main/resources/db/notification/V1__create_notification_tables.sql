CREATE TABLE notifications (
    id UUID PRIMARY KEY,
    event_id VARCHAR(128) NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    correlation_id VARCHAR(128) NOT NULL,
    order_id VARCHAR(128) NOT NULL,
    payment_id VARCHAR(128),
    recipient VARCHAR(320) NOT NULL,
    template_key VARCHAR(64) NOT NULL,
    status VARCHAR(32) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uk_notifications_event_id UNIQUE (event_id),
    CONSTRAINT ck_notifications_event_type
        CHECK (event_type IN ('OrderCreated', 'PaymentProcessed', 'PaymentFailed')),
    CONSTRAINT ck_notifications_status CHECK (status = 'CREATED')
);

CREATE TABLE notification_processed_events (
    event_id VARCHAR(128) PRIMARY KEY,
    event_type VARCHAR(64) NOT NULL,
    order_id VARCHAR(128) NOT NULL,
    notification_id UUID NOT NULL,
    consumer VARCHAR(64) NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT fk_notification_processed_event
        FOREIGN KEY (notification_id) REFERENCES notifications (id),
    CONSTRAINT uk_notification_processed_notification UNIQUE (notification_id),
    CONSTRAINT ck_notification_processed_consumer CHECK (consumer = 'notification')
);

CREATE INDEX idx_notifications_order_id ON notifications (order_id);
CREATE INDEX idx_notifications_status_created_at ON notifications (status, created_at);
CREATE INDEX idx_notification_processed_at ON notification_processed_events (processed_at);
