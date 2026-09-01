package com.ecommerce.serverless.payment.application;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;
import com.ecommerce.serverless.payment.domain.PaymentRecord;
import com.ecommerce.serverless.contracts.PaymentResultEvent;

import java.time.Duration;
import java.time.Instant;

public interface PaymentProcessingRepository {
    Claim claim(
            OrderCreatedEvent event,
            String gatewayIdempotencyKey,
            Instant now,
            Duration processingLease);

    PaymentRecord finalizePayment(
            PaymentRecord payment,
            PaymentGateway.GatewayResult gatewayResult,
            PaymentResultEvent resultEvent,
            Instant processedAt);

    enum ClaimDisposition {
        CLAIMED,
        DUPLICATE,
        IN_PROGRESS
    }

    record Claim(ClaimDisposition disposition, PaymentRecord payment) {
    }
}
