package com.ecommerce.serverless.payment.infrastructure.config;

public record DatabaseCredentials(String username, String password) {
    public DatabaseCredentials {
        if (username == null || username.isBlank() || password == null || password.isBlank()) {
            throw new IllegalArgumentException("Database username and password are required");
        }
    }
}
