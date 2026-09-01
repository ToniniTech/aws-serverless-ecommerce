package com.ecommerce.serverless.outbox;

public interface OutboxTransport {
    void publish(OutboxMessage message);
}
