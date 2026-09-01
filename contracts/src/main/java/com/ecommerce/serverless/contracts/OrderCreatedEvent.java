package com.ecommerce.serverless.contracts;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;

/**
 * Messaging contract published to the order-events SNS topic.
 * This is deliberately separate from persistence entities and AWS envelope types.
 */
public record OrderCreatedEvent(
        String eventId,
        String eventVersion,
        String eventType,
        Instant occurredAt,
        String correlationId,
        String orderId,
        String customerId,
        String customerEmail,
        BigDecimal totalAmount,
        String currency,
        List<OrderItem> items
) {
    public OrderCreatedEvent {
        items = items == null ? List.of() : List.copyOf(items);
    }

    public record OrderItem(
            String productId,
            String productName,
            int quantity,
            BigDecimal unitPrice,
            BigDecimal subtotal
    ) {
    }
}

