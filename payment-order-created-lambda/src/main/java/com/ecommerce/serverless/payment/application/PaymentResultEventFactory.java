package com.ecommerce.serverless.payment.application;

import com.ecommerce.serverless.contracts.PaymentFailedEvent;
import com.ecommerce.serverless.contracts.PaymentProcessedEvent;
import com.ecommerce.serverless.contracts.PaymentResultEvent;
import com.ecommerce.serverless.payment.domain.PaymentRecord;

import java.time.Instant;

public final class PaymentResultEventFactory {
    private PaymentResultEventFactory() {
    }

    public static PaymentResultEvent create(
            PaymentRecord payment,
            PaymentGateway.GatewayResult gatewayResult,
            Instant processedAt) {
        String eventId = "payment-result-" + payment.paymentId();
        if (gatewayResult.approved()) {
            return new PaymentProcessedEvent(
                    eventId, "v1", "PaymentProcessed", processedAt, payment.correlationId(),
                    payment.paymentId(), payment.orderId(), payment.customerId(), payment.customerEmail(),
                    payment.amount(), payment.currency(), gatewayResult.transactionId(), processedAt);
        }
        return new PaymentFailedEvent(
                eventId, "v1", "PaymentFailed", processedAt, payment.correlationId(),
                payment.paymentId(), payment.orderId(), payment.customerId(), payment.customerEmail(),
                payment.amount(), payment.currency(), gatewayResult.failureCode(), gatewayResult.failureReason(), processedAt);
    }
}
