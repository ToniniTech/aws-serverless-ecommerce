package com.ecommerce.serverless.contracts;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

class PaymentResultEventParserTest {
    private final PaymentResultEventParser parser = new PaymentResultEventParser();

    @Test
    void parsesPaymentProcessedFromEventBridgeEnvelope() {
        PaymentResultEvent event = parser.parseEventBridgeEnvelope(processedEnvelope());

        assertInstanceOf(PaymentProcessedEvent.class, event);
        assertEquals("payment-result-pay-1", event.eventId());
        assertEquals("order-1", event.orderId());
    }

    @Test
    void rejectsMismatchedDetailType() {
        String body = processedEnvelope().replace("\"eventType\":\"PaymentProcessed\"",
                "\"eventType\":\"PaymentFailed\"");

        assertThrows(EventContractException.class, () -> parser.parseEventBridgeEnvelope(body));
    }

    static String processedEnvelope() {
        return """
                {"version":"0","id":"aws-event-id","detail-type":"PaymentProcessed",
                "source":"com.ecommerce.payment","account":"123456789012","time":"2026-08-21T12:00:01Z",
                "region":"sa-east-1","resources":[],"detail":{
                  "eventId":"payment-result-pay-1","eventVersion":"v1","eventType":"PaymentProcessed",
                  "occurredAt":"2026-08-21T12:00:00Z","correlationId":"corr-1",
                  "paymentId":"pay-1","orderId":"order-1","customerId":"customer-1",
                  "customerEmail":"customer@example.com","amount":99.99,"currency":"USD",
                  "gatewayTransactionId":"gateway-1","processedAt":"2026-08-21T12:00:00Z"}}
                """;
    }
}
