package poc;

import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.annotation.BindingName;
import com.microsoft.azure.functions.annotation.FunctionName;
import com.microsoft.azure.functions.annotation.ServiceBusQueueTrigger;

import java.util.logging.Logger;

/**
 * Service Bus-triggered Azure Function. The Functions host receives each message in peek-lock mode, renews its lock
 * while the function runs and runs up to 16 messages in parallel per instance (host.json). Service Bus does the rest:
 * <ul>
 *   <li>Return normally: the host completes the message, Service Bus deletes it.</li>
 *   <li>Throw: the host abandons it and Service Bus redelivers it at once. After 5 deliveries (max_delivery_count,
 *       in Terraform) Service Bus moves it to the queue's dead-letter queue, with the reason. A crash counts too.</li>
 * </ul>
 * Java functions can't dead-letter a message themselves (explicit settlement is C#-only), so a message that can never
 * succeed takes the same path, in milliseconds. Delivery is at-least-once: see {@link OrderHandler}.
 * Every log line carries the order, the message ID and the attempt, so one search finds a message's whole story
 * (queries in the README). The queue name and the "ServiceBus" connection (Entra ID, no key) come from app settings.
 */
public class OrderFunction {

    @FunctionName("ProcessOrder")
    public void run(
            @ServiceBusQueueTrigger(name = "order", queueName = "%QUEUE_NAME%", connection = "ServiceBus") String order,
            @BindingName("MessageId") String messageId,
            @BindingName("DeliveryCount") int attempt,
            ExecutionContext context) throws Exception {
        // The body is the order ID in this demo. With a real payload, log its business ID, never the whole message.
        String keys = "order " + order + " (message " + messageId + ", attempt " + attempt + ")";
        Logger log = context.getLogger();
        try {
            OrderHandler.process(order);
            log.info("Processed " + keys);
        } catch (Exception e) {
            log.warning("Failed " + keys + ": " + e.getMessage());
            throw e; // redelivered by Service Bus, dead-lettered after the last attempt
        }
    }
}
