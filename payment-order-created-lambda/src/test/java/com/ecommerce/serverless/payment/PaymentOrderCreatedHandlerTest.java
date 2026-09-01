package com.ecommerce.serverless.payment;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.events.SQSBatchResponse;
import com.amazonaws.services.lambda.runtime.events.SQSEvent;
import com.ecommerce.serverless.contracts.OrderCreatedEventParser;
import com.ecommerce.serverless.payment.application.PaymentProcessingResult;
import com.ecommerce.serverless.payment.application.PaymentProcessor;
import com.ecommerce.serverless.payment.domain.PaymentStatus;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.math.BigDecimal;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PaymentOrderCreatedHandlerTest {
    private final PaymentProcessor processor = mock(PaymentProcessor.class);
    private final PaymentOrderCreatedHandler handler = new PaymentOrderCreatedHandler(
            new OrderCreatedEventParser(), processor);

    @Test
    void returnsOnlyInvalidRecordsAsBatchFailures() {
        when(processor.process(any())).thenReturn(completed());
        SQSEvent event = new SQSEvent();
        event.setRecords(List.of(message("valid", validEventJson()), message("invalid", "not-json")));

        SQSBatchResponse response = handler.handleRequest(event, context());

        assertEquals(1, response.getBatchItemFailures().size());
        assertEquals("invalid", response.getBatchItemFailures().get(0).getItemIdentifier());
        verify(processor).process(any());
    }

    @Test
    void retriesRecordWhenPaymentInfrastructureFails() {
        when(processor.process(any())).thenThrow(new IllegalStateException("database unavailable"));
        SQSEvent event = new SQSEvent();
        event.setRecords(List.of(message("retry", validEventJson())));

        SQSBatchResponse response = handler.handleRequest(event, context());

        assertEquals(1, response.getBatchItemFailures().size());
        assertEquals("retry", response.getBatchItemFailures().get(0).getItemIdentifier());
    }

    @Test
    void acknowledgesPersistedBusinessDecline() {
        when(processor.process(any())).thenReturn(new PaymentProcessingResult(
                "pay-1", "order-001", "evt-001", "corr-001", "customer-001", "customer@example.com",
                new BigDecimal("129.99"), "CLP", PaymentStatus.FAILED, false,
                "order-payment-v1-key", null, "CARD_EXPIRED", "Card expired",
                Instant.parse("2026-08-21T12:00:00Z")));
        SQSEvent event = new SQSEvent();
        event.setRecords(List.of(message("declined", validEventJson())));

        SQSBatchResponse response = handler.handleRequest(event, context());

        assertEquals(0, response.getBatchItemFailures().size());
    }

    @Test
    void acknowledgesPaymentAfterAtomicOutboxPersistence() {
        when(processor.process(any())).thenReturn(completed());
        SQSEvent event = new SQSEvent();
        event.setRecords(List.of(message("persisted", validEventJson())));

        SQSBatchResponse response = handler.handleRequest(event, context());

        assertEquals(0, response.getBatchItemFailures().size());
    }

    private static PaymentProcessingResult completed() {
        return new PaymentProcessingResult(
                "pay-1", "order-001", "evt-001", "corr-001", "customer-001", "customer@example.com",
                new BigDecimal("129.99"), "CLP", PaymentStatus.COMPLETED, false,
                "order-payment-v1-key", "gateway-1", null, null,
                Instant.parse("2026-08-21T12:00:00Z"));
    }

    private static SQSEvent.SQSMessage message(String id, String body) {
        SQSEvent.SQSMessage message = new SQSEvent.SQSMessage();
        message.setMessageId(id);
        message.setBody(body);
        message.setAttributes(Map.of("ApproximateReceiveCount", "1"));
        return message;
    }

    private static Context context() {
        Context context = mock(Context.class);
        LambdaLogger logger = mock(LambdaLogger.class);
        when(context.getLogger()).thenReturn(logger);
        return context;
    }

    static String validEventJson() {
        return """
                {"eventId":"evt-001","eventVersion":"v1","eventType":"OrderCreated",
                "occurredAt":"2026-08-21T12:00:00Z","correlationId":"corr-001",
                "orderId":"order-001","customerId":"customer-001",
                "customerEmail":"customer@example.com","totalAmount":129.99,"currency":"CLP",
                "items":[{"productId":"prod-001","productName":"Keyboard","quantity":1,
                "unitPrice":129.99,"subtotal":129.99}]}
                """;
    }
}
