package com.ecommerce.serverless.saga;

import java.math.BigDecimal;
import java.util.Map;

final class SagaApplicationService {
    private static final BigDecimal LIMIT = new BigDecimal("1000.00");
    private static final BigDecimal EXPIRED_FRACTION = new BigDecimal("0.13");
    private final SagaRepository repository;

    SagaApplicationService(SagaRepository repository) { this.repository = repository; }

    Map<String, Object> reserve(SagaTaskRequest request) {
        if (request.productId() == null || request.quantity() <= 0 || request.amount() == null) {
            throw new IllegalArgumentException("productId, positive quantity, and amount are required");
        }
        return repository.reserve(request);
    }

    Map<String, Object> processPayment(SagaTaskRequest request) {
        if (request.amount() == null || request.amount().signum() <= 0 || request.currency() == null) {
            throw new IllegalArgumentException("positive amount and currency are required");
        }
        String failureCode = null;
        if (request.amount().compareTo(LIMIT) > 0) failureCode = "AMOUNT_EXCEEDS_LIMIT";
        else if (request.amount().remainder(BigDecimal.ONE).compareTo(EXPIRED_FRACTION) == 0) {
            failureCode = "CARD_EXPIRED";
        }
        return repository.recordPayment(request, failureCode);
    }

    Map<String, Object> confirm(SagaTaskRequest request) { return repository.confirm(request); }
    Map<String, Object> compensate(SagaTaskRequest request) { return repository.compensate(request); }
}
