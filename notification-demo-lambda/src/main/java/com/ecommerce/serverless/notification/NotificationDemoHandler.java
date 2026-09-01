package com.ecommerce.serverless.notification;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.SQSEvent;
import com.amazonaws.services.lambda.runtime.events.SQSBatchResponse;
import com.ecommerce.serverless.notification.application.NotificationProcessor;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Idempotent transport consumer. It creates a durable notification record but performs no external delivery.
 */
public final class NotificationDemoHandler implements RequestHandler<SQSEvent, SQSBatchResponse> {
    private static final String FORCE_FAILURE_ATTRIBUTE = "forceFailure";
    private static final ObjectMapper LOG_MAPPER = new ObjectMapper();

    private final NotificationEventParser parser;
    private final NotificationProcessor processor;

    public NotificationDemoHandler() {
        this(new NotificationEventParser(), NotificationRuntime.processor());
    }

    NotificationDemoHandler(NotificationEventParser parser, NotificationProcessor processor) {
        this.parser = parser;
        this.processor = processor;
    }

    @Override
    public SQSBatchResponse handleRequest(SQSEvent input, Context context) {
        List<SQSBatchResponse.BatchItemFailure> failures = new ArrayList<>();

        if (input == null || input.getRecords() == null) {
            writeLog(context, Map.of(
                    "level", "INFO",
                    "consumer", "notification-demo",
                    "message", "empty_batch"));
            return new SQSBatchResponse(failures);
        }

        for (SQSEvent.SQSMessage message : input.getRecords()) {
            NotificationEvent event = null;
            try {
                event = parser.parse(message.getBody());
                if (isIntentionalFailure(message)) {
                    throw new IntentionalDemoFailureException("Intentional failure requested for DLQ testing");
                }
                NotificationProcessor.ProcessResult result = processor.process(event);

                Map<String, Object> fields = new LinkedHashMap<>();
                fields.put("level", "INFO");
                fields.put("consumer", "notification-demo");
                fields.put("eventType", event.eventType());
                fields.put("eventId", event.eventId());
                fields.put("correlationId", event.correlationId());
                fields.put("orderId", event.orderId());
                if (event.paymentId() != null) {
                    fields.put("paymentId", event.paymentId());
                }
                fields.put("sqsMessageId", message.getMessageId());
                fields.put("receiveCount", receiveCount(message));
                fields.put("notificationId", result.notificationId());
                fields.put("notificationStatus", result.status());
                fields.put("duplicate", result.duplicate());
                fields.put("message", result.duplicate() ? "duplicate_event_ignored" : "notification_recorded");
                writeLog(context, fields);
            } catch (RuntimeException exception) {
                Map<String, Object> fields = new LinkedHashMap<>();
                fields.put("level", "ERROR");
                fields.put("consumer", "notification-demo");
                fields.put("sqsMessageId", message.getMessageId());
                fields.put("receiveCount", receiveCount(message));
                fields.put("errorType", exception.getClass().getSimpleName());
                fields.put("error", exception.getMessage());
                if (event != null) {
                    fields.put("eventId", event.eventId());
                    fields.put("correlationId", event.correlationId());
                    fields.put("orderId", event.orderId());
                }
                writeLog(context, fields);
                failures.add(new SQSBatchResponse.BatchItemFailure(message.getMessageId()));
            }
        }

        return new SQSBatchResponse(failures);
    }

    private static String receiveCount(SQSEvent.SQSMessage message) {
        return message.getAttributes() == null
                ? "unknown"
                : message.getAttributes().getOrDefault("ApproximateReceiveCount", "unknown");
    }

    private static boolean isIntentionalFailure(SQSEvent.SQSMessage message) {
        if (message.getMessageAttributes() == null) {
            return false;
        }

        SQSEvent.MessageAttribute attribute = message.getMessageAttributes().get(FORCE_FAILURE_ATTRIBUTE);
        return attribute != null && "true".equalsIgnoreCase(attribute.getStringValue());
    }

    private static void writeLog(Context context, Map<String, Object> fields) {
        try {
            Map<String, Object> correlated = new LinkedHashMap<>(fields);
            correlated.put("awsRequestId", context.getAwsRequestId());
            context.getLogger().log(LOG_MAPPER.writeValueAsString(correlated) + System.lineSeparator());
        } catch (JsonProcessingException exception) {
            context.getLogger().log("{\"level\":\"ERROR\",\"consumer\":\"notification-demo\",\"message\":\"log_serialization_failed\"}\n");
        }
    }

    private static final class IntentionalDemoFailureException extends RuntimeException {
        private IntentionalDemoFailureException(String message) {
            super(message);
        }
    }
}
