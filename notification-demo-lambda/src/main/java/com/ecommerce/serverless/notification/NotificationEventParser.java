package com.ecommerce.serverless.notification;

import com.ecommerce.serverless.contracts.EventContractException;
import com.ecommerce.serverless.contracts.OrderCreatedEvent;
import com.ecommerce.serverless.contracts.OrderCreatedEventParser;
import com.ecommerce.serverless.contracts.PaymentResultEvent;
import com.ecommerce.serverless.contracts.PaymentResultEventParser;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

final class NotificationEventParser {
    private final ObjectMapper objectMapper = new ObjectMapper();
    private final OrderCreatedEventParser orderCreatedParser;
    private final PaymentResultEventParser paymentResultParser;

    NotificationEventParser() {
        this(new OrderCreatedEventParser(), new PaymentResultEventParser());
    }

    NotificationEventParser(
            OrderCreatedEventParser orderCreatedParser,
            PaymentResultEventParser paymentResultParser) {
        this.orderCreatedParser = orderCreatedParser;
        this.paymentResultParser = paymentResultParser;
    }

    NotificationEvent parse(String body) {
        try {
            JsonNode root = objectMapper.readTree(body);
            if (root != null && root.has("detail") && root.has("detail-type")) {
                PaymentResultEvent event = paymentResultParser.parseEventBridgeEnvelope(body);
                return new NotificationEvent(
                        event.eventId(), event.eventType(), event.correlationId(), event.orderId(), event.paymentId(),
                        event.customerEmail());
            }
            OrderCreatedEvent event = orderCreatedParser.parse(body);
            return new NotificationEvent(
                    event.eventId(), event.eventType(), event.correlationId(), event.orderId(), null,
                    event.customerEmail());
        } catch (JsonProcessingException | NullPointerException exception) {
            throw new EventContractException("Notification message is not valid JSON", exception);
        }
    }
}
