package poc;

import java.time.Duration;

/** Settings from environment variables, with defaults tuned for the demo. Invalid values stop the app at startup. */
record Config(
        String serviceUrl,          // https://<account>.queue.core.windows.net
        String queueName,
        String poisonQueueName,
        int concurrency,            // messages processed in parallel by one instance
        Duration visibilityTimeout, // lease on a received message: must cover its processing + one HTTP call's retries (< 30 s)
        int maxAttempts,            // then the message goes to the poison queue
        Duration retryBaseDelay,    // backoff between attempts: base * 2^(attempt - 1)...
        Duration retryMaxDelay) {   // ...capped here

    private static final Duration MAX_VISIBILITY = Duration.ofDays(7); // service limit

    Config {
        check(concurrency >= 1, "CONCURRENCY must be at least 1");
        check(maxAttempts >= 1, "MAX_ATTEMPTS must be at least 1");
        check(visibilityTimeout.toSeconds() >= 1 && visibilityTimeout.compareTo(MAX_VISIBILITY) <= 0,
                "VISIBILITY_TIMEOUT_SECONDS must be between 1 and 604800 (7 days)");
        check(!retryBaseDelay.isNegative() && retryBaseDelay.compareTo(retryMaxDelay) <= 0,
                "RETRY_BASE_DELAY_SECONDS must be between 0 and RETRY_MAX_DELAY_SECONDS");
    }

    static Config fromEnv() {
        String queue = env("QUEUE_NAME", "orders");
        return new Config(
                env("QUEUE_SERVICE_URL", null),
                queue,
                env("POISON_QUEUE_NAME", queue + "-poison"),
                number("CONCURRENCY", 16),
                Duration.ofSeconds(number("VISIBILITY_TIMEOUT_SECONDS", 60)),
                number("MAX_ATTEMPTS", 5),
                Duration.ofSeconds(number("RETRY_BASE_DELAY_SECONDS", 5)),
                Duration.ofSeconds(number("RETRY_MAX_DELAY_SECONDS", 300)));
    }

    private static String env(String name, String defaultValue) {
        String value = System.getenv(name);
        if (value != null && !value.isBlank()) {
            return value;
        }
        if (defaultValue == null) {
            throw new IllegalStateException(name + " is not set. Run: eval \"$(terraform -chdir=../infra output -raw env)\"");
        }
        return defaultValue;
    }

    private static int number(String name, int defaultValue) {
        String value = env(name, String.valueOf(defaultValue));
        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            throw new IllegalStateException(name + " must be an integer, got '" + value + "'");
        }
    }

    private static void check(boolean valid, String message) {
        if (!valid) {
            throw new IllegalStateException(message);
        }
    }
}
