package com.ecommerce.serverless.order.infrastructure.persistence;

public final class OrderPersistenceException extends RuntimeException {
    public OrderPersistenceException(String message, Throwable cause) {
        super(message, cause);
    }
}
