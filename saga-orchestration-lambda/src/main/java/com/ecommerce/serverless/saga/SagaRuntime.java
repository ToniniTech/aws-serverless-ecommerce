package com.ecommerce.serverless.saga;

final class SagaRuntime {
    private static final SagaApplicationService SERVICE = create();
    private SagaRuntime() {}
    static SagaApplicationService service() { return SERVICE; }

    private static SagaApplicationService create() {
        String url = required("DB_URL");
        var source = SagaDatabase.connectAndMigrate(url, required("DB_USERNAME"), required("DB_PASSWORD"));
        return new SagaApplicationService(new JdbcSagaRepository(source));
    }

    private static String required(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) throw new IllegalStateException(name + " is required");
        return value;
    }
}
