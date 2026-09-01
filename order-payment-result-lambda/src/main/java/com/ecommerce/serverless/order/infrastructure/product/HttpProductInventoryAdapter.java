package com.ecommerce.serverless.order.infrastructure.product;

import com.ecommerce.serverless.order.application.ProductInventoryPort;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

public final class HttpProductInventoryAdapter implements ProductInventoryPort {
    private final HttpClient client;
    private final String baseUrl;
    private final Duration timeout;
    private final ObjectMapper objectMapper;

    public HttpProductInventoryAdapter(String baseUrl, Duration timeout) {
        this(HttpClient.newBuilder().connectTimeout(timeout).build(), baseUrl, timeout, new ObjectMapper());
    }

    HttpProductInventoryAdapter(HttpClient client, String baseUrl, Duration timeout, ObjectMapper objectMapper) {
        this.client = client;
        this.baseUrl = baseUrl.replaceAll("/+$", "");
        this.timeout = timeout;
        this.objectMapper = objectMapper;
    }

    @Override
    public ReservedProduct reserve(String productId, int quantity) {
        try {
            String encoded = URLEncoder.encode(productId, StandardCharsets.UTF_8).replace("+", "%20");
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(baseUrl + "/api/products/" + encoded + "/decreaseStock"))
                    .timeout(timeout)
                    .header("Content-Type", "application/json")
                    .method("PATCH", HttpRequest.BodyPublishers.ofString("{\"quantity\":" + quantity + "}"))
                    .build();
            HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() < 200 || response.statusCode() >= 300) {
                throw new ProductInventoryException(
                        "Product reservation failed with HTTP " + response.statusCode() + " for " + productId);
            }
            ProductResponse product = objectMapper.readValue(response.body(), ProductResponse.class);
            if (!product.active() || product.price() == null || product.price().signum() <= 0
                    || product.productId() == null || !product.productId().equals(productId)
                    || product.name() == null || product.name().isBlank()) {
                throw new ProductInventoryException("Product is inactive or has an invalid price: " + productId);
            }
            return new ReservedProduct(product.productId(), product.name(), product.price());
        } catch (ProductInventoryException exception) {
            throw exception;
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new ProductInventoryException("Product reservation was interrupted for " + productId, exception);
        } catch (Exception exception) {
            throw new ProductInventoryException("Product Service is unavailable for " + productId, exception);
        }
    }

    private record ProductResponse(
            String productId,
            String name,
            java.math.BigDecimal price,
            Integer stock,
            boolean active) {
    }
}
