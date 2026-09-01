package com.ecommerce.serverless.outbox;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface OutboxRepository {
    List<OutboxMessage> claimBatch(int batchSize, Instant now, Duration claimLease);

    void markPublished(UUID id, Instant publishedAt);

    void releaseForRetry(UUID id, Instant nextAttemptAt, String error);

    Optional<Instant> oldestOutstandingCreatedAt();
}
