package com.ecommerce.serverless.order;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.ScheduledEvent;
import com.ecommerce.serverless.outbox.OutboxBatchResult;
import com.ecommerce.serverless.outbox.OutboxBatchException;
import com.ecommerce.serverless.outbox.OutboxMetricsLog;

import java.time.Instant;

public final class OrderOutboxPublisherHandler implements RequestHandler<ScheduledEvent, OutboxBatchResult> {
    @Override
    public OutboxBatchResult handleRequest(ScheduledEvent input, Context context) {
        try {
            OutboxBatchResult result = OrderRuntime.outboxProcessor().processBatch();
            log(context, input, "INFO", result);
            return result;
        } catch (OutboxBatchException exception) {
            log(context, input, "ERROR", exception.result());
            throw exception;
        }
    }

    private static void log(Context context, ScheduledEvent input, String level, OutboxBatchResult result) {
        context.getLogger().log(OutboxMetricsLog.format(
                System.getenv().getOrDefault("METRIC_NAMESPACE", "serverless-ecommerce/local"),
                "order-outbox", result, Instant.now(), context.getAwsRequestId(),
                input == null ? null : input.getId(), level));
    }
}
