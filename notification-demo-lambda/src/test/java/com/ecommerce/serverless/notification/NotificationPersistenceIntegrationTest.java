package com.ecommerce.serverless.notification;

import com.ecommerce.serverless.notification.application.NotificationProcessor;
import com.ecommerce.serverless.notification.infrastructure.config.DatabaseCredentials;
import com.ecommerce.serverless.notification.infrastructure.config.DatabaseSettings;
import com.ecommerce.serverless.notification.infrastructure.persistence.JdbcNotificationRepository;
import com.ecommerce.serverless.notification.infrastructure.persistence.NotificationDatabase;
import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

@Testcontainers(disabledWithoutDocker = true)
class NotificationPersistenceIntegrationTest {
    @Container
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("notifications").withUsername("notification_test").withPassword("notification_test");
    private static final Instant NOW = Instant.parse("2026-08-21T12:00:00Z");
    private static HikariDataSource dataSource;
    private JdbcNotificationRepository repository;

    @BeforeAll
    static void connect() {
        dataSource = NotificationDatabase.connectAndMigrate(new DatabaseSettings(
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
    void reset() throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(
                     "TRUNCATE notification_processed_events, notifications")) {
            statement.executeUpdate();
        }
        repository = new JdbcNotificationRepository(dataSource);
    }

    @Test
    void recordsNotificationAndProcessedEventInOneTransaction() throws SQLException {
        NotificationProcessor.ProcessResult result = repository.record(event("evt-normal"), "ORDER_CREATED", NOW);

        assertFalse(result.duplicate());
        assertEquals("CREATED", result.status());
        assertEquals(1L, count("SELECT count(*) FROM notifications WHERE event_id = 'evt-normal'"));
        assertEquals(1L, count("SELECT count(*) FROM notification_processed_events WHERE event_id = 'evt-normal'"));
    }

    @Test
    void duplicateEventReturnsOriginalNotificationWithoutCreatingAnotherRow() throws SQLException {
        NotificationEvent event = event("evt-duplicate");
        NotificationProcessor.ProcessResult first = repository.record(event, "ORDER_CREATED", NOW);

        NotificationProcessor.ProcessResult duplicate = repository.record(
                event, "ORDER_CREATED", NOW.plusSeconds(1));

        assertTrue(duplicate.duplicate());
        assertEquals(first.notificationId(), duplicate.notificationId());
        assertEquals(1L, count("SELECT count(*) FROM notifications"));
        assertEquals(1L, count("SELECT count(*) FROM notification_processed_events"));
    }

    private static NotificationEvent event(String eventId) {
        return new NotificationEvent(
                eventId,
                "OrderCreated",
                "corr-001",
                "order-001",
                null,
                "customer@example.com");
    }

    private static long count(String sql) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet resultSet = statement.executeQuery()) {
            resultSet.next();
            return resultSet.getLong(1);
        }
    }
}
