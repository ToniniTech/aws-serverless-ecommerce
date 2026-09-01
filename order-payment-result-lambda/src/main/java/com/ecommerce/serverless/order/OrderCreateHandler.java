package com.ecommerce.serverless.order;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.ecommerce.serverless.order.application.CreateOrderCommand;
import com.ecommerce.serverless.order.application.CreatedOrder;
import com.ecommerce.serverless.order.infrastructure.product.ProductInventoryException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public final class OrderCreateHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {
    private static final ObjectMapper MAPPER = new ObjectMapper();

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent input, Context context) {
        String correlationId = null;
        try {
            Map<String, String> headers = input.getHeaders() == null ? Map.of() : input.getHeaders();
            String customerId = header(headers, "x-customer-id");
            String customerEmail = header(headers, "x-customer-email");
            String idempotencyKey = header(headers, "idempotency-key");
            correlationId = optionalHeader(headers, "x-correlation-id", UUID.randomUUID().toString());
            String body = input.getIsBase64Encoded() == Boolean.TRUE
                    ? new String(Base64.getDecoder().decode(input.getBody()), StandardCharsets.UTF_8)
                    : input.getBody();
            CreateOrderBody request = MAPPER.readValue(body, CreateOrderBody.class);
            List<CreateOrderCommand.Item> items = request.items() == null ? List.of() : request.items().stream()
                    .map(item -> new CreateOrderCommand.Item(item.productId(), item.quantity())).toList();
            CreatedOrder created = OrderRuntime.commandService().create(new CreateOrderCommand(
                    customerId, customerEmail, idempotencyKey, correlationId,
                    System.getenv().getOrDefault("ORDER_CURRENCY", "CLP"), items));
            context.getLogger().log(MAPPER.writeValueAsString(Map.of(
                    "level", "INFO", "handler", "order-create", "eventId", created.event().eventId(),
                    "correlationId", created.event().correlationId(), "orderId", created.event().orderId(),
                    "duplicate", created.duplicate(), "message", "order_and_outbox_persisted",
                    "awsRequestId", safeRequestId(context))) + "\n");
            String response = MAPPER.writeValueAsString(new OrderResponse(
                    created.event().orderId(), created.event().eventId(), "PENDING",
                    created.event().totalAmount(), created.event().currency(), created.duplicate()));
            return response(created.duplicate() ? 200 : 201, response);
        } catch (IllegalArgumentException exception) {
            logFailure(context, "WARN", correlationId, exception);
            return response(400, jsonError(exception.getMessage()));
        } catch (ProductInventoryException exception) {
            logFailure(context, "ERROR", correlationId, exception);
            return response(503, jsonError(exception.getMessage()));
        } catch (Exception exception) {
            logFailure(context, "ERROR", correlationId, exception);
            return response(500, jsonError("Order creation failed"));
        }
    }

    private static void logFailure(Context context, String level, String correlationId, Exception exception) {
        try {
            java.util.LinkedHashMap<String, Object> fields = new java.util.LinkedHashMap<>();
            fields.put("level", level);
            fields.put("handler", "order-create");
            fields.put("message", "order_creation_failed");
            fields.put("errorType", exception.getClass().getSimpleName());
            fields.put("correlationId", correlationId == null ? "unavailable" : correlationId);
            fields.put("awsRequestId", safeRequestId(context));
            context.getLogger().log(MAPPER.writeValueAsString(fields) + "\n");
        } catch (Exception ignored) {
            context.getLogger().log("{\"level\":\"ERROR\",\"handler\":\"order-create\",\"message\":\"log_serialization_failed\"}\n");
        }
    }

    private static String safeRequestId(Context context) {
        String requestId = context.getAwsRequestId();
        return requestId == null ? "unknown" : requestId;
    }

    private static APIGatewayV2HTTPResponse response(int status, String body) {
        return APIGatewayV2HTTPResponse.builder().withStatusCode(status)
                .withHeaders(Map.of("Content-Type", "application/json")).withBody(body).build();
    }

    private static String header(Map<String, String> headers, String name) {
        String value = headers.entrySet().stream().filter(e -> e.getKey().equalsIgnoreCase(name))
                .map(Map.Entry::getValue).findFirst().orElse(null);
        if (value == null || value.isBlank()) throw new IllegalArgumentException(name + " header is required");
        return value;
    }

    private static String optionalHeader(Map<String, String> headers, String name, String fallback) {
        return headers.entrySet().stream().filter(e -> e.getKey().equalsIgnoreCase(name))
                .map(Map.Entry::getValue).filter(v -> !v.isBlank()).findFirst().orElse(fallback);
    }

    private static String jsonError(String message) {
        try { return MAPPER.writeValueAsString(Map.of("error", message == null ? "Unknown error" : message)); }
        catch (Exception ignored) { return "{\"error\":\"Serialization failed\"}"; }
    }

    private record CreateOrderBody(List<Item> items) {
        private record Item(String productId, int quantity) {
        }
    }

    private record OrderResponse(
            String orderId, String eventId, String status, java.math.BigDecimal totalAmount,
            String currency, boolean duplicate) {
    }
}
