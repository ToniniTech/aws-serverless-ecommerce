package com.ecommerce.serverless.order;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.SQSBatchResponse;
import com.amazonaws.services.lambda.runtime.events.SQSEvent;
import com.ecommerce.serverless.contracts.PaymentResultEvent;
import com.ecommerce.serverless.contracts.PaymentResultEventParser;
import com.ecommerce.serverless.order.application.OrderPaymentResultRepository;
import com.ecommerce.serverless.order.application.OrderPaymentResultService;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class OrderPaymentResultHandler implements RequestHandler<SQSEvent, SQSBatchResponse> {
    private static final ObjectMapper LOG_MAPPER = new ObjectMapper();
    private final PaymentResultEventParser parser;
    private final OrderPaymentResultService service;

    public OrderPaymentResultHandler() {
        this(new PaymentResultEventParser(), OrderRuntime.service());
    }

    OrderPaymentResultHandler(PaymentResultEventParser parser, OrderPaymentResultService service) {
        this.parser = parser;
        this.service = service;
    }

    @Override
    public SQSBatchResponse handleRequest(SQSEvent input, Context context) {
        List<SQSBatchResponse.BatchItemFailure> failures = new ArrayList<>();
        if (input == null || input.getRecords() == null) {
            writeLog(context, Map.of("level", "INFO", "consumer", "order-payment-result", "message", "empty_batch"));
            return new SQSBatchResponse(failures);
        }
        for (SQSEvent.SQSMessage message : input.getRecords()) {
            PaymentResultEvent event = null;
            try {
                event = parser.parseEventBridgeEnvelope(message.getBody());
                OrderPaymentResultRepository.ApplyResult result = service.apply(event);
                Map<String, Object> fields = commonFields(message, event);
                fields.put("level", "INFO");
                fields.put("orderStatus", result.status().name());
                fields.put("duplicate", result.duplicate());
                fields.put("orderVersion", result.version());
                fields.put("message", result.duplicate() ? "duplicate_ignored" : "order_status_updated");
                writeLog(context, fields);
            } catch (RuntimeException exception) {
                Map<String, Object> fields = new LinkedHashMap<>();
                fields.put("level", "ERROR");
                fields.put("consumer", "order-payment-result");
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

    private static Map<String, Object> commonFields(SQSEvent.SQSMessage message, PaymentResultEvent event) {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("consumer", "order-payment-result");
        fields.put("eventType", event.eventType());
        fields.put("eventId", event.eventId());
        fields.put("correlationId", event.correlationId());
        fields.put("orderId", event.orderId());
        fields.put("paymentId", event.paymentId());
        fields.put("sqsMessageId", message.getMessageId());
        fields.put("receiveCount", receiveCount(message));
        return fields;
    }

    private static String receiveCount(SQSEvent.SQSMessage message) {
        return message.getAttributes() == null ? "unknown"
                : message.getAttributes().getOrDefault("ApproximateReceiveCount", "unknown");
    }

    private static void writeLog(Context context, Map<String, Object> fields) {
        try {
            Map<String, Object> correlated = new LinkedHashMap<>(fields);
            correlated.put("awsRequestId", context.getAwsRequestId());
            context.getLogger().log(LOG_MAPPER.writeValueAsString(correlated) + System.lineSeparator());
        } catch (JsonProcessingException exception) {
            context.getLogger().log("{\"level\":\"ERROR\",\"consumer\":\"order-payment-result\",\"message\":\"log_serialization_failed\"}\n");
        }
    }
}
