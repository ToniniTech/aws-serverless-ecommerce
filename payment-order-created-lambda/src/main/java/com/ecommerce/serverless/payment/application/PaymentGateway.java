package com.ecommerce.serverless.payment.application;

import java.math.BigDecimal;

public interface PaymentGateway {
    GatewayResult charge(ChargeRequest request);

    record ChargeRequest(
            String orderId,
            BigDecimal amount,
            String currency,
            String idempotencyKey
    ) {
    }

    record GatewayResult(
            boolean approved,
            String transactionId,
            String failureCode,
            String failureReason
    ) {
        public static GatewayResult success(String transactionId) {
            return new GatewayResult(true, transactionId, null, null);
        }

        public static GatewayResult failure(String code, String reason) {
            return new GatewayResult(false, null, code, reason);
        }
    }
}
