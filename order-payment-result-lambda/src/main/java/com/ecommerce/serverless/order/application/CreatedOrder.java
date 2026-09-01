package com.ecommerce.serverless.order.application;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;

public record CreatedOrder(OrderCreatedEvent event, boolean duplicate) {
}
