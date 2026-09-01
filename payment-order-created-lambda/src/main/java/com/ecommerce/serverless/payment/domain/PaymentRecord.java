package com.ecommerce.serverless.payment.domain;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

public record PaymentRecord(
        UUID id,
        String paymentId,
        String orderId,
        String sourceEventId,
        String correlationId,
        String gatewayIdempotencyKey,
        String customerId,
        String customerEmail,
        BigDecimal amount,
        String currency,
        PaymentStatus status,
        String gatewayTransactionId,
        String failureCode,
        String failureReason,
        Instant processingStartedAt,
        Instant processedAt
) {
}
