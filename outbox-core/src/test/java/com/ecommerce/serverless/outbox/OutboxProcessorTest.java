package com.ecommerce.serverless.outbox;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class OutboxProcessorTest {
    private static final Instant NOW = Instant.parse("2026-08-21T12:00:00Z");
    private final OutboxRepository repository = mock(OutboxRepository.class);
    private final OutboxTransport transport = mock(OutboxTransport.class);
    private final OutboxProcessor processor = new OutboxProcessor(
            repository, transport, Clock.fixed(NOW, ZoneOffset.UTC), 10, Duration.ofMinutes(2));

    @Test
    void marksSuccessfulMessagesPublished() {
        OutboxMessage message = message(1);
        when(repository.claimBatch(10, NOW, Duration.ofMinutes(2))).thenReturn(List.of(message));
        when(repository.oldestOutstandingCreatedAt()).thenReturn(Optional.of(NOW.minusSeconds(42)));

        OutboxBatchResult result = processor.processBatch();

        assertEquals(new OutboxBatchResult(1, 1, 0, 42), result);
        verify(repository).markPublished(message.id(), NOW);
    }

    @Test
    void releasesFailuresWithBackoffAndFailsInvocation() {
        OutboxMessage message = message(3);
        when(repository.claimBatch(10, NOW, Duration.ofMinutes(2))).thenReturn(List.of(message));
        when(repository.oldestOutstandingCreatedAt()).thenReturn(Optional.empty());
        doThrow(new IllegalStateException("AWS unavailable")).when(transport).publish(message);

        OutboxBatchException exception = assertThrows(OutboxBatchException.class, processor::processBatch);

        assertEquals(new OutboxBatchResult(1, 0, 1, 0), exception.result());
        verify(repository).releaseForRetry(any(), any(), any());
    }

    private static OutboxMessage message(int attempt) {
        return new OutboxMessage(UUID.randomUUID(), "evt-1", "Example", "aggregate-1", "{}", attempt);
    }
}
