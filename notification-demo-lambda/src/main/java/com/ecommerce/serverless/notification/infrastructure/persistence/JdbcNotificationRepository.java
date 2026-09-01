package com.ecommerce.serverless.notification.infrastructure.persistence;

import com.ecommerce.serverless.notification.NotificationEvent;
import com.ecommerce.serverless.notification.application.NotificationProcessor;
import com.ecommerce.serverless.notification.application.NotificationRepository;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

public final class JdbcNotificationRepository implements NotificationRepository {
    private static final String STATUS_CREATED = "CREATED";
    private final DataSource dataSource;

    public JdbcNotificationRepository(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @Override
    public NotificationProcessor.ProcessResult record(
            NotificationEvent event,
            String templateKey,
            Instant processedAt) {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try {
                Optional<UUID> inserted = insertNotification(connection, event, templateKey, processedAt);
                if (inserted.isEmpty()) {
                    NotificationProcessor.ProcessResult duplicate = findProcessed(connection, event.eventId())
                            .orElseThrow(() -> new SQLException(
                                    "Notification exists without its ProcessedEvent for " + event.eventId()));
                    connection.commit();
                    return duplicate;
                }

                UUID notificationId = inserted.get();
                insertProcessedEvent(connection, event, notificationId, processedAt);
                connection.commit();
                return new NotificationProcessor.ProcessResult(notificationId, STATUS_CREATED, false);
            } catch (Exception exception) {
                connection.rollback();
                throw exception;
            }
        } catch (Exception exception) {
            throw new NotificationPersistenceException(
                    "Could not record notification event " + event.eventId(), exception);
        }
    }

    private static Optional<UUID> insertNotification(
            Connection connection,
            NotificationEvent event,
            String templateKey,
            Instant createdAt) throws SQLException {
        String sql = """
                INSERT INTO notifications
                    (id, event_id, event_type, correlation_id, order_id, payment_id,
                     recipient, template_key, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'CREATED', ?)
                ON CONFLICT (event_id) DO NOTHING
                RETURNING id
                """;
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, UUID.randomUUID());
            statement.setString(2, event.eventId());
            statement.setString(3, event.eventType());
            statement.setString(4, event.correlationId());
            statement.setString(5, event.orderId());
            statement.setString(6, event.paymentId());
            statement.setString(7, event.customerEmail());
            statement.setString(8, templateKey);
            statement.setTimestamp(9, Timestamp.from(createdAt));
            try (ResultSet resultSet = statement.executeQuery()) {
                return resultSet.next() ? Optional.of(resultSet.getObject(1, UUID.class)) : Optional.empty();
            }
        }
    }

    private static void insertProcessedEvent(
            Connection connection,
            NotificationEvent event,
            UUID notificationId,
            Instant processedAt) throws SQLException {
        String sql = """
                INSERT INTO notification_processed_events
                    (event_id, event_type, order_id, notification_id, consumer, processed_at)
                VALUES (?, ?, ?, ?, 'notification', ?)
                """;
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, event.eventId());
            statement.setString(2, event.eventType());
            statement.setString(3, event.orderId());
            statement.setObject(4, notificationId);
            statement.setTimestamp(5, Timestamp.from(processedAt));
            statement.executeUpdate();
        }
    }

    private static Optional<NotificationProcessor.ProcessResult> findProcessed(
            Connection connection,
            String eventId) throws SQLException {
        String sql = """
                SELECT n.id, n.status
                FROM notification_processed_events pe
                JOIN notifications n ON n.id = pe.notification_id
                WHERE pe.event_id = ?
                """;
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, eventId);
            try (ResultSet resultSet = statement.executeQuery()) {
                if (!resultSet.next()) {
                    return Optional.empty();
                }
                return Optional.of(new NotificationProcessor.ProcessResult(
                        resultSet.getObject("id", UUID.class), resultSet.getString("status"), true));
            }
        }
    }
}
