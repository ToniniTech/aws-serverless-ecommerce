package com.ecommerce.serverless.order;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.LambdaLogger;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.ecommerce.serverless.order.application.OrderQueryService;
import com.ecommerce.serverless.order.application.OrderView;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class OrderGetHandlerTest {
    @Test
    void returnsOrderProjectionWithoutCustomerPii() {
        OrderView view = new OrderView(
                "order-1", "PAID", new BigDecimal("129.99"), "CLP", 1,
                "payment-1", null, null, Instant.parse("2026-08-21T12:00:00Z"),
                Instant.parse("2026-08-21T12:01:00Z"),
                List.of(new OrderView.Item("prod-001", "Mechanical Keyboard", 1,
                        new BigDecimal("129.99"), new BigDecimal("129.99"))));
        OrderGetHandler handler = new OrderGetHandler(new OrderQueryService(id -> Optional.of(view)));

        var response = handler.handleRequest(event("order-1"), context());

        assertEquals(200, response.getStatusCode());
        assertTrue(response.getBody().contains("\"status\":\"PAID\""));
        assertTrue(response.getBody().contains("\"productId\":\"prod-001\""));
        assertTrue(!response.getBody().contains("customerEmail"));
    }

    @Test
    void returnsNotFoundForMissingOrder() {
        OrderGetHandler handler = new OrderGetHandler(new OrderQueryService(id -> Optional.empty()));

        var response = handler.handleRequest(event("missing"), context());

        assertEquals(404, response.getStatusCode());
    }

    @Test
    void rejectsMissingPathParameter() {
        OrderGetHandler handler = new OrderGetHandler(new OrderQueryService(id -> Optional.empty()));
        APIGatewayV2HTTPEvent event = new APIGatewayV2HTTPEvent();

        var response = handler.handleRequest(event, context());

        assertEquals(400, response.getStatusCode());
    }

    private static APIGatewayV2HTTPEvent event(String orderId) {
        APIGatewayV2HTTPEvent event = new APIGatewayV2HTTPEvent();
        event.setPathParameters(Map.of("orderId", orderId));
        return event;
    }

    private static Context context() {
        Context context = mock(Context.class);
        when(context.getLogger()).thenReturn(mock(LambdaLogger.class));
        when(context.getAwsRequestId()).thenReturn("request-1");
        return context;
    }
}
