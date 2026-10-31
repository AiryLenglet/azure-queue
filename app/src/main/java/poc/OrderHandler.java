package poc;

import java.util.concurrent.ThreadLocalRandom;

/**
 * Business logic stub: replace with yours. Rules for the real thing:
 * <ul>
 *   <li>Idempotent: delivery is at-least-once, the same message can come twice.
 *       Deduplicate on a business key (e.g. unique constraint on the order id).</li>
 *   <li>Throw when processing fails: the message is retried, then dead-lettered.</li>
 *   <li>Put a timeout on every I/O call: a stuck call holds the message until the function times out.</li>
 * </ul>
 * Demo payloads (sent with curl, see the README): ok-N, flaky-N (fails half the attempts), down-N (always fails),
 * invalid-N (can never succeed).
 */
final class OrderHandler {

    static void process(String order) throws Exception {
        if (order.startsWith("invalid")) {
            throw new IllegalArgumentException("cannot parse '" + order + "'");
        }
        if (order.startsWith("down")) {
            throw new IllegalStateException("payment service unavailable for '" + order + "' (simulated)");
        }
        if (order.startsWith("flaky") && ThreadLocalRandom.current().nextBoolean()) {
            throw new IllegalStateException("payment service timeout for '" + order + "' (simulated)");
        }
        Thread.sleep(200); // simulated work
    }
}
