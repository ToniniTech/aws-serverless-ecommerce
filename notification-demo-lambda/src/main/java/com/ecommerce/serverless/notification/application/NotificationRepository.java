package com.ecommerce.serverless.notification.application;

import com.ecommerce.serverless.notification.NotificationEvent;

import java.time.Instant;

public interface NotificationRepository {
    NotificationProcessor.ProcessResult record(
            NotificationEvent event,
            String templateKey,
            Instant processedAt);
}
