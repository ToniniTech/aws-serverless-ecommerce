package com.ecommerce.serverless.notification.infrastructure.config;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;

import java.util.Map;

public record DatabaseSettings(
        String jdbcUrl, DatabaseCredentials credentials, int maximumPoolSize, long connectionTimeoutMillis) {

    public static DatabaseSettings fromEnvironment() {
        Map<String, String> environment = System.getenv();
        String jdbcUrl = environment.get("DB_URL");
        DatabaseCredentials credentials;
        if (jdbcUrl != null && !jdbcUrl.isBlank()) {
            credentials = new DatabaseCredentials(required(environment, "DB_USERNAME"), required(environment, "DB_PASSWORD"));
        } else {
            jdbcUrl = "jdbc:postgresql://" + required(environment, "DB_HOST") + ":"
                    + environment.getOrDefault("DB_PORT", "5432") + "/" + required(environment, "DB_NAME")
                    + "?sslmode=" + environment.getOrDefault("DB_SSL_MODE", "require");
            credentials = readSecret(required(environment, "DB_SECRET_ARN"));
        }
        return new DatabaseSettings(
                jdbcUrl,
                credentials,
                boundedInt(environment, "DB_MAX_POOL_SIZE", 2, 1, 4),
                boundedInt(environment, "DB_CONNECTION_TIMEOUT_MS", 5_000, 1_000, 30_000));
    }

    private static DatabaseCredentials readSecret(String secretArn) {
        try (SecretsManagerClient client = SecretsManagerClient.builder()
                .httpClientBuilder(UrlConnectionHttpClient.builder()).build()) {
            String secret = client.getSecretValue(GetSecretValueRequest.builder().secretId(secretArn).build()).secretString();
            JsonNode json = new ObjectMapper().readTree(secret);
            return new DatabaseCredentials(requiredText(json, "username"), requiredText(json, "password"));
        } catch (Exception exception) {
            throw new IllegalStateException("Could not read the PostgreSQL secret", exception);
        }
    }

    private static String requiredText(JsonNode json, String field) {
        JsonNode value = json.get(field);
        if (value == null || value.asText().isBlank()) {
            throw new IllegalStateException("Database secret is missing " + field);
        }
        return value.asText();
    }

    private static String required(Map<String, String> environment, String name) {
        String value = environment.get(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is required");
        }
        return value;
    }

    private static int boundedInt(Map<String, String> environment, String name, int fallback, int min, int max) {
        int value = Integer.parseInt(environment.getOrDefault(name, Integer.toString(fallback)));
        if (value < min || value > max) {
            throw new IllegalStateException(name + " must be between " + min + " and " + max);
        }
        return value;
    }
}
