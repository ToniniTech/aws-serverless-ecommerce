package com.ecommerce.serverless.payment;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;
import com.ecommerce.serverless.payment.application.PaymentApplicationService;
import com.ecommerce.serverless.payment.application.PaymentGateway;
import com.ecommerce.serverless.payment.application.PaymentInProgressException;
import com.ecommerce.serverless.payment.application.PaymentProcessingRepository;
import com.ecommerce.serverless.payment.application.PaymentProcessingResult;
import com.ecommerce.serverless.payment.domain.PaymentRecord;
import com.ecommerce.serverless.payment.domain.PaymentStatus;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PaymentApplicationServiceTest {
    private static final Clock CLOCK = Clock.fixed(
            Instant.parse("2026-08-21T12:00:00Z"), ZoneOffset.UTC);

    private final PaymentProcessingRepository repository = mock(PaymentProcessingRepository.class);
    private final PaymentGateway gateway = mock(PaymentGateway.class);
    private final PaymentApplicationService service = new PaymentApplicationService(
            repository, gateway, CLOCK, Duration.ofSeconds(60));

    @Test
    void finalizesApprovedGatewayResult() {
        OrderCreatedEvent event = event("evt-1", "order-1");
        PaymentRecord processing = payment(event, PaymentStatus.PROCESSING);
        PaymentRecord completed = payment(event, PaymentStatus.COMPLETED);
        when(repository.claim(any(), any(), any(), any())).thenReturn(new PaymentProcessingRepository.Claim(
                PaymentProcessingRepository.ClaimDisposition.CLAIMED, processing));
        when(gateway.charge(any())).thenReturn(PaymentGateway.GatewayResult.success("gateway-1"));
        when(repository.finalizePayment(any(), any(), any(), any())).thenReturn(completed);

        PaymentProcessingResult result = service.process(event);

        assertEquals(PaymentStatus.COMPLETED, result.status());
        verify(gateway).charge(any());
        verify(repository).finalizePayment(any(), any(), any(), any());
    }

    @Test
    void duplicateNeverCallsGateway() {
        OrderCreatedEvent event = event("evt-duplicate", "order-duplicate");
        PaymentRecord completed = payment(event, PaymentStatus.COMPLETED);
        when(repository.claim(any(), any(), any(), any())).thenReturn(new PaymentProcessingRepository.Claim(
                PaymentProcessingRepository.ClaimDisposition.DUPLICATE, completed));

        PaymentProcessingResult result = service.process(event);

        assertEquals(true, result.duplicate());
        verify(gateway, never()).charge(any());
    }

    @Test
    void inProgressPaymentRemainsRetryable() {
        OrderCreatedEvent event = event("evt-progress", "order-progress");
        when(repository.claim(any(), any(), any(), any())).thenReturn(new PaymentProcessingRepository.Claim(
                PaymentProcessingRepository.ClaimDisposition.IN_PROGRESS,
                payment(event, PaymentStatus.PROCESSING)));

        assertThrows(PaymentInProgressException.class, () -> service.process(event));
        verify(gateway, never()).charge(any());
    }

    @Test
    void gatewayIdempotencyKeyIsStablePerOrder() {
        String first = PaymentApplicationService.stableGatewayIdempotencyKey("order-123");
        String second = PaymentApplicationService.stableGatewayIdempotencyKey("order-123");
        String different = PaymentApplicationService.stableGatewayIdempotencyKey("order-456");

        assertEquals(first, second);
        assertNotEquals(first, different);
    }

    private static OrderCreatedEvent event(String eventId, String orderId) {
        BigDecimal amount = new BigDecimal("99.99");
        return new OrderCreatedEvent(
                eventId, "v1", "OrderCreated", CLOCK.instant(), "correlation-1", orderId,
                "customer-1", "customer@example.com", amount, "USD",
                List.of(new OrderCreatedEvent.OrderItem("product-1", "Keyboard", 1, amount, amount)));
    }

    private static PaymentRecord payment(OrderCreatedEvent event, PaymentStatus status) {
        Instant processedAt = status == PaymentStatus.PROCESSING ? null : CLOCK.instant();
        return new PaymentRecord(
                UUID.randomUUID(),
                "pay-test",
                event.orderId(),
                event.eventId(),
                event.correlationId(),
                PaymentApplicationService.stableGatewayIdempotencyKey(event.orderId()),
                event.customerId(),
                event.customerEmail(),
                event.totalAmount(),
                event.currency(),
                status,
                status == PaymentStatus.COMPLETED ? "gateway-1" : null,
                null,
                null,
                CLOCK.instant(),
                processedAt);
    }
}
