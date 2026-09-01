package com.ecommerce.serverless.notification.infrastructure.persistence;

public final class NotificationPersistenceException extends RuntimeException {
    public NotificationPersistenceException(String message, Throwable cause) {
        super(message, cause);
    }
}
