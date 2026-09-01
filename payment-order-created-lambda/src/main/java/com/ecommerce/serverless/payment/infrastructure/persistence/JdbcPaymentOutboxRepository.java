package com.ecommerce.serverless.payment.infrastructure.persistence;

import com.ecommerce.serverless.outbox.OutboxMessage;
import com.ecommerce.serverless.outbox.OutboxRepository;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public final class JdbcPaymentOutboxRepository implements OutboxRepository {
    private final DataSource dataSource;

    public JdbcPaymentOutboxRepository(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @Override
    public List<OutboxMessage> claimBatch(int batchSize, Instant now, Duration claimLease) {
        String sql = """
                WITH candidates AS (
                    SELECT id FROM payment_outbox
                    WHERE (status = 'PENDING' AND next_attempt_at <= ?)
                       OR (status = 'PROCESSING' AND claimed_at <= ?)
                    ORDER BY created_at
                    LIMIT ?
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE payment_outbox o
                SET status = 'PROCESSING', claimed_at = ?, attempt_count = attempt_count + 1, updated_at = ?
                FROM candidates c
                WHERE o.id = c.id
                RETURNING o.id, o.event_id, o.event_type, o.aggregate_id, o.payload::text, o.attempt_count
                """;
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try (PreparedStatement statement = connection.prepareStatement(sql)) {
                statement.setTimestamp(1, Timestamp.from(now));
                statement.setTimestamp(2, Timestamp.from(now.minus(claimLease)));
                statement.setInt(3, batchSize);
                statement.setTimestamp(4, Timestamp.from(now));
                statement.setTimestamp(5, Timestamp.from(now));
                List<OutboxMessage> messages = new ArrayList<>();
                try (ResultSet rs = statement.executeQuery()) {
                    while (rs.next()) {
                        messages.add(new OutboxMessage(
                                rs.getObject("id", UUID.class), rs.getString("event_id"),
                                rs.getString("event_type"), rs.getString("aggregate_id"),
                                rs.getString("payload"), rs.getInt("attempt_count")));
                    }
                }
                connection.commit();
                return messages;
            } catch (SQLException | RuntimeException exception) {
                connection.rollback();
                throw exception;
            }
        } catch (SQLException exception) {
            throw new PaymentPersistenceException("Could not claim Payment Outbox batch", exception);
        }
    }

    @Override
    public void markPublished(UUID id, Instant publishedAt) {
        update("""
                UPDATE payment_outbox SET status = 'PUBLISHED', published_at = ?, claimed_at = NULL,
                    last_error = NULL, updated_at = ? WHERE id = ? AND status = 'PROCESSING'
                """, id, publishedAt, publishedAt, null);
    }

    @Override
    public void releaseForRetry(UUID id, Instant nextAttemptAt, String error) {
        update("""
                UPDATE payment_outbox SET status = 'PENDING', next_attempt_at = ?, claimed_at = NULL,
                    last_error = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'PROCESSING'
                """, id, nextAttemptAt, null, error);
    }

    @Override
    public Optional<Instant> oldestOutstandingCreatedAt() {
        String sql = "SELECT MIN(created_at) FROM payment_outbox WHERE status IN ('PENDING', 'PROCESSING')";
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet resultSet = statement.executeQuery()) {
            resultSet.next();
            Timestamp timestamp = resultSet.getTimestamp(1);
            return timestamp == null ? Optional.empty() : Optional.of(timestamp.toInstant());
        } catch (SQLException exception) {
            throw new PaymentPersistenceException("Could not inspect Payment Outbox age", exception);
        }
    }

    private void update(String sql, UUID id, Instant timestamp, Instant secondTimestamp, String error) {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setTimestamp(1, Timestamp.from(timestamp));
            if (secondTimestamp != null) {
                statement.setTimestamp(2, Timestamp.from(secondTimestamp));
            } else {
                statement.setString(2, error);
            }
            statement.setObject(3, id);
            if (statement.executeUpdate() != 1) {
                throw new SQLException("Payment Outbox row was not PROCESSING: " + id);
            }
        } catch (SQLException exception) {
            throw new PaymentPersistenceException("Could not update Payment Outbox row", exception);
        }
    }
}
