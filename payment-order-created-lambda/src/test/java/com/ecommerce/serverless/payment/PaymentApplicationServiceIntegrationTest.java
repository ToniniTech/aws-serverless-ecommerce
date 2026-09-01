package com.ecommerce.serverless.payment;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;
import com.ecommerce.serverless.payment.application.PaymentApplicationService;
import com.ecommerce.serverless.payment.application.PaymentProcessingResult;
import com.ecommerce.serverless.payment.domain.PaymentStatus;
import com.ecommerce.serverless.payment.infrastructure.config.DatabaseCredentials;
import com.ecommerce.serverless.payment.infrastructure.config.DatabaseSettings;
import com.ecommerce.serverless.payment.infrastructure.gateway.SimulatedPaymentGateway;
import com.ecommerce.serverless.payment.infrastructure.persistence.JdbcPaymentProcessingRepository;
import com.ecommerce.serverless.payment.infrastructure.persistence.JdbcPaymentOutboxRepository;
import com.ecommerce.serverless.payment.infrastructure.persistence.PaymentDatabase;
import com.ecommerce.serverless.outbox.OutboxBatchException;
import com.ecommerce.serverless.outbox.OutboxProcessor;
import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;

@Testcontainers(disabledWithoutDocker = true)
class PaymentApplicationServiceIntegrationTest {
    @Container
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("payments")
            .withUsername("payment_test")
            .withPassword("payment_test");

    private static final Clock CLOCK = Clock.fixed(
            Instant.parse("2026-08-21T12:00:00Z"), ZoneOffset.UTC);

    private static HikariDataSource dataSource;
    private PaymentApplicationService service;

    @BeforeAll
    static void connect() {
        dataSource = PaymentDatabase.connectAndMigrate(new DatabaseSettings(
                POSTGRES.getJdbcUrl(),
                new DatabaseCredentials(POSTGRES.getUsername(), POSTGRES.getPassword()),
                2,
                5_000));
    }

    @AfterAll
    static void close() {
        if (dataSource != null) {
            dataSource.close();
        }
    }

    @BeforeEach
    void resetDatabase() throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(
                     "TRUNCATE TABLE payment_outbox, processed_events, payments")) {
            statement.executeUpdate();
        }

        service = new PaymentApplicationService(
                new JdbcPaymentProcessingRepository(dataSource),
                new SimulatedPaymentGateway(),
                CLOCK,
                Duration.ofSeconds(60));
    }

    @Test
    void persistsSuccessfulPaymentAndProcessedEventInPostgresql() throws SQLException {
        PaymentProcessingResult result = service.process(event("evt-success", "order-success", "129.99"));

        assertEquals(PaymentStatus.COMPLETED, result.status());
        assertFalse(result.duplicate());
        assertEquals("COMPLETED", scalarString("SELECT status FROM payments WHERE order_id = 'order-success'"));
        assertEquals(1L, scalarLong("SELECT COUNT(*) FROM processed_events WHERE event_id = 'evt-success'"));
        assertEquals(1L, scalarLong("SELECT COUNT(*) FROM payment_outbox WHERE status = 'PENDING'"));
        assertTrue(result.gatewayIdempotencyKey().startsWith("order-payment-v1-"));
    }

    @Test
    void duplicateOrderCreatedDoesNotChargeOrCreateAnotherPayment() throws SQLException {
        PaymentProcessingResult first = service.process(event("evt-duplicate", "order-duplicate", "99.99"));
        PaymentProcessingResult duplicate = service.process(event("evt-duplicate", "order-duplicate", "99.99"));

        assertFalse(first.duplicate());
        assertTrue(duplicate.duplicate());
        assertEquals(first.paymentId(), duplicate.paymentId());
        assertEquals(1L, scalarLong("SELECT COUNT(*) FROM payments"));
        assertEquals(1L, scalarLong("SELECT COUNT(*) FROM processed_events"));
        assertEquals(1L, scalarLong("SELECT COUNT(*) FROM payment_outbox"));
    }

    @Test
    void persistsBusinessDeclineAndAcknowledgableProcessedEvent() throws SQLException {
        PaymentProcessingResult result = service.process(event("evt-declined", "order-declined", "100.13"));

        assertEquals(PaymentStatus.FAILED, result.status());
        assertEquals("CARD_EXPIRED", result.failureCode());
        assertEquals("FAILED", scalarString("SELECT status FROM payments WHERE order_id = 'order-declined'"));
        assertEquals(1L, scalarLong("SELECT COUNT(*) FROM processed_events WHERE outcome = 'FAILED'"));
    }

    @Test
    void differentEventIdForSameOrderIsRecordedWithoutSecondPayment() throws SQLException {
        service.process(event("evt-original", "order-one-payment", "50.00"));
        PaymentProcessingResult duplicate = service.process(
                event("evt-upstream-duplicate", "order-one-payment", "50.00"));

        assertTrue(duplicate.duplicate());
        assertEquals(1L, scalarLong("SELECT COUNT(*) FROM payments"));
        assertEquals(2L, scalarLong("SELECT COUNT(*) FROM processed_events"));
        assertEquals(1L, scalarLong(
                "SELECT COUNT(*) FROM processed_events WHERE event_id = 'evt-upstream-duplicate' "
                        + "AND outcome = 'DUPLICATE_ORDER'"));
    }

    @Test
    void outboxSurvivesAwsFailureAndCanBeRepublished() throws SQLException {
        service.process(event("evt-outbox-retry", "order-outbox-retry", "75.00"));
        JdbcPaymentOutboxRepository repository = new JdbcPaymentOutboxRepository(dataSource);
        OutboxProcessor failing = new OutboxProcessor(
                repository, message -> { throw new IllegalStateException("EventBridge unavailable"); },
                CLOCK, 10, Duration.ofMinutes(2));

        assertThrows(OutboxBatchException.class, failing::processBatch);
        assertEquals("PENDING", scalarString("SELECT status FROM payment_outbox"));
        assertEquals(1L, scalarLong("SELECT attempt_count FROM payment_outbox"));

        OutboxProcessor recovered = new OutboxProcessor(
                repository, message -> { }, Clock.offset(CLOCK, Duration.ofSeconds(2)), 10, Duration.ofMinutes(2));
        recovered.processBatch();

        assertEquals("PUBLISHED", scalarString("SELECT status FROM payment_outbox"));
    }

    @Test
    void skipLockedLetsAnotherWorkerClaimASeparateRow() throws SQLException {
        service.process(event("evt-locked", "order-locked", "70.00"));
        service.process(event("evt-available", "order-available", "80.00"));
        try (Connection lockConnection = dataSource.getConnection()) {
            lockConnection.setAutoCommit(false);
            try (PreparedStatement lock = lockConnection.prepareStatement(
                    "SELECT id FROM payment_outbox WHERE aggregate_id = 'order-locked' FOR UPDATE")) {
                lock.executeQuery();
                var claimed = new JdbcPaymentOutboxRepository(dataSource)
                        .claimBatch(10, CLOCK.instant(), Duration.ofMinutes(2));
                assertEquals(1, claimed.size());
                assertEquals("order-available", claimed.get(0).aggregateId());
            } finally {
                lockConnection.rollback();
            }
        }
    }

    private static OrderCreatedEvent event(String eventId, String orderId, String amount) {
        BigDecimal total = new BigDecimal(amount);
        return new OrderCreatedEvent(
                eventId,
                "v1",
                "OrderCreated",
                CLOCK.instant(),
                "correlation-" + orderId,
                orderId,
                "customer-001",
                "customer@example.com",
                total,
                "USD",
                List.of(new OrderCreatedEvent.OrderItem(
                        "product-001", "Keyboard", 1, total, total)));
    }

    private static long scalarLong(String sql) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet resultSet = statement.executeQuery()) {
            resultSet.next();
            return resultSet.getLong(1);
        }
    }

    private static String scalarString(String sql) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet resultSet = statement.executeQuery()) {
            resultSet.next();
            return resultSet.getString(1);
        }
    }
}
