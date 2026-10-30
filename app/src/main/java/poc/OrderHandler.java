package poc;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.concurrent.ThreadLocalRandom;

/**
 * Business logic stub: replace with yours. Rules for the real thing:
 * <ul>
 *   <li>Idempotent: delivery is at-least-once, the same message can come twice.
 *       Deduplicate on a business key (e.g. unique constraint on the order id).</li>
 *   <li>Throw {@link NonRetryableException} when retrying cannot help (bad payload, business rule):
 *       the message goes straight to the poison queue. Any other exception is retried with backoff.</li>
 *   <li>Put a timeout on every I/O call: a stuck message holds a worker and outlives its visibility timeout.</li>
 * </ul>
 * Demo payloads (sent with the Azure CLI, see the README): ok-N, flaky-N (fails half the attempts), down-N (always fails),
 * invalid-N.
 */
final class OrderHandler {

    private static final Logger log = LoggerFactory.getLogger(OrderHandler.class);

    static void process(String order) throws Exception {
        if (order.startsWith("invalid")) {
            throw new NonRetryableException("cannot parse '" + order + "'");
        }
        if (order.startsWith("down")) {
            throw new IllegalStateException("payment service unavailable for '" + order + "' (simulated)");
        }
        if (order.startsWith("flaky") && ThreadLocalRandom.current().nextBoolean()) {
            throw new IllegalStateException("payment service timeout for '" + order + "' (simulated)");
        }
        Thread.sleep(200); // simulated work
        log.info("Processed {}", order);
    }
}
