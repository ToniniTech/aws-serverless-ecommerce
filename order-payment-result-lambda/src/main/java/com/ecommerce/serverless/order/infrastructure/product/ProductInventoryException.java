package com.ecommerce.serverless.order.infrastructure.product;

public final class ProductInventoryException extends RuntimeException {
    public ProductInventoryException(String message) {
        super(message);
    }

    public ProductInventoryException(String message, Throwable cause) {
        super(message, cause);
    }
}
