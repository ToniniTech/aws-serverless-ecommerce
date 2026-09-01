package com.ecommerce.serverless.order;

import com.ecommerce.serverless.contracts.PaymentFailedEvent;
import com.ecommerce.serverless.contracts.PaymentProcessedEvent;
import com.ecommerce.serverless.contracts.PaymentResultEvent;
import com.ecommerce.serverless.order.application.OrderPaymentResultRepository;
import com.ecommerce.serverless.order.infrastructure.config.DatabaseCredentials;
import com.ecommerce.serverless.order.infrastructure.config.DatabaseSettings;
import com.ecommerce.serverless.order.infrastructure.persistence.JdbcOrderPaymentResultRepository;
import com.ecommerce.serverless.order.infrastructure.persistence.OrderDatabase;
import com.ecommerce.serverless.order.infrastructure.persistence.OrderNotFoundException;
import com.ecommerce.serverless.order.infrastructure.persistence.OrderStateConflictException;
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
import java.sql.DriverManager;
import java.sql.Statement;
import java.time.Instant;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@Testcontainers(disabledWithoutDocker = true)
class OrderPaymentResultIntegrationTest {
    @Container
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("orders").withUsername("order_test").withPassword("order_test");
    private static final Instant NOW = Instant.parse("2026-08-21T12:00:00Z");
    private static HikariDataSource dataSource;
    private JdbcOrderPaymentResultRepository repository;

    @BeforeAll
    static void connect() throws SQLException {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            statement.execute("CREATE TABLE public.preexisting_payment_table (id UUID PRIMARY KEY)");
        }
        dataSource = OrderDatabase.connectAndMigrate(new DatabaseSettings(
                POSTGRES.getJdbcUrl(), new DatabaseCredentials(POSTGRES.getUsername(), POSTGRES.getPassword()), 2, 5_000));
    }

    @AfterAll
    static void close() {
        if (dataSource != null) dataSource.close();
    }

    @BeforeEach
    void reset() throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(
                     "TRUNCATE order_outbox, order_items, order_processed_events, orders")) {
            statement.executeUpdate();
        }
        repository = new JdbcOrderPaymentResultRepository(dataSource);
    }

    @Test
    void transitionsPendingToPaidAndRecordsEventAtomically() throws SQLException {
        insertPending("order-paid");

        OrderPaymentResultRepository.ApplyResult result = repository.apply(processed("evt-paid", "order-paid"), NOW);

        assertEquals("PAID", scalar("SELECT status FROM orders WHERE order_id = 'order-paid'"));
        assertEquals(1L, count("SELECT count(*) FROM order_processed_events WHERE event_id = 'evt-paid'"));
        assertEquals(1L, result.version());
        assertFalse(result.duplicate());
    }

    @Test
    void duplicatePaymentProcessedDoesNotApplyASecondEffect() throws SQLException {
        insertPending("order-duplicate");
        PaymentResultEvent event = processed("evt-duplicate", "order-duplicate");
        repository.apply(event, NOW);

        OrderPaymentResultRepository.ApplyResult duplicate = repository.apply(event, NOW.plusSeconds(1));

        assertTrue(duplicate.duplicate());
        assertEquals(1L, count("SELECT version FROM orders WHERE order_id = 'order-duplicate'"));
        assertEquals(1L, count("SELECT count(*) FROM order_processed_events"));
    }

    @Test
    void transitionsPendingToFailed() throws SQLException {
        insertPending("order-failed");

        repository.apply(failed("evt-failed", "order-failed"), NOW);

        assertEquals("FAILED", scalar("SELECT status FROM orders WHERE order_id = 'order-failed'"));
        assertEquals("CARD_EXPIRED", scalar("SELECT payment_failure_code FROM orders WHERE order_id = 'order-failed'"));
    }

    @Test
    void missingOrderAndConflictingTerminalResultRemainRetryable() throws SQLException {
        assertThrows(OrderNotFoundException.class,
                () -> repository.apply(processed("evt-missing", "missing"), NOW));
        assertEquals(0L, count("SELECT count(*) FROM order_processed_events"));

        insertPending("order-conflict");
        repository.apply(processed("evt-success", "order-conflict"), NOW);
        assertThrows(OrderStateConflictException.class,
                () -> repository.apply(failed("evt-failure", "order-conflict"), NOW.plusSeconds(1)));
        assertEquals("PAID", scalar("SELECT status FROM orders WHERE order_id = 'order-conflict'"));
    }

    private static PaymentProcessedEvent processed(String eventId, String orderId) {
        return new PaymentProcessedEvent(eventId, "v1", "PaymentProcessed", NOW, "corr-1", "pay-" + orderId,
                orderId, "customer-1", "customer@example.com", new BigDecimal("99.99"), "USD", "gateway-1", NOW);
    }

    private static PaymentFailedEvent failed(String eventId, String orderId) {
        return new PaymentFailedEvent(eventId, "v1", "PaymentFailed", NOW, "corr-1", "pay-" + orderId,
                orderId, "customer-1", "customer@example.com", new BigDecimal("100.13"), "USD",
                "CARD_EXPIRED", "Card expired", NOW);
    }

    private static void insertPending(String orderId) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(
                     """
                     INSERT INTO orders
                         (id, order_id, status, customer_id, customer_email, idempotency_key, total_amount, currency)
                     VALUES (?, ?, 'PENDING', 'customer-test', 'customer@example.com', ?, 99.99, 'USD')
                     """)) {
            statement.setObject(1, UUID.randomUUID());
            statement.setString(2, orderId);
            statement.setString(3, "test-" + orderId);
            statement.executeUpdate();
        }
    }

    private static String scalar(String sql) throws SQLException {
        try (Connection connection = dataSource.getConnection(); PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet rs = statement.executeQuery()) { rs.next(); return rs.getString(1); }
    }

    private static long count(String sql) throws SQLException {
        try (Connection connection = dataSource.getConnection(); PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet rs = statement.executeQuery()) { rs.next(); return rs.getLong(1); }
    }
}
