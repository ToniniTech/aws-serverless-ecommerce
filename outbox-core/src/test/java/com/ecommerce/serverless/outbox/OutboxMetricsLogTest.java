package com.ecommerce.serverless.outbox;

import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertTrue;

class OutboxMetricsLogTest {
    @Test
    void emitsEmbeddedMetricsWithoutHighCardinalityDimensions() {
        String log = OutboxMetricsLog.format(
                "serverless-ecommerce/dev", "payment-outbox",
                new OutboxBatchResult(3, 2, 1, 75), Instant.ofEpochMilli(1234),
                "request-1", "schedule-1", "ERROR");

        assertTrue(log.contains("\"Namespace\":\"serverless-ecommerce/dev\""));
        assertTrue(log.contains("\"Dimensions\":[[\"Publisher\"]]"));
        assertTrue(log.contains("\"OutboxFailed\":1"));
        assertTrue(log.contains("\"OutboxOldestOutstandingAgeSeconds\":75"));
        assertTrue(log.contains("\"awsRequestId\":\"request-1\""));
    }
}
