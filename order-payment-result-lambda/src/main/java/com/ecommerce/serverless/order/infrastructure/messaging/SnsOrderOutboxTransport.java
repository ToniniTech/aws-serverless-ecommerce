package com.ecommerce.serverless.order.infrastructure.messaging;

import com.ecommerce.serverless.outbox.OutboxMessage;
import com.ecommerce.serverless.outbox.OutboxTransport;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sns.model.PublishRequest;
import software.amazon.awssdk.services.sns.model.PublishResponse;

public final class SnsOrderOutboxTransport implements OutboxTransport {
    private final SnsClient client;
    private final String topicArn;

    public SnsOrderOutboxTransport(SnsClient client, String topicArn) {
        this.client = client;
        this.topicArn = topicArn;
    }

    @Override
    public void publish(OutboxMessage message) {
        PublishResponse response = client.publish(PublishRequest.builder()
                .topicArn(topicArn)
                .message(message.payload())
                .messageAttributes(java.util.Map.of(
                        "eventType", software.amazon.awssdk.services.sns.model.MessageAttributeValue.builder()
                                .dataType("String").stringValue(message.eventType()).build(),
                        "eventId", software.amazon.awssdk.services.sns.model.MessageAttributeValue.builder()
                                .dataType("String").stringValue(message.eventId()).build()))
                .build());
        if (response.messageId() == null || response.messageId().isBlank()) {
            throw new IllegalStateException("SNS returned no messageId for " + message.eventId());
        }
    }
}
