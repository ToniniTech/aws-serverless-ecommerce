package com.ecommerce.serverless.payment.infrastructure.persistence;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;
import com.ecommerce.serverless.contracts.PaymentResultEvent;
import com.ecommerce.serverless.payment.application.PaymentGateway;
import com.ecommerce.serverless.payment.application.PaymentProcessingRepository;
import com.ecommerce.serverless.payment.domain.PaymentRecord;
import com.ecommerce.serverless.payment.domain.PaymentStatus;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;

public final class JdbcPaymentProcessingRepository implements PaymentProcessingRepository {
    private static final String PAYMENT_COLUMNS = """
            id, payment_id, order_id, source_event_id, correlation_id, gateway_idempotency_key,
            customer_id, customer_email, amount, currency, status,
            gateway_transaction_id, failure_code, failure_reason,
            processing_started_at, processed_at
            """;

    private final DataSource dataSource;
    private final ObjectMapper objectMapper;

    public JdbcPaymentProcessingRepository(DataSource dataSource) {
        this.dataSource = dataSource;
        this.objectMapper = new ObjectMapper().registerModule(new JavaTimeModule());
    }

    @Override
    public Claim claim(
            OrderCreatedEvent event,
            String gatewayIdempotencyKey,
            Instant now,
            Duration processingLease) {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try {
                Optional<PaymentRecord> processed = findByProcessedEvent(connection, event.eventId());
                if (processed.isPresent()) {
                    connection.commit();
                    return new Claim(ClaimDisposition.DUPLICATE, processed.get());
                }

                PaymentRecord candidate = newPayment(event, gatewayIdempotencyKey, now);
                if (insertClaim(connection, candidate)) {
                    connection.commit();
                    return new Claim(ClaimDisposition.CLAIMED, candidate);
                }

                PaymentRecord existing = findConflictingPaymentForUpdate(connection, event)
                        .orElseThrow(() -> new SQLException("A payment uniqueness conflict occurred without a matching row"));

                if (!existing.sourceEventId().equals(event.eventId())) {
                    insertProcessedEvent(connection, event.eventId(), event.orderId(), existing.id(), "DUPLICATE_ORDER", now);
                    connection.commit();
                    return new Claim(ClaimDisposition.DUPLICATE, existing);
                }

                if (existing.status() != PaymentStatus.PROCESSING) {
                    insertProcessedEvent(
                            connection,
                            event.eventId(),
                            existing.orderId(),
                            existing.id(),
                            existing.status().name(),
                            now);
                    connection.commit();
                    return new Claim(ClaimDisposition.DUPLICATE, existing);
                }

                if (existing.processingStartedAt().isAfter(now.minus(processingLease))) {
                    connection.commit();
                    return new Claim(ClaimDisposition.IN_PROGRESS, existing);
                }

                updateProcessingLease(connection, existing.id(), now);
                connection.commit();
                return new Claim(
                        ClaimDisposition.CLAIMED,
                        new PaymentRecord(
                                existing.id(), existing.paymentId(), existing.orderId(), existing.sourceEventId(),
                                existing.correlationId(),
                                existing.gatewayIdempotencyKey(), existing.customerId(), existing.customerEmail(),
                                existing.amount(), existing.currency(), existing.status(), existing.gatewayTransactionId(),
                                existing.failureCode(), existing.failureReason(), now, existing.processedAt()));
            } catch (SQLException | RuntimeException exception) {
                rollback(connection);
                throw exception;
            }
        } catch (SQLException exception) {
            throw new PaymentPersistenceException("Could not claim OrderCreated for payment processing", exception);
        }
    }

    @Override
    public PaymentRecord finalizePayment(
            PaymentRecord payment,
            PaymentGateway.GatewayResult gatewayResult,
            PaymentResultEvent resultEvent,
            Instant processedAt) {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try {
                PaymentRecord current = findByIdForUpdate(connection, payment.id())
                        .orElseThrow(() -> new SQLException("Claimed payment no longer exists: " + payment.id()));

                if (current.status() != PaymentStatus.PROCESSING) {
                    insertProcessedEvent(
                            connection,
                            current.sourceEventId(),
                            current.orderId(),
                            current.id(),
                            current.status().name(),
                            processedAt);
                    connection.commit();
                    return current;
                }

                PaymentStatus status = gatewayResult.approved() ? PaymentStatus.COMPLETED : PaymentStatus.FAILED;
                updateFinalState(connection, current.id(), status, gatewayResult, processedAt);
                insertProcessedEvent(
                        connection,
                        current.sourceEventId(),
                        current.orderId(),
                        current.id(),
                        status.name(),
                        processedAt);

                PaymentRecord finalized = findById(connection, current.id())
                        .orElseThrow(() -> new SQLException("Finalized payment could not be reloaded: " + current.id()));
                insertOutbox(connection, resultEvent, finalized, processedAt);
                connection.commit();
                return finalized;
            } catch (SQLException | RuntimeException exception) {
                rollback(connection);
                throw exception;
            }
        } catch (SQLException exception) {
            throw new PaymentPersistenceException("Could not finalize payment and ProcessedEvent atomically", exception);
        }
    }

    private void insertOutbox(
            Connection connection,
            PaymentResultEvent event,
            PaymentRecord payment,
            Instant createdAt) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement("""
                INSERT INTO payment_outbox
                    (id, event_id, event_type, aggregate_id, payment_record_id, payload,
                     status, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?::jsonb, 'PENDING', ?, ?)
                """)) {
            statement.setObject(1, UUID.randomUUID());
            statement.setString(2, event.eventId());
            statement.setString(3, event.eventType());
            statement.setString(4, payment.orderId());
            statement.setObject(5, payment.id());
            statement.setString(6, objectMapper.writeValueAsString(event));
            statement.setTimestamp(7, Timestamp.from(createdAt));
            statement.setTimestamp(8, Timestamp.from(createdAt));
            statement.executeUpdate();
        } catch (JsonProcessingException exception) {
            throw new PaymentPersistenceException("Could not serialize Payment Outbox event", exception);
        }
    }

    private static PaymentRecord newPayment(
            OrderCreatedEvent event,
            String gatewayIdempotencyKey,
            Instant now) {
        UUID id = UUID.randomUUID();
        return new PaymentRecord(
                id,
                "pay-" + id,
                event.orderId(),
                event.eventId(),
                event.correlationId(),
                gatewayIdempotencyKey,
                event.customerId(),
                event.customerEmail(),
                event.totalAmount(),
                event.currency().toUpperCase(),
                PaymentStatus.PROCESSING,
                null,
                null,
                null,
                now,
                null);
    }

    private static boolean insertClaim(Connection connection, PaymentRecord payment) throws SQLException {
        String sql = """
                INSERT INTO payments (
                    id, payment_id, order_id, source_event_id, correlation_id, gateway_idempotency_key,
                    customer_id, customer_email, amount, currency, status, processing_started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PROCESSING', ?)
                ON CONFLICT DO NOTHING
                """;
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, payment.id());
            statement.setString(2, payment.paymentId());
            statement.setString(3, payment.orderId());
            statement.setString(4, payment.sourceEventId());
            statement.setString(5, payment.correlationId());
            statement.setString(6, payment.gatewayIdempotencyKey());
            statement.setString(7, payment.customerId());
            statement.setString(8, payment.customerEmail());
            statement.setBigDecimal(9, payment.amount());
            statement.setString(10, payment.currency());
            statement.setTimestamp(11, Timestamp.from(payment.processingStartedAt()));
            return statement.executeUpdate() == 1;
        }
    }

    private static Optional<PaymentRecord> findByProcessedEvent(Connection connection, String eventId)
            throws SQLException {
        String sql = "SELECT " + prefixedColumns("p") + " FROM processed_events pe "
                + "JOIN payments p ON p.id = pe.payment_id WHERE pe.event_id = ?";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, eventId);
            return singlePayment(statement);
        }
    }

    private static Optional<PaymentRecord> findConflictingPaymentForUpdate(
            Connection connection,
            OrderCreatedEvent event) throws SQLException {
        String sql = "SELECT " + PAYMENT_COLUMNS + " FROM payments "
                + "WHERE order_id = ? OR source_event_id = ? "
                + "ORDER BY CASE WHEN source_event_id = ? THEN 0 ELSE 1 END LIMIT 1 FOR UPDATE";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, event.orderId());
            statement.setString(2, event.eventId());
            statement.setString(3, event.eventId());
            return singlePayment(statement);
        }
    }

    private static Optional<PaymentRecord> findByIdForUpdate(Connection connection, UUID id) throws SQLException {
        String sql = "SELECT " + PAYMENT_COLUMNS + " FROM payments WHERE id = ? FOR UPDATE";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            return singlePayment(statement);
        }
    }

    private static Optional<PaymentRecord> findById(Connection connection, UUID id) throws SQLException {
        String sql = "SELECT " + PAYMENT_COLUMNS + " FROM payments WHERE id = ?";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, id);
            return singlePayment(statement);
        }
    }

    private static Optional<PaymentRecord> singlePayment(PreparedStatement statement) throws SQLException {
        try (ResultSet resultSet = statement.executeQuery()) {
            return resultSet.next() ? Optional.of(mapPayment(resultSet)) : Optional.empty();
        }
    }

    private static PaymentRecord mapPayment(ResultSet resultSet) throws SQLException {
        Timestamp processedAt = resultSet.getTimestamp("processed_at");
        return new PaymentRecord(
                resultSet.getObject("id", UUID.class),
                resultSet.getString("payment_id"),
                resultSet.getString("order_id"),
                resultSet.getString("source_event_id"),
                resultSet.getString("correlation_id"),
                resultSet.getString("gateway_idempotency_key"),
                resultSet.getString("customer_id"),
                resultSet.getString("customer_email"),
                resultSet.getBigDecimal("amount"),
                resultSet.getString("currency"),
                PaymentStatus.valueOf(resultSet.getString("status")),
                resultSet.getString("gateway_transaction_id"),
                resultSet.getString("failure_code"),
                resultSet.getString("failure_reason"),
                resultSet.getTimestamp("processing_started_at").toInstant(),
                processedAt == null ? null : processedAt.toInstant());
    }

    private static void updateProcessingLease(Connection connection, UUID id, Instant now) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(
                "UPDATE payments SET processing_started_at = ?, updated_at = ? WHERE id = ?")) {
            statement.setTimestamp(1, Timestamp.from(now));
            statement.setTimestamp(2, Timestamp.from(now));
            statement.setObject(3, id);
            statement.executeUpdate();
        }
    }

    private static void updateFinalState(
            Connection connection,
            UUID id,
            PaymentStatus status,
            PaymentGateway.GatewayResult result,
            Instant processedAt) throws SQLException {
        String sql = """
                UPDATE payments
                SET status = ?, gateway_transaction_id = ?, failure_code = ?, failure_reason = ?,
                    processed_at = ?, updated_at = ?
                WHERE id = ? AND status = 'PROCESSING'
                """;
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, status.name());
            statement.setString(2, result.transactionId());
            statement.setString(3, result.failureCode());
            statement.setString(4, result.failureReason());
            statement.setTimestamp(5, Timestamp.from(processedAt));
            statement.setTimestamp(6, Timestamp.from(processedAt));
            statement.setObject(7, id);
            if (statement.executeUpdate() != 1) {
                throw new SQLException("Payment was not in PROCESSING state during finalization: " + id);
            }
        }
    }

    private static void insertProcessedEvent(
            Connection connection,
            String eventId,
            String orderId,
            UUID paymentId,
            String outcome,
            Instant processedAt) throws SQLException {
        String sql = """
                INSERT INTO processed_events (event_id, payment_id, event_type, order_id, outcome, processed_at)
                VALUES (?, ?, 'OrderCreated', ?, ?, ?)
                ON CONFLICT (event_id) DO NOTHING
                """;
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, eventId);
            statement.setObject(2, paymentId);
            statement.setString(3, orderId);
            statement.setString(4, outcome);
            statement.setTimestamp(5, Timestamp.from(processedAt));
            statement.executeUpdate();
        }
    }

    private static String prefixedColumns(String alias) {
        return PAYMENT_COLUMNS.lines()
                .map(String::trim)
                .filter(line -> !line.isBlank())
                .flatMap(line -> java.util.Arrays.stream(line.split(",")))
                .map(String::trim)
                .map(column -> alias + "." + column)
                .reduce((left, right) -> left + ", " + right)
                .orElseThrow();
    }

    private static void rollback(Connection connection) {
        try {
            connection.rollback();
        } catch (SQLException ignored) {
            // The original failure is more useful than a rollback failure.
        }
    }
}
