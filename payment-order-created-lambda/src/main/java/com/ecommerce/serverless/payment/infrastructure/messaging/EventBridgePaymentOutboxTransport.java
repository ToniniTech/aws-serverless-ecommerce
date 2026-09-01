package com.ecommerce.serverless.payment.infrastructure.messaging;

import com.ecommerce.serverless.contracts.PaymentResultEventParser;
import com.ecommerce.serverless.outbox.OutboxMessage;
import com.ecommerce.serverless.outbox.OutboxTransport;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;
import software.amazon.awssdk.services.eventbridge.model.PutEventsRequest;
import software.amazon.awssdk.services.eventbridge.model.PutEventsRequestEntry;
import software.amazon.awssdk.services.eventbridge.model.PutEventsResponse;

public final class EventBridgePaymentOutboxTransport implements OutboxTransport {
    private final EventBridgeClient client;
    private final String eventBusName;

    public EventBridgePaymentOutboxTransport(EventBridgeClient client, String eventBusName) {
        this.client = client;
        this.eventBusName = eventBusName;
    }

    @Override
    public void publish(OutboxMessage message) {
        PutEventsResponse response = client.putEvents(PutEventsRequest.builder()
                .entries(PutEventsRequestEntry.builder()
                        .eventBusName(eventBusName)
                        .source(PaymentResultEventParser.EVENT_SOURCE)
                        .detailType(message.eventType())
                        .detail(message.payload())
                        .build())
                .build());
        if (response.failedEntryCount() == null || response.failedEntryCount() != 0) {
            String reason = response.entries().isEmpty() ? "no entry result"
                    : response.entries().get(0).errorCode() + ": " + response.entries().get(0).errorMessage();
            throw new PaymentResultPublishException("EventBridge rejected Outbox event: " + reason);
        }
    }
}
