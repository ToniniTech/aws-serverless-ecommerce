package com.ecommerce.serverless.saga;

import javax.sql.DataSource;
import java.sql.*;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

final class JdbcSagaRepository implements SagaRepository {
    private final DataSource dataSource;
    JdbcSagaRepository(DataSource dataSource) { this.dataSource = dataSource; }

    @Override
    public Map<String, Object> reserve(SagaTaskRequest request) {
        return transaction(connection -> {
            Map<String, Object> existing = reservation(connection, request.sagaId());
            if (existing != null) { existing.put("duplicate", true); return existing; }
            int available;
            try (PreparedStatement statement = connection.prepareStatement(
                    "SELECT available_stock FROM saga_inventory_products WHERE product_id = ? FOR UPDATE")) {
                statement.setString(1, request.productId());
                try (ResultSet rows = statement.executeQuery()) {
                    if (!rows.next()) throw new IllegalStateException("Unknown Saga product: " + request.productId());
                    available = rows.getInt(1);
                }
            }
            if (available < request.quantity()) throw new IllegalStateException("Insufficient Saga stock");
            try (PreparedStatement update = connection.prepareStatement(
                    "UPDATE saga_inventory_products SET available_stock = available_stock - ?, updated_at = CURRENT_TIMESTAMP WHERE product_id = ?");
                 PreparedStatement insert = connection.prepareStatement(
                    "INSERT INTO saga_stock_reservations (reservation_id, saga_id, order_id, product_id, quantity, status) VALUES (?, ?, ?, ?, ?, 'RESERVED')")) {
                update.setInt(1, request.quantity()); update.setString(2, request.productId()); update.executeUpdate();
                insert.setObject(1, UUID.randomUUID()); insert.setString(2, request.sagaId());
                insert.setString(3, request.orderId()); insert.setString(4, request.productId());
                insert.setInt(5, request.quantity()); insert.executeUpdate();
            }
            return reservation(connection, request.sagaId());
        });
    }

    @Override
    public Map<String, Object> recordPayment(SagaTaskRequest request, String failureCode) {
        return transaction(connection -> {
            Map<String, Object> existing = payment(connection, request.sagaId());
            if (existing != null) { existing.put("duplicate", true); return existing; }
            requireReservation(connection, request.sagaId(), "RESERVED", false);
            UUID paymentId = UUID.randomUUID();
            String status = failureCode == null ? "COMPLETED" : "FAILED";
            try (PreparedStatement insert = connection.prepareStatement(
                    "INSERT INTO saga_payments (payment_id, saga_id, order_id, amount, currency, status, failure_code) VALUES (?, ?, ?, ?, ?, ?, ?)")) {
                insert.setObject(1, paymentId); insert.setString(2, request.sagaId());
                insert.setString(3, request.orderId()); insert.setBigDecimal(4, request.amount());
                insert.setString(5, request.currency()); insert.setString(6, status);
                insert.setString(7, failureCode); insert.executeUpdate();
            }
            return payment(connection, request.sagaId());
        });
    }

    @Override
    public Map<String, Object> confirm(SagaTaskRequest request) {
        return transaction(connection -> {
            Map<String, Object> existing = order(connection, request.sagaId());
            if (existing != null) { existing.put("duplicate", true); return existing; }
            requireReservation(connection, request.sagaId(), "RESERVED", false);
            try (PreparedStatement check = connection.prepareStatement(
                    "SELECT status FROM saga_payments WHERE saga_id = ?")) {
                check.setString(1, request.sagaId());
                try (ResultSet rows = check.executeQuery()) {
                    if (!rows.next() || !"COMPLETED".equals(rows.getString(1))) {
                        throw new IllegalStateException("Payment must be COMPLETED before confirmation");
                    }
                }
            }
            try (PreparedStatement insert = connection.prepareStatement(
                    "INSERT INTO saga_orders (saga_id, order_id, status) VALUES (?, ?, 'CONFIRMED')")) {
                insert.setString(1, request.sagaId()); insert.setString(2, request.orderId()); insert.executeUpdate();
            }
            return order(connection, request.sagaId());
        });
    }

    @Override
    public Map<String, Object> compensate(SagaTaskRequest request) {
        return transaction(connection -> {
            Map<String, Object> reservation = requireReservation(connection, request.sagaId(), null, true);
            if ("COMPENSATED".equals(reservation.get("reservationStatus"))) {
                reservation.put("duplicate", true); return reservation;
            }
            try (PreparedStatement restore = connection.prepareStatement(
                    "UPDATE saga_inventory_products SET available_stock = available_stock + ?, updated_at = CURRENT_TIMESTAMP WHERE product_id = ?");
                 PreparedStatement update = connection.prepareStatement(
                    "UPDATE saga_stock_reservations SET status = 'COMPENSATED', compensation_reason = ?, updated_at = CURRENT_TIMESTAMP WHERE saga_id = ?")) {
                restore.setInt(1, (Integer) reservation.get("quantity"));
                restore.setString(2, (String) reservation.get("productId")); restore.executeUpdate();
                update.setString(1, request.reason() == null ? "PAYMENT_FAILED" : request.reason());
                update.setString(2, request.sagaId()); update.executeUpdate();
            }
            return reservation(connection, request.sagaId());
        });
    }

    private Map<String, Object> requireReservation(Connection connection, String sagaId, String status, boolean lock)
            throws SQLException {
        Map<String, Object> result = reservation(connection, sagaId, lock);
        if (result == null) throw new IllegalStateException("Stock reservation not found");
        if (status != null && !status.equals(result.get("reservationStatus"))) {
            throw new IllegalStateException("Stock reservation must be " + status);
        }
        return result;
    }

    private Map<String, Object> reservation(Connection connection, String sagaId) throws SQLException {
        return reservation(connection, sagaId, false);
    }

    private Map<String, Object> reservation(Connection connection, String sagaId, boolean lock) throws SQLException {
        String sql = "SELECT reservation_id, order_id, product_id, quantity, status FROM saga_stock_reservations WHERE saga_id = ?" + (lock ? " FOR UPDATE" : "");
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, sagaId);
            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) return null;
                Map<String, Object> result = base(sagaId, rows.getString("order_id"));
                result.put("reservationId", rows.getObject("reservation_id").toString());
                result.put("productId", rows.getString("product_id")); result.put("quantity", rows.getInt("quantity"));
                result.put("reservationStatus", rows.getString("status")); result.put("duplicate", false);
                return result;
            }
        }
    }

    private Map<String, Object> payment(Connection connection, String sagaId) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT payment_id, order_id, status, failure_code FROM saga_payments WHERE saga_id = ?")) {
            statement.setString(1, sagaId);
            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) return null;
                Map<String, Object> result = base(sagaId, rows.getString("order_id"));
                result.put("paymentId", rows.getObject("payment_id").toString());
                result.put("paymentStatus", rows.getString("status"));
                result.put("approved", "COMPLETED".equals(rows.getString("status")));
                if (rows.getString("failure_code") != null) result.put("failureCode", rows.getString("failure_code"));
                result.put("duplicate", false); return result;
            }
        }
    }

    private Map<String, Object> order(Connection connection, String sagaId) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT order_id, status FROM saga_orders WHERE saga_id = ?")) {
            statement.setString(1, sagaId);
            try (ResultSet rows = statement.executeQuery()) {
                if (!rows.next()) return null;
                Map<String, Object> result = base(sagaId, rows.getString("order_id"));
                result.put("orderStatus", rows.getString("status")); result.put("duplicate", false); return result;
            }
        }
    }

    private static Map<String, Object> base(String sagaId, String orderId) {
        Map<String, Object> result = new LinkedHashMap<>(); result.put("sagaId", sagaId); result.put("orderId", orderId); return result;
    }

    private <T> T transaction(SqlWork<T> work) {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try { T result = work.run(connection); connection.commit(); return result; }
            catch (Exception exception) { connection.rollback(); throw exception; }
        } catch (RuntimeException exception) { throw exception; }
        catch (Exception exception) { throw new IllegalStateException("Saga persistence failed", exception); }
    }

    @FunctionalInterface private interface SqlWork<T> { T run(Connection connection) throws Exception; }
}
