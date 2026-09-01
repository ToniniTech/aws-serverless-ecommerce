package com.ecommerce.serverless.notification;

public record NotificationEvent(
        String eventId,
        String eventType,
        String correlationId,
        String orderId,
        String paymentId,
        String customerEmail) {
}
