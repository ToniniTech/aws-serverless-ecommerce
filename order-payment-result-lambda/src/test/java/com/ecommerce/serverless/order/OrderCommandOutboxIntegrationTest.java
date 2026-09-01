package com.ecommerce.serverless.order;

import com.ecommerce.serverless.order.application.CreateOrderCommand;
import com.ecommerce.serverless.order.application.CreatedOrder;
import com.ecommerce.serverless.order.application.OrderCommandService;
import com.ecommerce.serverless.order.application.ProductInventoryPort;
import com.ecommerce.serverless.order.infrastructure.config.DatabaseCredentials;
import com.ecommerce.serverless.order.infrastructure.config.DatabaseSettings;
import com.ecommerce.serverless.order.infrastructure.persistence.JdbcOrderCommandRepository;
import com.ecommerce.serverless.order.infrastructure.persistence.JdbcOrderOutboxRepository;
import com.ecommerce.serverless.order.infrastructure.persistence.JdbcOrderQueryRepository;
import com.ecommerce.serverless.order.infrastructure.persistence.OrderDatabase;
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
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@Testcontainers(disabledWithoutDocker = true)
class OrderCommandOutboxIntegrationTest {
    @Container
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("orders").withUsername("order_test").withPassword("order_test");
    private static final Clock CLOCK = Clock.fixed(Instant.parse("2026-08-21T12:00:00Z"), ZoneOffset.UTC);
    private static HikariDataSource dataSource;
    private AtomicInteger reservations;
    private OrderCommandService service;

    @BeforeAll
    static void connect() {
        dataSource = OrderDatabase.connectAndMigrate(new DatabaseSettings(
                POSTGRES.getJdbcUrl(), new DatabaseCredentials(POSTGRES.getUsername(), POSTGRES.getPassword()), 2, 5_000));
    }

    @AfterAll
    static void close() {
        if (dataSource != null) dataSource.close();
    }

    @BeforeEach
    void reset() throws SQLException {
        try (Connection connection = dataSource.getConnection(); PreparedStatement statement = connection.prepareStatement(
                "TRUNCATE order_outbox, order_items, order_processed_events, orders")) {
            statement.executeUpdate();
        }
        reservations = new AtomicInteger();
        ProductInventoryPort inventory = (productId, quantity) -> {
            reservations.incrementAndGet();
            return new ProductInventoryPort.ReservedProduct(productId, "Keyboard", new BigDecimal("25.00"));
        };
        service = new OrderCommandService(new JdbcOrderCommandRepository(dataSource), inventory, CLOCK);
    }

    @Test
    void commitsOrderItemsAndOutboxInOneTransaction() throws SQLException {
        CreatedOrder created = service.create(command("request-1"));

        assertFalse(created.duplicate());
        assertEquals(new BigDecimal("50.00"), created.event().totalAmount());
        assertEquals(1L, scalar("SELECT count(*) FROM orders"));
        assertEquals(1L, scalar("SELECT count(*) FROM order_items"));
        assertEquals(1L, scalar("SELECT count(*) FROM order_outbox WHERE status = 'PENDING'"));
    }

    @Test
    void readsThePersistedOrderAndItemsAsOneProjection() {
        CreatedOrder created = service.create(command("query-order"));

        var order = new JdbcOrderQueryRepository(dataSource).findByOrderId(created.event().orderId()).orElseThrow();

        assertEquals("PENDING", order.status());
        assertEquals(new BigDecimal("50.00"), order.totalAmount());
        assertEquals(1, order.items().size());
        assertEquals("product-1", order.items().get(0).productId());
    }

    @Test
    void duplicateCommandDoesNotReserveStockAgainOrCreateAnotherOutbox() throws SQLException {
        CreatedOrder first = service.create(command("same-request"));
        CreatedOrder duplicate = service.create(command("same-request"));

        assertTrue(duplicate.duplicate());
        assertEquals(first.event().orderId(), duplicate.event().orderId());
        assertEquals(1, reservations.get());
        assertEquals(1L, scalar("SELECT count(*) FROM orders"));
        assertEquals(1L, scalar("SELECT count(*) FROM order_outbox"));
    }

    @Test
    void snsFailureLeavesOrderOutboxRetryableAndStable() throws SQLException {
        CreatedOrder created = service.create(command("sns-retry"));
        JdbcOrderOutboxRepository repository = new JdbcOrderOutboxRepository(dataSource);
        OutboxProcessor failing = new OutboxProcessor(
                repository, message -> { throw new IllegalStateException("SNS unavailable"); },
                CLOCK, 10, Duration.ofMinutes(2));

        assertThrows(OutboxBatchException.class, failing::processBatch);
        assertEquals(1L, scalar("SELECT count(*) FROM order_outbox WHERE status = 'PENDING' AND attempt_count = 1"));

        AtomicInteger published = new AtomicInteger();
        OutboxProcessor recovered = new OutboxProcessor(
                repository, message -> {
                    assertEquals(created.event().eventId(), message.eventId());
                    published.incrementAndGet();
                }, Clock.offset(CLOCK, Duration.ofSeconds(2)), 10, Duration.ofMinutes(2));
        recovered.processBatch();

        assertEquals(1, published.get());
        assertEquals(1L, scalar("SELECT count(*) FROM order_outbox WHERE status = 'PUBLISHED'"));
    }

    @Test
    void productFailureCreatesNeitherOrderNorOutbox() throws SQLException {
        OrderCommandService failingService = new OrderCommandService(
                new JdbcOrderCommandRepository(dataSource),
                (productId, quantity) -> { throw new IllegalStateException("Product unavailable"); }, CLOCK);

        assertThrows(IllegalStateException.class, () -> failingService.create(command("product-failure")));
        assertEquals(0L, scalar("SELECT count(*) FROM orders"));
        assertEquals(0L, scalar("SELECT count(*) FROM order_outbox"));
    }

    private static CreateOrderCommand command(String key) {
        return new CreateOrderCommand(
                "customer-1", "customer@example.com", key, "corr-" + key, "USD",
                List.of(new CreateOrderCommand.Item("product-1", 2)));
    }

    private static long scalar(String sql) throws SQLException {
        try (Connection connection = dataSource.getConnection(); PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet rs = statement.executeQuery()) { rs.next(); return rs.getLong(1); }
    }
}
