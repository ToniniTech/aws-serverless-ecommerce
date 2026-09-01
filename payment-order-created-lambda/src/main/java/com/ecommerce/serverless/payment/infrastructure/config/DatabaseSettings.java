package com.ecommerce.serverless.payment.infrastructure.config;

import java.util.Map;

public record DatabaseSettings(
        String jdbcUrl,
        DatabaseCredentials credentials,
        int maximumPoolSize,
        long connectionTimeoutMillis
) {
    public static DatabaseSettings fromEnvironment() {
        return fromEnvironment(System.getenv(), new AwsDatabaseSecretProvider());
    }

    static DatabaseSettings fromEnvironment(
            Map<String, String> environment,
            DatabaseSecretProvider secretProvider) {
        String jdbcUrl = environment.get("DB_URL");
        DatabaseCredentials credentials;

        if (jdbcUrl != null && !jdbcUrl.isBlank()) {
            credentials = new DatabaseCredentials(
                    required(environment, "DB_USERNAME"),
                    required(environment, "DB_PASSWORD"));
        } else {
            String host = required(environment, "DB_HOST");
            String port = environment.getOrDefault("DB_PORT", "5432");
            String database = required(environment, "DB_NAME");
            String sslMode = environment.getOrDefault("DB_SSL_MODE", "require");
            jdbcUrl = "jdbc:postgresql://" + host + ":" + port + "/" + database + "?sslmode=" + sslMode;
            credentials = secretProvider.get(required(environment, "DB_SECRET_ARN"));
        }

        int poolSize = integer(environment, "DB_MAX_POOL_SIZE", 2, 1, 4);
        long timeout = integer(environment, "DB_CONNECTION_TIMEOUT_MS", 5_000, 1_000, 30_000);
        return new DatabaseSettings(jdbcUrl, credentials, poolSize, timeout);
    }

    private static String required(Map<String, String> environment, String name) {
        String value = environment.get(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is required");
        }
        return value;
    }

    private static int integer(
            Map<String, String> environment,
            String name,
            int defaultValue,
            int minimum,
            int maximum) {
        int value = Integer.parseInt(environment.getOrDefault(name, Integer.toString(defaultValue)));
        if (value < minimum || value > maximum) {
            throw new IllegalStateException(name + " must be between " + minimum + " and " + maximum);
        }
        return value;
    }
}
