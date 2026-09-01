package com.ecommerce.serverless.order.infrastructure.persistence;

public final class OrderNotFoundException extends RuntimeException {
    public OrderNotFoundException(String orderId) {
        super("Order does not exist yet: " + orderId);
    }
}
