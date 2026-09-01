package com.ecommerce.serverless.order.application;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;

import java.time.Instant;
import java.util.Optional;

public interface OrderCommandRepository {
    Optional<OrderCreatedEvent> findByIdempotencyKey(String idempotencyKey);

    CreatedOrder saveOrderAndOutbox(String idempotencyKey, OrderCreatedEvent event, Instant createdAt);
}
