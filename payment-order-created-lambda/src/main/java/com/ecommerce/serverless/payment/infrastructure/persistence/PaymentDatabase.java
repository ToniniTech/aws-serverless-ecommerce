package com.ecommerce.serverless.payment.infrastructure.persistence;

import com.ecommerce.serverless.payment.infrastructure.config.DatabaseSettings;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.flywaydb.core.Flyway;

public final class PaymentDatabase {
    private PaymentDatabase() {
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
        config.setPoolName("payment-lambda-pool");

        HikariDataSource dataSource = new HikariDataSource(config);
        try {
            Flyway.configure()
                    .dataSource(dataSource)
                    .locations("classpath:db/migration")
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
