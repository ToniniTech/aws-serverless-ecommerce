package com.ecommerce.serverless.saga;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;

import java.util.Map;

public final class SagaTaskHandlers {
    private SagaTaskHandlers() {}

    public static final class ReserveStock implements RequestHandler<Map<String, Object>, Map<String, Object>> {
        public Map<String, Object> handleRequest(Map<String, Object> input, Context context) {
            return SagaRuntime.service().reserve(SagaTaskRequest.from(input));
        }
    }
    public static final class ProcessPayment implements RequestHandler<Map<String, Object>, Map<String, Object>> {
        public Map<String, Object> handleRequest(Map<String, Object> input, Context context) {
            return SagaRuntime.service().processPayment(SagaTaskRequest.from(input));
        }
    }
    public static final class ConfirmOrder implements RequestHandler<Map<String, Object>, Map<String, Object>> {
        public Map<String, Object> handleRequest(Map<String, Object> input, Context context) {
            return SagaRuntime.service().confirm(SagaTaskRequest.from(input));
        }
    }
    public static final class CompensateStock implements RequestHandler<Map<String, Object>, Map<String, Object>> {
        public Map<String, Object> handleRequest(Map<String, Object> input, Context context) {
            return SagaRuntime.service().compensate(SagaTaskRequest.from(input));
        }
    }
}
