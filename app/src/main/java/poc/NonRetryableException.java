package poc;

/** Retrying cannot help (bad payload, business rule violation): the message goes straight to the poison queue. */
final class NonRetryableException extends RuntimeException {

    NonRetryableException(String message) {
        super(message);
    }
}
