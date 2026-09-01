package com.ecommerce.serverless.order.infrastructure.persistence;

import com.ecommerce.serverless.order.infrastructure.config.DatabaseSettings;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.flywaydb.core.Flyway;

public final class OrderDatabase {
    private OrderDatabase() {
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
        config.setPoolName("order-payment-result-pool");
        config.setConnectionInitSql("SET search_path TO order_domain");
        HikariDataSource dataSource = new HikariDataSource(config);
        try {
            Flyway.configure()
                    .dataSource(dataSource)
                    .locations("classpath:db/order")
                    .schemas("order_domain")
                    .defaultSchema("order_domain")
                    .table("order_flyway_schema_history")
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
