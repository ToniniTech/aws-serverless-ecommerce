package com.ecommerce.serverless.payment.infrastructure.messaging;

public final class PaymentResultPublishException extends RuntimeException {
    public PaymentResultPublishException(String message) {
        super(message);
    }

    public PaymentResultPublishException(String message, Throwable cause) {
        super(message, cause);
    }
}
