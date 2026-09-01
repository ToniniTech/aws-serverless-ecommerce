package com.ecommerce.serverless.order.application;

import com.ecommerce.serverless.contracts.PaymentResultEvent;
import com.ecommerce.serverless.order.domain.OrderStatus;

import java.time.Instant;

public interface OrderPaymentResultRepository {
    ApplyResult apply(PaymentResultEvent event, Instant processedAt);

    record ApplyResult(String orderId, OrderStatus status, boolean duplicate, long version) {
    }
}
