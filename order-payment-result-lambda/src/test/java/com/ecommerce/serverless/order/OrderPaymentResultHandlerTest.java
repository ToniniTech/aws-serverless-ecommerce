package com.ecommerce.serverless.order;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.events.SQSBatchResponse;
import com.amazonaws.services.lambda.runtime.events.SQSEvent;
import com.ecommerce.serverless.contracts.PaymentResultEventParser;
import com.ecommerce.serverless.order.application.OrderPaymentResultRepository;
import com.ecommerce.serverless.order.application.OrderPaymentResultService;
import com.ecommerce.serverless.order.domain.OrderStatus;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class OrderPaymentResultHandlerTest {
    private final OrderPaymentResultService service = mock(OrderPaymentResultService.class);
    private final OrderPaymentResultHandler handler = new OrderPaymentResultHandler(new PaymentResultEventParser(), service);

    @Test
    void reportsOnlyInvalidRecordAsBatchFailure() {
        when(service.apply(any())).thenReturn(new OrderPaymentResultRepository.ApplyResult(
                "order-1", OrderStatus.PAID, false, 1));
        SQSEvent input = new SQSEvent();
        input.setRecords(List.of(message("valid", envelope()), message("invalid", "{}")));

        SQSBatchResponse response = handler.handleRequest(input, context());

        assertEquals(1, response.getBatchItemFailures().size());
        assertEquals("invalid", response.getBatchItemFailures().get(0).getItemIdentifier());
    }

    @Test
    void databaseFailureLeavesMessageForSqsRetry() {
        when(service.apply(any())).thenThrow(new IllegalStateException("database unavailable"));
        SQSEvent input = new SQSEvent();
        input.setRecords(List.of(message("retry", envelope())));

        SQSBatchResponse response = handler.handleRequest(input, context());

        assertEquals("retry", response.getBatchItemFailures().get(0).getItemIdentifier());
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

    private static String envelope() {
        return """
                {"version":"0","id":"aws-id","detail-type":"PaymentProcessed",
                "source":"com.ecommerce.payment","detail":{
                "eventId":"payment-result-pay-1","eventVersion":"v1","eventType":"PaymentProcessed",
                "occurredAt":"2026-08-21T12:00:00Z","correlationId":"corr-1","paymentId":"pay-1",
                "orderId":"order-1","customerId":"customer-1","customerEmail":"customer@example.com",
                "amount":99.99,"currency":"USD","gatewayTransactionId":"gateway-1",
                "processedAt":"2026-08-21T12:00:00Z"}}
                """;
    }
}
