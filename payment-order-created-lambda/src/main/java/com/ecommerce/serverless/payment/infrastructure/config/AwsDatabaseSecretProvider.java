package com.ecommerce.serverless.payment.infrastructure.config;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;

public final class AwsDatabaseSecretProvider implements DatabaseSecretProvider {
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    @Override
    public DatabaseCredentials get(String secretArn) {
        try (SecretsManagerClient client = SecretsManagerClient.builder()
                .httpClientBuilder(UrlConnectionHttpClient.builder())
                .build()) {
            String secret = client.getSecretValue(GetSecretValueRequest.builder()
                            .secretId(secretArn)
                            .build())
                    .secretString();
            JsonNode json = OBJECT_MAPPER.readTree(secret);
            return new DatabaseCredentials(requiredText(json, "username"), requiredText(json, "password"));
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("Database secret is not valid JSON", exception);
        }
    }

    private static String requiredText(JsonNode json, String field) {
        JsonNode value = json.get(field);
        if (value == null || value.asText().isBlank()) {
            throw new IllegalStateException("Database secret is missing " + field);
        }
        return value.asText();
    }
}
