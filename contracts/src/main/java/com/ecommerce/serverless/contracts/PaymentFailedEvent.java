package com.ecommerce.serverless.contracts;

import java.math.BigDecimal;
import java.time.Instant;

public record PaymentFailedEvent(
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
        String failureCode,
        String failureReason,
        Instant failedAt
) implements PaymentResultEvent {
}
