package com.ecommerce.serverless.order.application;

import com.ecommerce.serverless.contracts.PaymentResultEvent;

import java.time.Clock;

public final class OrderPaymentResultService {
    private final OrderPaymentResultRepository repository;
    private final Clock clock;

    public OrderPaymentResultService(OrderPaymentResultRepository repository, Clock clock) {
        this.repository = repository;
        this.clock = clock;
    }

    public OrderPaymentResultRepository.ApplyResult apply(PaymentResultEvent event) {
        return repository.apply(event, clock.instant());
    }
}
