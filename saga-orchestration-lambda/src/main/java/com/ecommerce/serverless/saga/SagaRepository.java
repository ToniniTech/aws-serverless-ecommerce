package com.ecommerce.serverless.saga;

import java.util.Map;

interface SagaRepository {
    Map<String, Object> reserve(SagaTaskRequest request);
    Map<String, Object> recordPayment(SagaTaskRequest request, String failureCode);
    Map<String, Object> confirm(SagaTaskRequest request);
    Map<String, Object> compensate(SagaTaskRequest request);
}
