package com.ecommerce.serverless.order.infrastructure.persistence;

public final class OrderStateConflictException extends RuntimeException {
    public OrderStateConflictException(String message) {
        super(message);
    }
}
