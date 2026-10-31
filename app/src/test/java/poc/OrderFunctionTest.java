package poc;

import com.microsoft.azure.functions.ExecutionContext;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.List;
import java.util.logging.Handler;
import java.util.logging.LogRecord;
import java.util.logging.Logger;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Calls the function the way the Functions host does, and checks what would then happen to the message:
 * the function returns = completed (deleted), it throws = redelivered, then dead-lettered after the last attempt.
 * Also checks that every log line carries the order, the message ID and the attempt.
 */
class OrderFunctionTest {

    private final OrderFunction function = new OrderFunction();
    private final List<String> logs = new ArrayList<>();
    private final ExecutionContext context = contextLoggingTo(logs);

    @Test
    void validOrderIsProcessed() {
        assertDoesNotThrow(() -> function.run("ok-1", "m-1", 1, context));
        assertEquals(List.of("INFO Processed order ok-1 (message m-1, attempt 1)"), logs);
    }

    @Test
    void invalidOrderFailsEveryAttempt() {
        assertThrows(IllegalArgumentException.class, () -> function.run("invalid-1", "m-2", 1, context));
        assertEquals(List.of("WARNING Failed order invalid-1 (message m-2, attempt 1): cannot parse 'invalid-1'"), logs);
    }

    @Test
    void transientFailureIsLoggedAndRedelivered() {
        assertThrows(IllegalStateException.class, () -> function.run("down-1", "m-3", 2, context));
        assertEquals(List.of("WARNING Failed order down-1 (message m-3, attempt 2): "
                + "payment service unavailable for 'down-1' (simulated)"), logs);
    }

    @Test
    void flakyOrderFailsSometimesAndSucceedsSometimes() {
        boolean failed = false;
        boolean succeeded = false;
        for (int i = 0; i < 50 && !(failed && succeeded); i++) { // missing an outcome in 50 tries: about 1 in 10^15
            try {
                function.run("flaky-1", "m-4", i + 1, context);
                succeeded = true;
            } catch (Exception e) {
                failed = true;
            }
        }
        assertTrue(failed && succeeded);
    }

    /**
     * An ExecutionContext whose logger records "LEVEL message". A dynamic proxy rather than a class: no mocking library,
     * and it still compiles if a library upgrade adds methods to the interface.
     */
    private static ExecutionContext contextLoggingTo(List<String> logs) {
        Logger logger = Logger.getAnonymousLogger();
        logger.setUseParentHandlers(false);
        logger.addHandler(new Handler() {
            @Override
            public void publish(LogRecord record) {
                logs.add(record.getLevel() + " " + record.getMessage());
            }

            @Override
            public void flush() {
            }

            @Override
            public void close() {
            }
        });
        return (ExecutionContext) Proxy.newProxyInstance(ExecutionContext.class.getClassLoader(),
                new Class<?>[] {ExecutionContext.class},
                (proxy, method, args) -> method.getName().equals("getLogger") ? logger : null);
    }
}
