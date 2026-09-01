package com.ecommerce.serverless.contracts;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class OrderCreatedEventParserTest {
    private final OrderCreatedEventParser parser = new OrderCreatedEventParser();

    @Test
    void parsesAValidOrderCreatedEvent() {
        OrderCreatedEvent event = parser.parse(validEventJson());

        assertEquals("evt-001", event.eventId());
        assertEquals("order-001", event.orderId());
        assertEquals(1, event.items().size());
    }

    @Test
    void rejectsAnUnexpectedEventType() {
        String body = validEventJson().replace("OrderCreated", "PaymentProcessed");

        assertThrows(EventContractException.class, () -> parser.parse(body));
    }

    static String validEventJson() {
        return """
                {
                  "eventId": "evt-001",
                  "eventVersion": "v1",
                  "eventType": "OrderCreated",
                  "occurredAt": "2026-08-21T12:00:00Z",
                  "correlationId": "corr-001",
                  "orderId": "order-001",
                  "customerId": "customer-001",
                  "customerEmail": "customer@example.com",
                  "totalAmount": 129.99,
                  "currency": "CLP",
                  "items": [
                    {
                      "productId": "prod-001",
                      "productName": "Mechanical Keyboard",
                      "quantity": 1,
                      "unitPrice": 129.99,
                      "subtotal": 129.99
                    }
                  ]
                }
                """;
    }
}

