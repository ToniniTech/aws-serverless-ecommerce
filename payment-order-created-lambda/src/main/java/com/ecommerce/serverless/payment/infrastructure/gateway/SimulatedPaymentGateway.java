package com.ecommerce.serverless.payment.infrastructure.gateway;

import com.ecommerce.serverless.payment.application.PaymentGateway;

import java.math.BigDecimal;

/**
 * Deterministic educational gateway. A real adapter must pass idempotencyKey to the provider.
 */
public final class SimulatedPaymentGateway implements PaymentGateway {
    private static final BigDecimal SINGLE_PAYMENT_LIMIT = new BigDecimal("1000.00");
    private static final BigDecimal EXPIRED_CARD_FRACTION = new BigDecimal("0.13");

    @Override
    public GatewayResult charge(ChargeRequest request) {
        if (request.amount().compareTo(SINGLE_PAYMENT_LIMIT) > 0) {
            return GatewayResult.failure(
                    "AMOUNT_EXCEEDS_LIMIT",
                    "Transaction amount exceeds the single-payment limit of 1000");
        }

        if (request.amount().remainder(BigDecimal.ONE).compareTo(EXPIRED_CARD_FRACTION) == 0) {
            return GatewayResult.failure("CARD_EXPIRED", "Card has expired");
        }

        String transactionId = "gw-txn-" + request.idempotencyKey()
                .substring(request.idempotencyKey().length() - 16);
        return GatewayResult.success(transactionId);
    }
}
