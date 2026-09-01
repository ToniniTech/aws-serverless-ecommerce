package com.ecommerce.serverless.payment;

import com.ecommerce.serverless.payment.application.PaymentApplicationService;
import com.ecommerce.serverless.payment.application.PaymentProcessor;
import com.ecommerce.serverless.outbox.OutboxProcessor;
import com.ecommerce.serverless.payment.infrastructure.config.DatabaseSettings;
import com.ecommerce.serverless.payment.infrastructure.gateway.SimulatedPaymentGateway;
import com.ecommerce.serverless.payment.infrastructure.persistence.JdbcPaymentProcessingRepository;
import com.ecommerce.serverless.payment.infrastructure.persistence.PaymentDatabase;
import com.ecommerce.serverless.payment.infrastructure.messaging.EventBridgePaymentOutboxTransport;
import com.ecommerce.serverless.payment.infrastructure.persistence.JdbcPaymentOutboxRepository;
import com.zaxxer.hikari.HikariDataSource;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.eventbridge.EventBridgeClient;

import java.time.Clock;
import java.time.Duration;

final class PaymentRuntime {
    private static final RuntimeComponents COMPONENTS = create();

    private PaymentRuntime() {
    }

    static PaymentProcessor processor() {
        return COMPONENTS.processor();
    }

    static OutboxProcessor outboxProcessor() {
        return OutboxHolder.PROCESSOR;
    }

    private static RuntimeComponents create() {
        DatabaseSettings settings = DatabaseSettings.fromEnvironment();
        HikariDataSource dataSource = PaymentDatabase.connectAndMigrate(settings);
        Duration processingLease = Duration.ofSeconds(longEnvironment("PAYMENT_PROCESSING_LEASE_SECONDS", 60));
        PaymentProcessor processor = new PaymentApplicationService(
                new JdbcPaymentProcessingRepository(dataSource),
                new SimulatedPaymentGateway(),
                Clock.systemUTC(),
                processingLease);
        return new RuntimeComponents(dataSource, processor);
    }

    private static long longEnvironment(String name, long defaultValue) {
        long value = Long.parseLong(System.getenv().getOrDefault(name, Long.toString(defaultValue)));
        if (value < 30 || value > 900) {
            throw new IllegalStateException(name + " must be between 30 and 900");
        }
        return value;
    }

    private static String requiredEnvironment(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is required");
        }
        return value;
    }

    private static int intEnvironment(String name, int defaultValue, int minimum, int maximum) {
        int value = Integer.parseInt(System.getenv().getOrDefault(name, Integer.toString(defaultValue)));
        if (value < minimum || value > maximum) {
            throw new IllegalStateException(name + " must be between " + minimum + " and " + maximum);
        }
        return value;
    }

    private record RuntimeComponents(HikariDataSource dataSource, PaymentProcessor processor) {
    }

    private static final class OutboxHolder {
        private static final EventBridgeClient CLIENT = EventBridgeClient.builder()
                .httpClientBuilder(UrlConnectionHttpClient.builder())
                .build();
        private static final OutboxProcessor PROCESSOR = new OutboxProcessor(
                new JdbcPaymentOutboxRepository(COMPONENTS.dataSource()),
                new EventBridgePaymentOutboxTransport(CLIENT, requiredEnvironment("PAYMENT_EVENT_BUS_NAME")),
                Clock.systemUTC(),
                intEnvironment("OUTBOX_BATCH_SIZE", 10, 1, 100),
                Duration.ofSeconds(intEnvironment("OUTBOX_CLAIM_LEASE_SECONDS", 120, 30, 900)));

        private OutboxHolder() {
        }
    }
}
