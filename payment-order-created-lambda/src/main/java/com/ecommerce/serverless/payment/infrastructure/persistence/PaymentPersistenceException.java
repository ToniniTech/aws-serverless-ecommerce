package com.ecommerce.serverless.payment.infrastructure.persistence;

public final class PaymentPersistenceException extends RuntimeException {
    public PaymentPersistenceException(String message, Throwable cause) {
        super(message, cause);
    }
}
