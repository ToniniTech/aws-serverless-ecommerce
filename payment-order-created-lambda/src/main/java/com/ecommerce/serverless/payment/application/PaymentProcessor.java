package com.ecommerce.serverless.payment.application;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;

public interface PaymentProcessor {
    PaymentProcessingResult process(OrderCreatedEvent event);
}
