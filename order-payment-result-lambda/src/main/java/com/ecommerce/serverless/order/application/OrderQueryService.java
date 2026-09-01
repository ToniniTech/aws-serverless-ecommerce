package com.ecommerce.serverless.order.application;

import com.ecommerce.serverless.order.infrastructure.persistence.OrderNotFoundException;

public final class OrderQueryService {
    private final OrderQueryRepository repository;

    public OrderQueryService(OrderQueryRepository repository) {
        this.repository = repository;
    }

    public OrderView findByOrderId(String orderId) {
        if (orderId == null || orderId.isBlank()) {
            throw new IllegalArgumentException("orderId is required");
        }
        return repository.findByOrderId(orderId)
                .orElseThrow(() -> new OrderNotFoundException(orderId));
    }
}
