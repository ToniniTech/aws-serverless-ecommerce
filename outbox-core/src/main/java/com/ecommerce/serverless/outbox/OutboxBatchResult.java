package com.ecommerce.serverless.outbox;

public record OutboxBatchResult(int claimed, int published, int failed, long oldestOutstandingAgeSeconds) {
}
