package com.ecommerce.serverless.payment.application;

import com.ecommerce.serverless.payment.domain.PaymentStatus;

import java.math.BigDecimal;
import java.time.Instant;

public record PaymentProcessingResult(
        String paymentId,
        String orderId,
        String sourceEventId,
        String correlationId,
        String customerId,
        String customerEmail,
        BigDecimal amount,
        String currency,
        PaymentStatus status,
        boolean duplicate,
        String gatewayIdempotencyKey,
        String gatewayTransactionId,
        String failureCode,
        String failureReason,
        Instant processedAt
) {
    public static PaymentProcessingResult duplicate(com.ecommerce.serverless.payment.domain.PaymentRecord payment) {
        return new PaymentProcessingResult(
                payment.paymentId(),
                payment.orderId(),
                payment.sourceEventId(),
                payment.correlationId(),
                payment.customerId(),
                payment.customerEmail(),
                payment.amount(),
                payment.currency(),
                payment.status(),
                true,
                payment.gatewayIdempotencyKey(),
                payment.gatewayTransactionId(),
                payment.failureCode(),
                payment.failureReason(),
                payment.processedAt());
    }

    public static PaymentProcessingResult processed(com.ecommerce.serverless.payment.domain.PaymentRecord payment) {
        return new PaymentProcessingResult(
                payment.paymentId(),
                payment.orderId(),
                payment.sourceEventId(),
                payment.correlationId(),
                payment.customerId(),
                payment.customerEmail(),
                payment.amount(),
                payment.currency(),
                payment.status(),
                false,
                payment.gatewayIdempotencyKey(),
                payment.gatewayTransactionId(),
                payment.failureCode(),
                payment.failureReason(),
                payment.processedAt());
    }
}
