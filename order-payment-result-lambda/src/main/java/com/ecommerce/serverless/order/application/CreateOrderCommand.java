package com.ecommerce.serverless.order.application;

import java.util.List;

public record CreateOrderCommand(
        String customerId,
        String customerEmail,
        String idempotencyKey,
        String correlationId,
        String currency,
        List<Item> items) {
    public CreateOrderCommand {
        items = items == null ? List.of() : List.copyOf(items);
    }

    public record Item(String productId, int quantity) {
    }
}
