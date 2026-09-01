package com.ecommerce.serverless.payment.application;

public final class PaymentInProgressException extends RuntimeException {
    public PaymentInProgressException(String orderId) {
        super("Payment is already being processed for order " + orderId);
    }
}
