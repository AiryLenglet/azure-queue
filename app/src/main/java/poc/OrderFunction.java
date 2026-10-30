package poc;

import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.OutputBinding;
import com.microsoft.azure.functions.annotation.BindingName;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.QueueOutput;
import com.microsoft.azure.functions.annotation.QueueTrigger;

import java.util.logging.Logger;

/**
 * Queue-triggered Azure Function. The Functions host does what a hand-written consumer would: it polls the queue,
 * runs up to 16 messages in parallel per instance, keeps each message invisible while it runs, retries a failed
 * message 30 s later and moves it to the poison queue after 5 attempts, including attempts that crashed the process
 * (settings in host.json). Delivery is at-least-once: see {@link OrderHandler}.
 * <ul>
 *   <li>Return normally: the message is deleted.</li>
 *   <li>Throw: the message is retried.</li>
 *   <li>{@link NonRetryableException}: retrying cannot help, so it goes straight to the poison queue.</li>
 * </ul>
 * Every log line carries the order, the message ID and the attempt, so one search finds a message's whole story
 * (queries in the README). Queue names and the "QueueStorage" connection (Entra ID, no key) come from app settings.
 */
public class OrderFunction {

    @FunctionName("ProcessOrder")
    public void run(
            @QueueTrigger(name = "order", queueName = "%QUEUE_NAME%", connection = "QueueStorage") String order,
            @BindingName("Id") String messageId,
            @BindingName("DequeueCount") long attempt,
            @QueueOutput(name = "poison", queueName = "%POISON_QUEUE_NAME%", connection = "QueueStorage") OutputBinding<String> poison,
            ExecutionContext context) throws Exception {
        // The payload is the order ID in this demo. With a real payload, log its business ID, never the whole message.
        String keys = "order " + order + " (message " + messageId + ", attempt " + attempt + ")";
        Logger log = context.getLogger();
        try {
            OrderHandler.process(order);
            log.info("Processed " + keys);
        } catch (NonRetryableException e) {
            poison.setValue(order); // written when the function returns, then the original message is deleted
            log.warning("Moved " + keys + " to the poison queue: " + e.getMessage());
        } catch (Exception e) {
            log.warning("Failed " + keys + ": " + e.getMessage());
            throw e; // the host retries it, and after the last attempt moves it to the poison queue
        }
    }
}
