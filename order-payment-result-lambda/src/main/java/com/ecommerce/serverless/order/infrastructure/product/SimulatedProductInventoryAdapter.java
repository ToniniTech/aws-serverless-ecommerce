package com.ecommerce.serverless.order.infrastructure.product;

import com.ecommerce.serverless.order.application.ProductInventoryPort;

import java.math.BigDecimal;
import java.util.Map;

/**
 * Deterministic, stateless Product boundary for the AWS demonstration profile.
 * It deliberately does not model concurrent stock ownership; use the HTTP profile for that comparison.
 */
public final class SimulatedProductInventoryAdapter implements ProductInventoryPort {
    private static final Map<String, SimulatedProduct> CATALOG = Map.of(
            "prod-001", new SimulatedProduct("Mechanical Keyboard", new BigDecimal("129.99"), 10),
            "prod-002", new SimulatedProduct("Wireless Mouse", new BigDecimal("49.90"), 25));

    @Override
    public ReservedProduct reserve(String productId, int quantity) {
        if (productId == null || productId.isBlank()) {
            throw new ProductInventoryException("productId is required");
        }
        if (quantity <= 0) {
            throw new ProductInventoryException("quantity must be positive");
        }
        SimulatedProduct product = CATALOG.get(productId);
        if (product == null) {
            throw new ProductInventoryException("Simulated product not found: " + productId);
        }
        if (quantity > product.availableStock()) {
            throw new ProductInventoryException("Insufficient simulated stock for product: " + productId);
        }
        return new ReservedProduct(productId, product.name(), product.unitPrice());
    }

    private record SimulatedProduct(String name, BigDecimal unitPrice, int availableStock) {
    }
}
