package com.ecommerce.serverless.payment.infrastructure.config;

public interface DatabaseSecretProvider {
    DatabaseCredentials get(String secretArn);
}
