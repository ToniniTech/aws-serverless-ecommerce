package com.ecommerce.serverless.order.application;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;

public record OrderView(
        String orderId,
        String status,
        BigDecimal totalAmount,
        String currency,
        long version,
        String paymentId,
        String paymentFailureCode,
        String paymentFailureReason,
        Instant createdAt,
        Instant updatedAt,
        List<Item> items) {

    public OrderView {
        items = List.copyOf(items);
    }

    public record Item(
            String productId,
            String productName,
            int quantity,
            BigDecimal unitPrice,
            BigDecimal subtotal) {
    }
}
