package com.ecommerce.serverless.contracts;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;

import java.math.BigDecimal;

/** Parses the full EventBridge envelope delivered as an SQS message body. */
public final class PaymentResultEventParser {
    public static final String EVENT_SOURCE = "com.ecommerce.payment";

    private final ObjectMapper objectMapper;

    public PaymentResultEventParser() {
        this(new ObjectMapper()
                .registerModule(new JavaTimeModule())
                .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false));
    }

    PaymentResultEventParser(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public PaymentResultEvent parseEventBridgeEnvelope(String body) {
        if (body == null || body.isBlank()) {
            throw new EventContractException("SQS message body must not be empty");
        }
        try {
            JsonNode envelope = objectMapper.readTree(body);
            requireEnvelopeText(envelope, "id");
            String source = requireEnvelopeText(envelope, "source");
            if (!EVENT_SOURCE.equals(source)) {
                throw new EventContractException("EventBridge source must be " + EVENT_SOURCE);
            }
            String detailType = requireEnvelopeText(envelope, "detail-type");
            JsonNode detail = envelope.get("detail");
            if (detail == null || !detail.isObject()) {
                throw new EventContractException("EventBridge detail must be an object");
            }
            PaymentResultEvent event = parseDetail(detailType, detail);
            if (!detailType.equals(event.eventType())) {
                throw new EventContractException("EventBridge detail-type must match detail.eventType");
            }
            validate(event);
            return event;
        } catch (JsonProcessingException exception) {
            throw new EventContractException("SQS message body is not a valid EventBridge payment result", exception);
        }
    }

    private PaymentResultEvent parseDetail(String detailType, JsonNode detail) throws JsonProcessingException {
        return switch (detailType) {
            case "PaymentProcessed" -> objectMapper.treeToValue(detail, PaymentProcessedEvent.class);
            case "PaymentFailed" -> objectMapper.treeToValue(detail, PaymentFailedEvent.class);
            default -> throw new EventContractException("Unsupported payment result detail-type: " + detailType);
        };
    }

    private static void validate(PaymentResultEvent event) {
        requireText(event.eventId(), "eventId", 128);
        requireText(event.eventVersion(), "eventVersion", 16);
        requireText(event.eventType(), "eventType", 64);
        requireText(event.correlationId(), "correlationId", 128);
        requireText(event.paymentId(), "paymentId", 64);
        requireText(event.orderId(), "orderId", 128);
        requireText(event.customerId(), "customerId", 128);
        requireText(event.customerEmail(), "customerEmail", 320);
        requireText(event.currency(), "currency", 3);
        if (event.occurredAt() == null) {
            throw new EventContractException("occurredAt is required");
        }
        BigDecimal amount = event.amount();
        if (amount == null || amount.signum() <= 0 || amount.scale() > 2) {
            throw new EventContractException("amount must be positive with at most two decimal places");
        }
        if (!event.currency().matches("[A-Z]{3}")) {
            throw new EventContractException("currency must be a three-letter uppercase code");
        }
        if (event instanceof PaymentProcessedEvent processed) {
            requireText(processed.gatewayTransactionId(), "gatewayTransactionId", 128);
            if (processed.processedAt() == null) {
                throw new EventContractException("processedAt is required");
            }
        } else if (event instanceof PaymentFailedEvent failed) {
            requireText(failed.failureCode(), "failureCode", 64);
            requireText(failed.failureReason(), "failureReason", 512);
            if (failed.failedAt() == null) {
                throw new EventContractException("failedAt is required");
            }
        }
    }

    private static String requireEnvelopeText(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || !value.isTextual() || value.textValue().isBlank()) {
            throw new EventContractException("EventBridge " + field + " is required");
        }
        return value.textValue();
    }

    private static void requireText(String value, String field, int maximumLength) {
        if (value == null || value.isBlank()) {
            throw new EventContractException(field + " is required");
        }
        if (value.length() > maximumLength) {
            throw new EventContractException(field + " must not exceed " + maximumLength + " characters");
        }
    }
}
