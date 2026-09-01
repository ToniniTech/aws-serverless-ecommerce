package com.ecommerce.serverless.saga;

import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.*;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.math.BigDecimal;
import java.sql.*;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

@Testcontainers(disabledWithoutDocker = true)
class SagaIntegrationTest {
    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("saga").withUsername("saga_test").withPassword("saga_test");
    static HikariDataSource dataSource;
    SagaApplicationService service;

    @BeforeAll static void connect() {
        dataSource = SagaDatabase.connectAndMigrate(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }
    @AfterAll static void close() { if (dataSource != null) dataSource.close(); }
    @BeforeEach void reset() throws SQLException {
        try (Connection connection = dataSource.getConnection(); Statement statement = connection.createStatement()) {
            statement.execute("TRUNCATE saga_orders, saga_payments, saga_stock_reservations");
            statement.execute("UPDATE saga_inventory_products SET available_stock = CASE product_id WHEN 'prod-001' THEN 10 ELSE 25 END");
        }
        service = new SagaApplicationService(new JdbcSagaRepository(dataSource));
    }

    @Test void successReservesChargesAndConfirmsIdempotently() throws SQLException {
        SagaTaskRequest request = request("saga-success", "order-success", "129.99");
        assertFalse((Boolean) service.reserve(request).get("duplicate"));
        assertTrue((Boolean) service.processPayment(request).get("approved"));
        assertEquals("CONFIRMED", service.confirm(request).get("orderStatus"));

        assertTrue((Boolean) service.reserve(request).get("duplicate"));
        assertTrue((Boolean) service.processPayment(request).get("duplicate"));
        assertTrue((Boolean) service.confirm(request).get("duplicate"));
        assertEquals(9, scalarInt("SELECT available_stock FROM saga_inventory_products WHERE product_id = 'prod-001'"));
        assertEquals(1, scalarInt("SELECT count(*) FROM saga_orders"));
    }

    @Test void paymentFailureCompensatesStockOnlyOnce() throws SQLException {
        SagaTaskRequest request = request("saga-failed", "order-failed", "100.13");
        service.reserve(request);
        Map<String, Object> payment = service.processPayment(request);
        assertFalse((Boolean) payment.get("approved"));
        assertEquals("CARD_EXPIRED", payment.get("failureCode"));
        assertEquals("COMPENSATED", service.compensate(new SagaTaskRequest(
                request.sagaId(), request.orderId(), null, 0, null, null, "CARD_EXPIRED")).get("reservationStatus"));
        assertTrue((Boolean) service.compensate(new SagaTaskRequest(
                request.sagaId(), request.orderId(), null, 0, null, null, "CARD_EXPIRED")).get("duplicate"));
        assertEquals(10, scalarInt("SELECT available_stock FROM saga_inventory_products WHERE product_id = 'prod-001'"));
        assertEquals(0, scalarInt("SELECT count(*) FROM saga_orders"));
    }

    private static SagaTaskRequest request(String sagaId, String orderId, String amount) {
        return new SagaTaskRequest(sagaId, orderId, "prod-001", 1, new BigDecimal(amount), "USD", null);
    }
    private static int scalarInt(String sql) throws SQLException {
        try (Connection connection = dataSource.getConnection(); Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(sql)) { rows.next(); return rows.getInt(1); }
    }
}
