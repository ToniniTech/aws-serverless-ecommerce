package com.ecommerce.serverless.notification.application;

import com.ecommerce.serverless.notification.NotificationEvent;

import java.time.Clock;

public final class NotificationApplicationService implements NotificationProcessor {
    private final NotificationRepository repository;
    private final Clock clock;

    public NotificationApplicationService(NotificationRepository repository, Clock clock) {
        this.repository = repository;
        this.clock = clock;
    }

    @Override
    public ProcessResult process(NotificationEvent event) {
        String templateKey = switch (event.eventType()) {
            case "OrderCreated" -> "ORDER_CREATED";
            case "PaymentProcessed" -> "PAYMENT_PROCESSED";
            case "PaymentFailed" -> "PAYMENT_FAILED";
            default -> throw new IllegalArgumentException("Unsupported notification event type: " + event.eventType());
        };
        return repository.record(event, templateKey, clock.instant());
    }
}
