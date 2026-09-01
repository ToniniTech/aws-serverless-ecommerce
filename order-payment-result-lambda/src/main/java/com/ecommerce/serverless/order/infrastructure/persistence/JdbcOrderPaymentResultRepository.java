package com.ecommerce.serverless.order.infrastructure.persistence;

import com.ecommerce.serverless.contracts.PaymentFailedEvent;
import com.ecommerce.serverless.contracts.PaymentResultEvent;
import com.ecommerce.serverless.order.application.OrderPaymentResultRepository;
import com.ecommerce.serverless.order.domain.OrderStatus;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;

public final class JdbcOrderPaymentResultRepository implements OrderPaymentResultRepository {
    private final DataSource dataSource;

    public JdbcOrderPaymentResultRepository(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @Override
    public ApplyResult apply(PaymentResultEvent event, Instant processedAt) {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try {
                ApplyResult duplicate = findProcessed(connection, event.eventId());
                if (duplicate != null) {
                    connection.commit();
                    return duplicate;
                }

                CurrentOrder current = findOrderForUpdate(connection, event.orderId());
                if (current == null) {
                    throw new OrderNotFoundException(event.orderId());
                }
                OrderStatus target = event instanceof PaymentFailedEvent ? OrderStatus.FAILED : OrderStatus.PAID;
                if (current.status() != OrderStatus.PENDING && current.status() != target) {
                    throw new OrderStateConflictException(
                            "Cannot apply " + event.eventType() + " to order " + event.orderId()
                                    + " in status " + current.status());
                }

                boolean duplicateEffect = current.status() == target;
                long version = current.version();
                if (!duplicateEffect) {
                    version = updateOrder(connection, event, target, processedAt);
                }
                insertProcessedEvent(connection, event, target, duplicateEffect, processedAt);
                connection.commit();
                return new ApplyResult(event.orderId(), target, duplicateEffect, version);
            } catch (SQLException | RuntimeException exception) {
                rollback(connection);
                throw exception;
            }
        } catch (SQLException exception) {
            throw new OrderPersistenceException("Could not apply payment result atomically", exception);
        }
    }

    private static ApplyResult findProcessed(Connection connection, String eventId) throws SQLException {
        String sql = "SELECT o.order_id, o.status, o.version FROM order_processed_events pe "
                + "JOIN orders o ON o.order_id = pe.order_id WHERE pe.event_id = ?";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, eventId);
            try (ResultSet rs = statement.executeQuery()) {
                return rs.next()
                        ? new ApplyResult(rs.getString(1), OrderStatus.valueOf(rs.getString(2)), true, rs.getLong(3))
                        : null;
            }
        }
    }

    private static CurrentOrder findOrderForUpdate(Connection connection, String orderId) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT status, version FROM orders WHERE order_id = ? FOR UPDATE")) {
            statement.setString(1, orderId);
            try (ResultSet rs = statement.executeQuery()) {
                return rs.next() ? new CurrentOrder(OrderStatus.valueOf(rs.getString(1)), rs.getLong(2)) : null;
            }
        }
    }

    private static long updateOrder(
            Connection connection, PaymentResultEvent event, OrderStatus status, Instant now) throws SQLException {
        String failureCode = event instanceof PaymentFailedEvent failed ? failed.failureCode() : null;
        String failureReason = event instanceof PaymentFailedEvent failed ? failed.failureReason() : null;
        String sql = "UPDATE orders SET status = ?, payment_id = ?, payment_failure_code = ?, "
                + "payment_failure_reason = ?, version = version + 1, updated_at = ? "
                + "WHERE order_id = ? AND status = 'PENDING' RETURNING version";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, status.name());
            statement.setString(2, event.paymentId());
            statement.setString(3, failureCode);
            statement.setString(4, failureReason);
            statement.setTimestamp(5, Timestamp.from(now));
            statement.setString(6, event.orderId());
            try (ResultSet rs = statement.executeQuery()) {
                if (!rs.next()) {
                    throw new SQLException("PENDING order transition lost its row lock");
                }
                return rs.getLong(1);
            }
        }
    }

    private static void insertProcessedEvent(
            Connection connection,
            PaymentResultEvent event,
            OrderStatus status,
            boolean duplicateEffect,
            Instant now) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                INSERT INTO order_processed_events
                    (event_id, event_type, order_id, payment_id, resulting_status, outcome, processed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)) {
            statement.setString(1, event.eventId());
            statement.setString(2, event.eventType());
            statement.setString(3, event.orderId());
            statement.setString(4, event.paymentId());
            statement.setString(5, status.name());
            statement.setString(6, duplicateEffect ? "ALREADY_APPLIED" : "APPLIED");
            statement.setTimestamp(7, Timestamp.from(now));
            statement.executeUpdate();
        }
    }

    private static void rollback(Connection connection) {
        try {
            connection.rollback();
        } catch (SQLException ignored) {
            // Preserve the original exception.
        }
    }

    private record CurrentOrder(OrderStatus status, long version) {
    }
}
