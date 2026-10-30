package poc;

import com.azure.core.util.Context;
import com.azure.storage.queue.QueueClient;
import com.azure.storage.queue.models.QueueMessageDecodingError;
import com.azure.storage.queue.models.QueueMessageItem;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;

/**
 * Competing consumer on an Azure Storage queue. Delivery is at-least-once:
 *
 * <pre>
 * receive            the message becomes invisible for visibilityTimeout, its dequeueCount is incremented
 * success            delete it
 * transient failure  keep it, make it visible again after an exponential backoff (updateMessage)
 * permanent failure, last attempt or undecodable    copy it to the poison queue, then delete it
 * crash or hang      nothing to do: it reappears after visibilityTimeout, dequeueCount catches crash loops
 * </pre>
 *
 * Scale out by running more instances: the visibility timeout gives each message a single owner at a time.
 */
final class QueueConsumer {

    private static final Logger log = LoggerFactory.getLogger(QueueConsumer.class);

    private static final Duration NEVER_EXPIRE = Duration.ofSeconds(-1); // default TTL is 7 days: poison must not vanish
    private static final int MAX_BATCH = 32;                             // service limit per receive call
    private static final long MIN_IDLE_MS = 1_000;                       // polling backoff while the queue is empty
    private static final long MAX_IDLE_MS = 10_000;

    private final Config cfg;
    private final QueueClient queue;
    private final QueueClient poison;
    private final Semaphore freeWorkers;
    private final CountDownLatch stop = new CountDownLatch(1);

    QueueConsumer(Config cfg) {
        this.cfg = cfg;
        this.freeWorkers = new Semaphore(cfg.concurrency());
        this.poison = App.queue(cfg, cfg.poisonQueueName()).buildClient();
        this.queue = App.queue(cfg, cfg.queueName())
                .processMessageDecodingError(this::onUndecodable) // otherwise one bad message breaks every receive
                .buildClient();
    }

    void run() {
        Thread loop = Thread.currentThread();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> { // Ctrl+C, SIGTERM (container stop, scale-in)
            log.info("Stopping: no new messages, finishing in-flight ones");
            stop.countDown();
            try {
                // Past the visibility timeout they are redelivered anyway. In a container, the platform's stop grace
                // period must be at least this long (Container Apps: terminationGracePeriodSeconds, default 30 s).
                loop.join(cfg.visibilityTimeout().toMillis());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }));
        log.info("Consuming '{}' (poison '{}', concurrency {}, max attempts {}, visibility timeout {}s)",
                cfg.queueName(), cfg.poisonQueueName(), cfg.concurrency(), cfg.maxAttempts(),
                cfg.visibilityTimeout().toSeconds());

        long idleMs = MIN_IDLE_MS;
        try (ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor()) {
            while (true) {
                freeWorkers.acquireUninterruptibly(); // wait for at least one free worker
                if (stopping()) {
                    break;
                }
                int free = 1 + freeWorkers.drainPermits();
                // Receive only what can be processed right now: a message waiting in a local buffer
                // burns its visibility timeout and blocks other instances from taking it.
                List<QueueMessageItem> batch = receive(Math.min(free, MAX_BATCH));
                freeWorkers.release(free - batch.size());

                if (batch.isEmpty()) {
                    pause(idleMs);
                    idleMs = Math.min(idleMs * 2, MAX_IDLE_MS);
                    continue;
                }
                idleMs = MIN_IDLE_MS;
                for (QueueMessageItem msg : batch) {
                    // execute, not submit: nobody reads the Future, which would silently swallow an Error from the handler
                    workers.execute(() -> {
                        try {
                            handle(msg);
                        } finally {
                            freeWorkers.release();
                        }
                    });
                }
            }
        } // close() waits for in-flight messages
        log.info("Stopped");
    }

    private void handle(QueueMessageItem msg) {
        long attempt = msg.getDequeueCount();
        try {
            if (attempt > cfg.maxAttempts()) {
                // Earlier attempts never reported back (crash, OOM, kill -9, hang): don't let it kill us again
                toPoison(msg, "no outcome after " + cfg.maxAttempts() + " attempts", null);
                return;
            }

            Exception failure = null;
            try {
                OrderHandler.process(msg.getBody().toString());
            } catch (InterruptedException e) {
                // Forced stop (ExecutorService.shutdownNow), not a processing failure: leave the message as it is,
                // it comes back after its visibility timeout. Keep the interrupt flag for whoever is stopping us.
                Thread.currentThread().interrupt();
                log.warn("Message {} interrupted, it will be redelivered", msg.getMessageId());
                return;
            } catch (Exception e) {
                failure = e;
            }

            if (failure == null) {
                queue.deleteMessage(msg.getMessageId(), msg.getPopReceipt());
            } else if (failure instanceof NonRetryableException) {
                toPoison(msg, "non-retryable failure", failure);
            } else if (attempt >= cfg.maxAttempts()) {
                toPoison(msg, "attempt " + attempt + "/" + cfg.maxAttempts() + " failed", failure);
            } else {
                // Same message, body untouched: only its visibility moves. No duplicate, dequeueCount keeps counting.
                Duration delay = backoff(attempt);
                queue.updateMessage(msg.getMessageId(), msg.getPopReceipt(), null, delay);
                log.warn("Message {} attempt {}/{} failed, retry in {}s: {}",
                        msg.getMessageId(), attempt, cfg.maxAttempts(), delay.toSeconds(), failure.getMessage());
            }
        } catch (Exception e) {
            // A queue call failed after the SDK retries. Typical cause: processing outlived the visibility timeout,
            // so the pop receipt is stale and the message is visible again. It WILL be processed again:
            // that is why OrderHandler must be idempotent.
            log.error("Message {} not settled, it will be redelivered: {}", msg.getMessageId(), e.toString());
        }
    }

    /**
     * Copy first, then delete: a crash in between duplicates the message in the poison queue, never loses it.
     * The cause (null when there is none) is logged with its stack trace: this is the log line you will investigate.
     */
    private void toPoison(QueueMessageItem msg, String reason, Exception cause) {
        poison.sendMessageWithResponse(msg.getBody(), null, NEVER_EXPIRE, null, Context.NONE);
        queue.deleteMessage(msg.getMessageId(), msg.getPopReceipt());
        log.error("Message {} moved to '{}' (dequeue count {}): {}",
                msg.getMessageId(), cfg.poisonQueueName(), msg.getDequeueCount(), reason, cause);
    }

    /** Called by the SDK for a received message that is not valid Base64, e.g. from a producer that forgot to encode. */
    private void onUndecodable(QueueMessageDecodingError error) {
        QueueMessageItem msg = error.getQueueMessageItem(); // body as received, not decoded
        if (msg != null) {                                  // null when peeking
            toPoison(msg, "not valid Base64", null);
        }
    }

    /** base * 2^(attempt - 1), capped, plus up to 20% jitter so that failed messages don't all come back together. */
    private Duration backoff(long attempt) {
        long base = cfg.retryBaseDelay().toSeconds() << Math.min(attempt - 1, 20);
        long seconds = Math.min(cfg.retryMaxDelay().toSeconds(), base);
        return Duration.ofSeconds(seconds + ThreadLocalRandom.current().nextLong(seconds / 5 + 1));
    }

    private List<QueueMessageItem> receive(int max) {
        try {
            return queue.receiveMessages(max, cfg.visibilityTimeout(), null, Context.NONE).stream().toList();
        } catch (Exception e) { // e.g. network down: the SDK already retried, back off and try again
            log.error("Receive failed: {}", e.toString());
            return List.of();
        }
    }

    private void pause(long millis) {
        try {
            stop.await(millis, TimeUnit.MILLISECONDS); // returns early on shutdown
        } catch (InterruptedException e) {
            stop.countDown();
            Thread.currentThread().interrupt();
        }
    }

    private boolean stopping() {
        return stop.getCount() == 0;
    }
}
