package com.ecommerce.serverless.saga;

import java.math.BigDecimal;
import java.util.Map;

record SagaTaskRequest(
        String sagaId, String orderId, String productId, int quantity,
        BigDecimal amount, String currency, String reason) {

    static SagaTaskRequest from(Map<String, Object> input) {
        if (input == null) throw new IllegalArgumentException("input is required");
        return new SagaTaskRequest(
                text(input, "sagaId"), text(input, "orderId"), optionalText(input, "productId"),
                number(input, "quantity", 0).intValue(), decimal(input, "amount"),
                optionalText(input, "currency"), optionalText(input, "reason"));
    }

    private static String text(Map<String, Object> input, String field) {
        String value = optionalText(input, field);
        if (value == null || value.isBlank()) throw new IllegalArgumentException(field + " is required");
        return value;
    }

    private static String optionalText(Map<String, Object> input, String field) {
        Object value = input.get(field);
        return value == null ? null : value.toString();
    }

    private static Number number(Map<String, Object> input, String field, Number fallback) {
        Object value = input.get(field);
        if (value == null) return fallback;
        if (value instanceof Number number) return number;
        return new BigDecimal(value.toString());
    }

    private static BigDecimal decimal(Map<String, Object> input, String field) {
        Object value = input.get(field);
        return value == null ? null : new BigDecimal(value.toString());
    }
}
