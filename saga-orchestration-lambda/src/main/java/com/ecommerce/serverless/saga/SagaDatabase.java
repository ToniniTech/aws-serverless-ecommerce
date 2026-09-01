package com.ecommerce.serverless.saga;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.flywaydb.core.Flyway;

final class SagaDatabase {
    private SagaDatabase() {}

    static HikariDataSource connectAndMigrate(String url, String username, String password) {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(url); config.setUsername(username); config.setPassword(password);
        config.setMaximumPoolSize(Integer.parseInt(System.getenv().getOrDefault("DB_MAX_POOL_SIZE", "2")));
        config.setConnectionTimeout(Long.parseLong(System.getenv().getOrDefault("DB_CONNECTION_TIMEOUT_MS", "5000")));
        config.setPoolName("saga-demo-pool");
        config.setConnectionInitSql("SET search_path TO saga_demo");
        HikariDataSource source = new HikariDataSource(config);
        Flyway.configure().dataSource(source).schemas("saga_demo").defaultSchema("saga_demo")
                .table("saga_flyway_schema_history").locations("classpath:db/saga").load().migrate();
        return source;
    }
}
