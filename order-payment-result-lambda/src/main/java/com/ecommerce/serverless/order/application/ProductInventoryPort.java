package com.ecommerce.serverless.order.application;

import java.math.BigDecimal;

public interface ProductInventoryPort {
    ReservedProduct reserve(String productId, int quantity);

    record ReservedProduct(String productId, String productName, BigDecimal unitPrice) {
    }
}
