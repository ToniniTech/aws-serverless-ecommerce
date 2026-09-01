package com.ecommerce.serverless.outbox;

import java.util.UUID;

public record OutboxMessage(
        UUID id,
        String eventId,
        String eventType,
        String aggregateId,
        String payload,
        int attemptCount) {
}
