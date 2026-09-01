# SQS Redrive Flow

Owns one encrypted standard source queue, its dedicated encrypted DLQ, redrive and redrive-allow
policies, and a sender resource policy restricted by service, exact source ARN, and source account.

Lambda event-source mappings and SNS/EventBridge targets remain outside this module because they are
consumer and routing concerns rather than queue lifecycle concerns.
