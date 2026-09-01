package com.ecommerce.serverless.order.application;

import java.util.Optional;

public interface OrderQueryRepository {
    Optional<OrderView> findByOrderId(String orderId);
}
