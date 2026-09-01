package com.ecommerce.serverless.order;

import com.ecommerce.serverless.order.application.OrderPaymentResultService;
import com.ecommerce.serverless.order.application.OrderCommandService;
import com.ecommerce.serverless.order.application.OrderQueryService;
import com.ecommerce.serverless.outbox.OutboxProcessor;
import com.ecommerce.serverless.order.infrastructure.config.DatabaseSettings;
import com.ecommerce.serverless.order.infrastructure.persistence.JdbcOrderPaymentResultRepository;
import com.ecommerce.serverless.order.infrastructure.persistence.JdbcOrderCommandRepository;
import com.ecommerce.serverless.order.infrastructure.persistence.JdbcOrderOutboxRepository;
import com.ecommerce.serverless.order.infrastructure.persistence.JdbcOrderQueryRepository;
import com.ecommerce.serverless.order.infrastructure.persistence.OrderDatabase;
import com.ecommerce.serverless.order.infrastructure.product.HttpProductInventoryAdapter;
import com.ecommerce.serverless.order.infrastructure.product.SimulatedProductInventoryAdapter;
import com.ecommerce.serverless.order.infrastructure.messaging.SnsOrderOutboxTransport;
import com.zaxxer.hikari.HikariDataSource;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.sns.SnsClient;

import java.time.Clock;
import java.time.Duration;
import java.util.Locale;

final class OrderRuntime {
    private static final Components COMPONENTS = create();

    private OrderRuntime() {
    }

    static OrderPaymentResultService service() {
        return COMPONENTS.service();
    }

    static OrderCommandService commandService() {
        return CommandHolder.SERVICE;
    }

    static OrderQueryService queryService() {
        return QueryHolder.SERVICE;
    }

    static OutboxProcessor outboxProcessor() {
        return OutboxHolder.PROCESSOR;
    }

    private static Components create() {
        HikariDataSource dataSource = OrderDatabase.connectAndMigrate(DatabaseSettings.fromEnvironment());
        return new Components(dataSource, new OrderPaymentResultService(
                new JdbcOrderPaymentResultRepository(dataSource), Clock.systemUTC()));
    }

    private record Components(HikariDataSource dataSource, OrderPaymentResultService service) {
    }

    private static String requiredEnvironment(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) throw new IllegalStateException(name + " is required");
        return value;
    }

    private static int intEnvironment(String name, int fallback, int min, int max) {
        int value = Integer.parseInt(System.getenv().getOrDefault(name, Integer.toString(fallback)));
        if (value < min || value > max) throw new IllegalStateException(name + " must be between " + min + " and " + max);
        return value;
    }

    private static final class CommandHolder {
        private static final OrderCommandService SERVICE = new OrderCommandService(
                new JdbcOrderCommandRepository(COMPONENTS.dataSource()),
                productInventoryAdapter(),
                Clock.systemUTC());
    }

    private static com.ecommerce.serverless.order.application.ProductInventoryPort productInventoryAdapter() {
        String mode = System.getenv().getOrDefault("PRODUCT_ADAPTER_MODE", "HTTP")
                .trim().toUpperCase(Locale.ROOT);
        return switch (mode) {
            case "SIMULATED" -> new SimulatedProductInventoryAdapter();
            case "HTTP" -> new HttpProductInventoryAdapter(
                    requiredEnvironment("PRODUCT_SERVICE_BASE_URL"),
                    Duration.ofMillis(intEnvironment("PRODUCT_SERVICE_TIMEOUT_MS", 5000, 500, 15000)));
            default -> throw new IllegalStateException("PRODUCT_ADAPTER_MODE must be SIMULATED or HTTP");
        };
    }

    private static final class QueryHolder {
        private static final OrderQueryService SERVICE = new OrderQueryService(
                new JdbcOrderQueryRepository(COMPONENTS.dataSource()));
    }

    private static final class OutboxHolder {
        private static final SnsClient CLIENT = SnsClient.builder()
                .httpClientBuilder(UrlConnectionHttpClient.builder()).build();
        private static final OutboxProcessor PROCESSOR = new OutboxProcessor(
                new JdbcOrderOutboxRepository(COMPONENTS.dataSource()),
                new SnsOrderOutboxTransport(CLIENT, requiredEnvironment("ORDER_EVENTS_TOPIC_ARN")),
                Clock.systemUTC(), intEnvironment("OUTBOX_BATCH_SIZE", 10, 1, 100),
                Duration.ofSeconds(intEnvironment("OUTBOX_CLAIM_LEASE_SECONDS", 120, 30, 900)));
    }
}
