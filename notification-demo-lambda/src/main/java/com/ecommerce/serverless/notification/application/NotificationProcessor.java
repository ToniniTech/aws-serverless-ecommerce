package com.ecommerce.serverless.notification.application;

import com.ecommerce.serverless.notification.NotificationEvent;

import java.util.UUID;

public interface NotificationProcessor {
    ProcessResult process(NotificationEvent event);

    record ProcessResult(UUID notificationId, String status, boolean duplicate) {
    }
}
