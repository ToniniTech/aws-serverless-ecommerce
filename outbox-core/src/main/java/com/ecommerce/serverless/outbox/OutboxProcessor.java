package com.ecommerce.serverless.outbox;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;

public final class OutboxProcessor {
    private static final int MAX_ERROR_LENGTH = 1000;

    private final OutboxRepository repository;
    private final OutboxTransport transport;
    private final Clock clock;
    private final int batchSize;
    private final Duration claimLease;

    public OutboxProcessor(
            OutboxRepository repository,
            OutboxTransport transport,
            Clock clock,
            int batchSize,
            Duration claimLease) {
        if (batchSize < 1 || batchSize > 100) {
            throw new IllegalArgumentException("batchSize must be between 1 and 100");
        }
        this.repository = repository;
        this.transport = transport;
        this.clock = clock;
        this.batchSize = batchSize;
        this.claimLease = claimLease;
    }

    public OutboxBatchResult processBatch() {
        Instant claimedAt = clock.instant();
        List<OutboxMessage> messages = repository.claimBatch(batchSize, claimedAt, claimLease);
        int published = 0;
        int failed = 0;
        for (OutboxMessage message : messages) {
            try {
                transport.publish(message);
                repository.markPublished(message.id(), clock.instant());
                published++;
            } catch (RuntimeException exception) {
                failed++;
                repository.releaseForRetry(
                        message.id(),
                        clock.instant().plus(backoff(message.attemptCount())),
                        boundedError(exception));
            }
        }
        long oldestOutstandingAgeSeconds = repository.oldestOutstandingCreatedAt()
                .map(createdAt -> Math.max(0, Duration.between(createdAt, clock.instant()).toSeconds()))
                .orElse(0L);
        OutboxBatchResult result = new OutboxBatchResult(
                messages.size(), published, failed, oldestOutstandingAgeSeconds);
        if (failed > 0) {
            throw new OutboxBatchException(result);
        }
        return result;
    }

    static Duration backoff(int attemptCount) {
        int exponent = Math.min(Math.max(attemptCount - 1, 0), 8);
        return Duration.ofSeconds(Math.min(1L << exponent, 300));
    }

    private static String boundedError(RuntimeException exception) {
        String message = exception.getClass().getSimpleName() + ": " + exception.getMessage();
        return message.length() <= MAX_ERROR_LENGTH ? message : message.substring(0, MAX_ERROR_LENGTH);
    }
}
