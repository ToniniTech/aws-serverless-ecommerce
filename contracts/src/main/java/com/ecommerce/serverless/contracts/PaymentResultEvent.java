package com.ecommerce.serverless.contracts;

import java.math.BigDecimal;
import java.time.Instant;

/** Messaging contract carried in the detail field of an EventBridge event. */
public sealed interface PaymentResultEvent permits PaymentProcessedEvent, PaymentFailedEvent {
    String eventId();
    String eventVersion();
    String eventType();
    Instant occurredAt();
    String correlationId();
    String paymentId();
    String orderId();
    String customerId();
    String customerEmail();
    BigDecimal amount();
    String currency();
}
