package poc;

import com.azure.core.credential.TokenCredential;
import com.azure.identity.AzureCliCredentialBuilder;
import com.azure.identity.ManagedIdentityCredentialBuilder;
import com.azure.storage.common.policy.RequestRetryOptions;
import com.azure.storage.common.policy.RetryPolicyType;
import com.azure.storage.queue.QueueClientBuilder;
import com.azure.storage.queue.QueueMessageEncoding;

/** Entry point (java -jar target/queue-poc.jar, Ctrl+C = graceful stop) and the settings shared by the queue clients. */
public final class App {

    // No keys or connection strings anywhere: shared keys are disabled on the storage account.
    private static final TokenCredential CREDENTIAL = credential();

    // Retry layer 1, transport level: timeouts, 500, 503 (throttling)... handled by the SDK.
    // Exponential, 4 tries of 5 s max (queue calls take milliseconds), delay 0.5 s -> 4 s: one call gives up in < 30 s.
    // That must stay well inside the visibility timeout: a delete or update must not outlive the message's lease.
    // Layer 2 (message level) is in QueueConsumer.
    private static final RequestRetryOptions HTTP_RETRY =
            new RequestRetryOptions(RetryPolicyType.EXPONENTIAL, 4, 5, 500L, 4_000L, null);

    public static void main(String[] args) {
        new QueueConsumer(Config.fromEnv()).run();
    }

    /** One place for the client settings shared by every queue client. Clients are thread-safe: build once, reuse. */
    static QueueClientBuilder queue(Config cfg, String queueName) {
        return new QueueClientBuilder()
                .endpoint(cfg.serviceUrl())
                .queueName(queueName)
                .credential(CREDENTIAL)
                .messageEncoding(QueueMessageEncoding.BASE64) // what Azure Functions expects, and safe for any payload
                .retryOptions(HTTP_RETRY);
    }

    /**
     * In Azure: the user-assigned managed identity whose client ID is in AZURE_CLIENT_ID. Locally: your {@code az login}.
     * Explicit on purpose: DefaultAzureCredential tries a chain of credentials and can silently fall back to another
     * one, which Microsoft advises against in production.
     */
    private static TokenCredential credential() {
        String clientId = System.getenv("AZURE_CLIENT_ID");
        if (clientId != null && !clientId.isBlank()) {
            return new ManagedIdentityCredentialBuilder().clientId(clientId).build();
        }
        return new AzureCliCredentialBuilder().build();
    }
}
