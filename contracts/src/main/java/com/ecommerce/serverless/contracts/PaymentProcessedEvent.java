package com.ecommerce.serverless.contracts;

import java.math.BigDecimal;
import java.time.Instant;

public record PaymentProcessedEvent(
        String eventId,
        String eventVersion,
        String eventType,
        Instant occurredAt,
        String correlationId,
        String paymentId,
        String orderId,
        String customerId,
        String customerEmail,
        BigDecimal amount,
        String currency,
        String gatewayTransactionId,
        Instant processedAt
) implements PaymentResultEvent {
}
