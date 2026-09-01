package com.ecommerce.serverless.notification.infrastructure.persistence;

import com.ecommerce.serverless.notification.infrastructure.config.DatabaseSettings;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.flywaydb.core.Flyway;

public final class NotificationDatabase {
    private NotificationDatabase() {
    }

    public static HikariDataSource connectAndMigrate(DatabaseSettings settings) {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(settings.jdbcUrl());
        config.setUsername(settings.credentials().username());
        config.setPassword(settings.credentials().password());
        config.setMaximumPoolSize(settings.maximumPoolSize());
        config.setMinimumIdle(0);
        config.setConnectionTimeout(settings.connectionTimeoutMillis());
        config.setIdleTimeout(60_000);
        config.setMaxLifetime(300_000);
        config.setPoolName("notification-pool");
        config.setConnectionInitSql("SET search_path TO notification_domain");
        HikariDataSource dataSource = new HikariDataSource(config);
        try {
            Flyway.configure()
                    .dataSource(dataSource)
                    .locations("classpath:db/notification")
                    .schemas("notification_domain")
                    .defaultSchema("notification_domain")
                    .table("notification_flyway_schema_history")
                    .cleanDisabled(true)
                    .load()
                    .migrate();
            return dataSource;
        } catch (RuntimeException exception) {
            dataSource.close();
            throw exception;
        }
    }
}
