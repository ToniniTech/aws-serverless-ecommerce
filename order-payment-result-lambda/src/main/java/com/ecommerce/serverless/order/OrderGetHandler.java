package com.ecommerce.serverless.order;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.ecommerce.serverless.order.application.OrderQueryService;
import com.ecommerce.serverless.order.application.OrderView;
import com.ecommerce.serverless.order.infrastructure.persistence.OrderNotFoundException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;

import java.util.LinkedHashMap;
import java.util.Map;

public final class OrderGetHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {
    private static final ObjectMapper MAPPER = new ObjectMapper()
            .registerModule(new JavaTimeModule())
            .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

    private final OrderQueryService service;

    public OrderGetHandler() {
        this(OrderRuntime.queryService());
    }

    OrderGetHandler(OrderQueryService service) {
        this.service = service;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent input, Context context) {
        String orderId = input.getPathParameters() == null ? null : input.getPathParameters().get("orderId");
        try {
            OrderView order = service.findByOrderId(orderId);
            log(context, "INFO", "order_queried", order.orderId(), order.status(), null);
            return response(200, MAPPER.writeValueAsString(order));
        } catch (IllegalArgumentException exception) {
            log(context, "WARN", "order_query_rejected", orderId, null, exception);
            return response(400, error(exception.getMessage()));
        } catch (OrderNotFoundException exception) {
            log(context, "INFO", "order_not_found", orderId, null, exception);
            return response(404, error(exception.getMessage()));
        } catch (Exception exception) {
            log(context, "ERROR", "order_query_failed", orderId, null, exception);
            return response(500, error("Order query failed"));
        }
    }

    private static void log(
            Context context, String level, String message, String orderId, String status, Exception exception) {
        try {
            Map<String, Object> fields = new LinkedHashMap<>();
            fields.put("level", level);
            fields.put("handler", "order-get");
            fields.put("message", message);
            fields.put("orderId", orderId == null ? "unavailable" : orderId);
            if (status != null) fields.put("status", status);
            if (exception != null) fields.put("errorType", exception.getClass().getSimpleName());
            fields.put("awsRequestId", context.getAwsRequestId() == null ? "unknown" : context.getAwsRequestId());
            context.getLogger().log(MAPPER.writeValueAsString(fields) + "\n");
        } catch (Exception ignored) {
            context.getLogger().log("{\"level\":\"ERROR\",\"handler\":\"order-get\",\"message\":\"log_serialization_failed\"}\n");
        }
    }

    private static APIGatewayV2HTTPResponse response(int status, String body) {
        return APIGatewayV2HTTPResponse.builder().withStatusCode(status)
                .withHeaders(Map.of("Content-Type", "application/json")).withBody(body).build();
    }

    private static String error(String message) {
        try {
            return MAPPER.writeValueAsString(Map.of("error", message == null ? "Unknown error" : message));
        } catch (Exception ignored) {
            return "{\"error\":\"Serialization failed\"}";
        }
    }
}
