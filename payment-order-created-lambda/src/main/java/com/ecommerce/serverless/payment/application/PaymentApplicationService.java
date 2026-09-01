package com.ecommerce.serverless.payment.application;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;
import com.ecommerce.serverless.payment.domain.PaymentRecord;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Duration;
import java.util.HexFormat;

public final class PaymentApplicationService implements PaymentProcessor {
    private static final String IDEMPOTENCY_KEY_PREFIX = "order-payment-v1-";

    private final PaymentProcessingRepository repository;
    private final PaymentGateway gateway;
    private final Clock clock;
    private final Duration processingLease;

    public PaymentApplicationService(
            PaymentProcessingRepository repository,
            PaymentGateway gateway,
            Clock clock,
            Duration processingLease) {
        this.repository = repository;
        this.gateway = gateway;
        this.clock = clock;
        this.processingLease = processingLease;
    }

    @Override
    public PaymentProcessingResult process(OrderCreatedEvent event) {
        String idempotencyKey = stableGatewayIdempotencyKey(event.orderId());
        PaymentProcessingRepository.Claim claim = repository.claim(
                event,
                idempotencyKey,
                clock.instant(),
                processingLease);

        if (claim.disposition() == PaymentProcessingRepository.ClaimDisposition.DUPLICATE) {
            return PaymentProcessingResult.duplicate(claim.payment());
        }
        if (claim.disposition() == PaymentProcessingRepository.ClaimDisposition.IN_PROGRESS) {
            throw new PaymentInProgressException(event.orderId());
        }

        PaymentRecord payment = claim.payment();
        PaymentGateway.GatewayResult gatewayResult = gateway.charge(new PaymentGateway.ChargeRequest(
                payment.orderId(),
                payment.amount(),
                payment.currency(),
                payment.gatewayIdempotencyKey()));

        var processedAt = clock.instant();
        var resultEvent = PaymentResultEventFactory.create(payment, gatewayResult, processedAt);
        PaymentRecord finalized = repository.finalizePayment(payment, gatewayResult, resultEvent, processedAt);
        return PaymentProcessingResult.processed(finalized);
    }

    public static String stableGatewayIdempotencyKey(String orderId) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(orderId.getBytes(StandardCharsets.UTF_8));
            return IDEMPOTENCY_KEY_PREFIX + HexFormat.of().formatHex(digest, 0, 16);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is required by the Java runtime", exception);
        }
    }
}
