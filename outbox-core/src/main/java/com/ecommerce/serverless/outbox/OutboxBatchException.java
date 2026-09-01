package com.ecommerce.serverless.outbox;

public final class OutboxBatchException extends RuntimeException {
    private final OutboxBatchResult result;

    public OutboxBatchException(OutboxBatchResult result) {
        super("Outbox batch completed with " + result.failed() + " publication failure(s)");
        this.result = result;
    }

    public OutboxBatchResult result() {
        return result;
    }
}
