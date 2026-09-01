package com.ecommerce.serverless.contracts;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;

public final class OrderCreatedEventParser {
    private final ObjectMapper objectMapper;

    public OrderCreatedEventParser() {
        this(new ObjectMapper()
                .registerModule(new JavaTimeModule())
                .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false));
    }

    OrderCreatedEventParser(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public OrderCreatedEvent parse(String body) {
        if (body == null || body.isBlank()) {
            throw new EventContractException("SQS message body must not be empty");
        }

        try {
            OrderCreatedEvent event = objectMapper.readValue(body, OrderCreatedEvent.class);
            validate(event);
            return event;
        } catch (JsonProcessingException exception) {
            throw new EventContractException("SQS message body is not a valid OrderCreated event", exception);
        }
    }

    private static void validate(OrderCreatedEvent event) {
        requireText(event.eventId(), "eventId", 128);
        requireText(event.eventVersion(), "eventVersion", 16);
        requireText(event.eventType(), "eventType", 64);
        requireText(event.correlationId(), "correlationId", 128);
        requireText(event.orderId(), "orderId", 128);
        requireText(event.customerId(), "customerId", 128);
        requireText(event.customerEmail(), "customerEmail", 320);
        requireText(event.currency(), "currency", 3);

        if (!"OrderCreated".equals(event.eventType())) {
            throw new EventContractException("eventType must be OrderCreated");
        }
        if (event.occurredAt() == null) {
            throw new EventContractException("occurredAt is required");
        }
        if (event.totalAmount() == null || event.totalAmount().signum() <= 0) {
            throw new EventContractException("totalAmount must be greater than zero");
        }
        if (event.totalAmount().scale() > 2) {
            throw new EventContractException("totalAmount must have at most two decimal places");
        }
        if (!event.currency().matches("[A-Z]{3}")) {
            throw new EventContractException("currency must be a three-letter uppercase code");
        }
        if (event.items().isEmpty()) {
            throw new EventContractException("items must not be empty");
        }
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
