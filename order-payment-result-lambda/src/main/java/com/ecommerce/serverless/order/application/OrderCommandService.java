package com.ecommerce.serverless.order.application;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;

import java.math.BigDecimal;
import java.time.Clock;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;

public final class OrderCommandService {
    private final OrderCommandRepository repository;
    private final ProductInventoryPort inventory;
    private final Clock clock;

    public OrderCommandService(OrderCommandRepository repository, ProductInventoryPort inventory, Clock clock) {
        this.repository = repository;
        this.inventory = inventory;
        this.clock = clock;
    }

    public CreatedOrder create(CreateOrderCommand command) {
        validate(command);
        var existing = repository.findByIdempotencyKey(command.idempotencyKey());
        if (existing.isPresent()) {
            return new CreatedOrder(existing.get(), true);
        }

        List<OrderCreatedEvent.OrderItem> items = new ArrayList<>();
        BigDecimal total = BigDecimal.ZERO;
        for (CreateOrderCommand.Item requested : command.items()) {
            ProductInventoryPort.ReservedProduct product = inventory.reserve(requested.productId(), requested.quantity());
            BigDecimal subtotal = product.unitPrice().multiply(BigDecimal.valueOf(requested.quantity()));
            total = total.add(subtotal);
            items.add(new OrderCreatedEvent.OrderItem(
                    product.productId(), product.productName(), requested.quantity(), product.unitPrice(), subtotal));
        }

        String orderId = "order-" + UUID.randomUUID();
        OrderCreatedEvent event = new OrderCreatedEvent(
                "order-created-" + UUID.randomUUID(), "v1", "OrderCreated", clock.instant(),
                command.correlationId(), orderId, command.customerId(), command.customerEmail(),
                total, command.currency(), items);
        return repository.saveOrderAndOutbox(command.idempotencyKey(), event, clock.instant());
    }

    private static void validate(CreateOrderCommand command) {
        require(command.customerId(), "customerId", 128);
        require(command.customerEmail(), "customerEmail", 320);
        require(command.idempotencyKey(), "idempotencyKey", 128);
        require(command.correlationId(), "correlationId", 128);
        require(command.currency(), "currency", 3);
        if (!command.currency().matches("[A-Z]{3}")) throw new IllegalArgumentException("currency must be uppercase ISO-like code");
        if (command.items().isEmpty()) throw new IllegalArgumentException("items must not be empty");
        HashSet<String> products = new HashSet<>();
        for (CreateOrderCommand.Item item : command.items()) {
            require(item.productId(), "productId", 128);
            if (item.quantity() < 1) throw new IllegalArgumentException("quantity must be positive");
            if (!products.add(item.productId())) throw new IllegalArgumentException("duplicate productId is not allowed");
        }
    }

    private static void require(String value, String field, int max) {
        if (value == null || value.isBlank() || value.length() > max) {
            throw new IllegalArgumentException(field + " is required and must not exceed " + max + " characters");
        }
    }
}
