package com.ecommerce.serverless.order.infrastructure.persistence;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;
import com.ecommerce.serverless.order.application.CreatedOrder;
import com.ecommerce.serverless.order.application.OrderCommandRepository;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

public final class JdbcOrderCommandRepository implements OrderCommandRepository {
    private final DataSource dataSource;
    private final ObjectMapper objectMapper = new ObjectMapper().registerModule(new JavaTimeModule());

    public JdbcOrderCommandRepository(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @Override
    public Optional<OrderCreatedEvent> findByIdempotencyKey(String idempotencyKey) {
        try (Connection connection = dataSource.getConnection()) {
            return findByIdempotencyKey(connection, idempotencyKey);
        } catch (SQLException exception) {
            throw new OrderPersistenceException("Could not query Order idempotency key", exception);
        }
    }

    @Override
    public CreatedOrder saveOrderAndOutbox(String idempotencyKey, OrderCreatedEvent event, Instant createdAt) {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try {
                if (!insertOrder(connection, idempotencyKey, event, createdAt)) {
                    OrderCreatedEvent existing = findByIdempotencyKey(connection, idempotencyKey)
                            .orElseThrow(() -> new SQLException("Order idempotency conflict has no Outbox payload"));
                    connection.commit();
                    return new CreatedOrder(existing, true);
                }
                insertItems(connection, event);
                insertOutbox(connection, event, createdAt);
                connection.commit();
                return new CreatedOrder(event, false);
            } catch (SQLException | RuntimeException exception) {
                connection.rollback();
                throw exception;
            }
        } catch (SQLException exception) {
            throw new OrderPersistenceException("Could not persist Order and Outbox atomically", exception);
        }
    }

    private Optional<OrderCreatedEvent> findByIdempotencyKey(Connection connection, String key) throws SQLException {
        String sql = "SELECT ob.payload::text FROM orders o JOIN order_outbox ob ON ob.aggregate_id = o.order_id "
                + "WHERE o.idempotency_key = ?";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, key);
            try (ResultSet rs = statement.executeQuery()) {
                if (!rs.next()) return Optional.empty();
                try {
                    return Optional.of(objectMapper.readValue(rs.getString(1), OrderCreatedEvent.class));
                } catch (JsonProcessingException exception) {
                    throw new OrderPersistenceException("Stored OrderCreated payload is invalid", exception);
                }
            }
        }
    }

    private static boolean insertOrder(
            Connection connection, String idempotencyKey, OrderCreatedEvent event, Instant createdAt) throws SQLException {
        String sql = """
                INSERT INTO orders
                    (id, order_id, status, customer_id, customer_email, idempotency_key,
                     total_amount, currency, created_at, updated_at)
                VALUES (?, ?, 'PENDING', ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (idempotency_key) DO NOTHING
                """;
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, UUID.randomUUID());
            statement.setString(2, event.orderId());
            statement.setString(3, event.customerId());
            statement.setString(4, event.customerEmail());
            statement.setString(5, idempotencyKey);
            statement.setBigDecimal(6, event.totalAmount());
            statement.setString(7, event.currency());
            statement.setTimestamp(8, Timestamp.from(createdAt));
            statement.setTimestamp(9, Timestamp.from(createdAt));
            return statement.executeUpdate() == 1;
        }
    }

    private static void insertItems(Connection connection, OrderCreatedEvent event) throws SQLException {
        String sql = """
                INSERT INTO order_items
                    (id, order_id, product_id, product_name, quantity, unit_price, subtotal)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """;
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (OrderCreatedEvent.OrderItem item : event.items()) {
                statement.setObject(1, UUID.randomUUID());
                statement.setString(2, event.orderId());
                statement.setString(3, item.productId());
                statement.setString(4, item.productName());
                statement.setInt(5, item.quantity());
                statement.setBigDecimal(6, item.unitPrice());
                statement.setBigDecimal(7, item.subtotal());
                statement.addBatch();
            }
            statement.executeBatch();
        }
    }

    private void insertOutbox(Connection connection, OrderCreatedEvent event, Instant createdAt) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                INSERT INTO order_outbox
                    (id, event_id, event_type, aggregate_id, payload, status, next_attempt_at, created_at)
                VALUES (?, ?, 'OrderCreated', ?, ?::jsonb, 'PENDING', ?, ?)
                """)) {
            statement.setObject(1, UUID.randomUUID());
            statement.setString(2, event.eventId());
            statement.setString(3, event.orderId());
            statement.setString(4, objectMapper.writeValueAsString(event));
            statement.setTimestamp(5, Timestamp.from(createdAt));
            statement.setTimestamp(6, Timestamp.from(createdAt));
            statement.executeUpdate();
        } catch (JsonProcessingException exception) {
            throw new OrderPersistenceException("Could not serialize OrderCreated Outbox payload", exception);
        }
    }
}
