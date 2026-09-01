package com.ecommerce.serverless.notification;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.events.SQSEvent;
import com.amazonaws.services.lambda.runtime.events.SQSBatchResponse;
import com.ecommerce.serverless.notification.application.NotificationProcessor;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class NotificationDemoHandlerTest {
    private final NotificationProcessor processor = mock(NotificationProcessor.class);
    private final NotificationDemoHandler handler = new NotificationDemoHandler(
            new NotificationEventParser(), processor);

    @BeforeEach
    void setUp() {
        when(processor.process(any())).thenReturn(new NotificationProcessor.ProcessResult(
                UUID.fromString("d07024d8-fbb3-4f6e-b342-7badf7697752"), "CREATED", false));
    }

    @Test
    void returnsOnlyInvalidRecordsAsBatchFailures() {
        SQSEvent event = new SQSEvent();
        event.setRecords(List.of(message("valid", validEventJson()), message("invalid", "{}")));

        SQSBatchResponse response = handler.handleRequest(event, context());

        assertEquals(1, response.getBatchItemFailures().size());
        assertEquals("invalid", response.getBatchItemFailures().get(0).getItemIdentifier());
        verify(processor, times(1)).process(any());
    }

    @Test
    void returnsValidRecordAsFailedWhenIntentionalFailureIsRequested() {
        SQSEvent.SQSMessage message = message("forced", validEventJson());
        SQSEvent.MessageAttribute forceFailure = new SQSEvent.MessageAttribute();
        forceFailure.setDataType("String");
        forceFailure.setStringValue("true");
        message.setMessageAttributes(Map.of("forceFailure", forceFailure));

        SQSEvent event = new SQSEvent();
        event.setRecords(List.of(message));

        SQSBatchResponse response = handler.handleRequest(event, context());

        assertEquals(1, response.getBatchItemFailures().size());
        assertEquals("forced", response.getBatchItemFailures().get(0).getItemIdentifier());
        verify(processor, times(0)).process(any());
    }

    @Test
    void acceptsPaymentResultEventBridgeEnvelope() {
        SQSEvent event = new SQSEvent();
        event.setRecords(List.of(message("payment-result", paymentProcessedEnvelope())));

        SQSBatchResponse response = handler.handleRequest(event, context());

        assertEquals(0, response.getBatchItemFailures().size());
        verify(processor, times(1)).process(any());
    }

    @Test
    void acceptsDuplicateAsSuccessfullyHandled() {
        when(processor.process(any())).thenReturn(new NotificationProcessor.ProcessResult(
                UUID.fromString("d07024d8-fbb3-4f6e-b342-7badf7697752"), "CREATED", true));
        SQSEvent event = new SQSEvent();
        event.setRecords(List.of(message("duplicate", validEventJson())));

        SQSBatchResponse response = handler.handleRequest(event, context());

        assertEquals(0, response.getBatchItemFailures().size());
        verify(processor, times(1)).process(any());
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

    private static String validEventJson() {
        return """
                {"eventId":"evt-001","eventVersion":"v1","eventType":"OrderCreated",
                "occurredAt":"2026-08-21T12:00:00Z","correlationId":"corr-001",
                "orderId":"order-001","customerId":"customer-001",
                "customerEmail":"customer@example.com","totalAmount":129.99,"currency":"CLP",
                "items":[{"productId":"prod-001","productName":"Keyboard","quantity":1,
                "unitPrice":129.99,"subtotal":129.99}]}
                """;
    }

    private static String paymentProcessedEnvelope() {
        return """
                {"version":"0","id":"aws-id","detail-type":"PaymentProcessed",
                "source":"com.ecommerce.payment","detail":{
                "eventId":"payment-result-pay-1","eventVersion":"v1","eventType":"PaymentProcessed",
                "occurredAt":"2026-08-21T12:00:00Z","correlationId":"corr-001","paymentId":"pay-1",
                "orderId":"order-001","customerId":"customer-001","customerEmail":"customer@example.com",
                "amount":129.99,"currency":"CLP","gatewayTransactionId":"gateway-1",
                "processedAt":"2026-08-21T12:00:00Z"}}
                """;
    }
}
