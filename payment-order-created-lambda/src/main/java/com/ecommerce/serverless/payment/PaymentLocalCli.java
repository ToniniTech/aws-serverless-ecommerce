package com.ecommerce.serverless.payment;

import com.ecommerce.serverless.contracts.OrderCreatedEvent;
import com.ecommerce.serverless.contracts.OrderCreatedEventParser;
import com.ecommerce.serverless.payment.application.PaymentProcessingResult;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Local-only entry point that reuses the Lambda's application and database wiring without LocalStack.
 */
public final class PaymentLocalCli {
    private PaymentLocalCli() {
    }

    public static void main(String[] args) throws IOException {
        if (args.length != 1) {
            throw new IllegalArgumentException("Usage: PaymentLocalCli <OrderCreated JSON file>");
        }

        OrderCreatedEvent event = new OrderCreatedEventParser().parse(Files.readString(Path.of(args[0])));
        PaymentProcessingResult result = PaymentRuntime.processor().process(event);
        System.out.printf(
                "paymentId=%s orderId=%s status=%s duplicate=%s gatewayIdempotencyKey=%s%n",
                result.paymentId(),
                result.orderId(),
                result.status(),
                result.duplicate(),
                result.gatewayIdempotencyKey());
    }
}
