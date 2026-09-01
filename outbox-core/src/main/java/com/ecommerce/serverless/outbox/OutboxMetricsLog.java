package com.ecommerce.serverless.outbox;

import java.time.Instant;

/** Produces one CloudWatch Embedded Metric Format log event per publisher invocation. */
public final class OutboxMetricsLog {
    private OutboxMetricsLog() {
    }

    public static String format(
            String namespace,
            String publisher,
            OutboxBatchResult result,
            Instant timestamp,
            String requestId,
            String triggerId,
            String level) {
        return "{\"_aws\":{\"Timestamp\":" + timestamp.toEpochMilli()
                + ",\"CloudWatchMetrics\":[{\"Namespace\":\"" + escape(namespace)
                + "\",\"Dimensions\":[[\"Publisher\"]],\"Metrics\":["
                + "{\"Name\":\"OutboxClaimed\",\"Unit\":\"Count\"},"
                + "{\"Name\":\"OutboxPublished\",\"Unit\":\"Count\"},"
                + "{\"Name\":\"OutboxFailed\",\"Unit\":\"Count\"},"
                + "{\"Name\":\"OutboxOldestOutstandingAgeSeconds\",\"Unit\":\"Seconds\"}]}]},"
                + "\"Publisher\":\"" + escape(publisher) + "\","
                + "\"OutboxClaimed\":" + result.claimed() + ","
                + "\"OutboxPublished\":" + result.published() + ","
                + "\"OutboxFailed\":" + result.failed() + ","
                + "\"OutboxOldestOutstandingAgeSeconds\":" + result.oldestOutstandingAgeSeconds() + ","
                + "\"level\":\"" + escape(level) + "\","
                + "\"message\":\"outbox_batch_completed\","
                + "\"awsRequestId\":\"" + escape(requestId) + "\","
                + "\"triggerId\":\"" + escape(triggerId) + "\"}\n";
    }

    private static String escape(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\n", "\\n").replace("\r", "\\r");
    }
}
