package com.ecommerce.serverless.notification;

import com.ecommerce.serverless.notification.application.NotificationApplicationService;
import com.ecommerce.serverless.notification.application.NotificationProcessor;
import com.ecommerce.serverless.notification.infrastructure.config.DatabaseSettings;
import com.ecommerce.serverless.notification.infrastructure.persistence.JdbcNotificationRepository;
import com.ecommerce.serverless.notification.infrastructure.persistence.NotificationDatabase;
import com.zaxxer.hikari.HikariDataSource;

import java.time.Clock;

final class NotificationRuntime {
    private static final Components COMPONENTS = create();

    private NotificationRuntime() {
    }

    static NotificationProcessor processor() {
        return COMPONENTS.processor();
    }

    private static Components create() {
        HikariDataSource dataSource = NotificationDatabase.connectAndMigrate(DatabaseSettings.fromEnvironment());
        NotificationProcessor processor = new NotificationApplicationService(
                new JdbcNotificationRepository(dataSource), Clock.systemUTC());
        return new Components(dataSource, processor);
    }

    private record Components(HikariDataSource dataSource, NotificationProcessor processor) {
    }
}
