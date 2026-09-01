package com.ecommerce.serverless.order.infrastructure.product;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SimulatedProductInventoryAdapterTest {
    private final SimulatedProductInventoryAdapter adapter = new SimulatedProductInventoryAdapter();

    @Test
    void returnsDeterministicCatalogData() {
        var product = adapter.reserve("prod-001", 2);

        assertEquals("prod-001", product.productId());
        assertEquals("Mechanical Keyboard", product.productName());
        assertEquals(new BigDecimal("129.99"), product.unitPrice());
    }

    @Test
    void rejectsUnknownProduct() {
        assertThrows(ProductInventoryException.class, () -> adapter.reserve("unknown", 1));
    }

    @Test
    void rejectsQuantityAboveSimulatedStock() {
        assertThrows(ProductInventoryException.class, () -> adapter.reserve("prod-001", 11));
    }
}
