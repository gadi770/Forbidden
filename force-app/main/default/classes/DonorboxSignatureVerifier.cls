/**
 * Verifies the HMAC signature Donorbox attaches to webhook deliveries (Donorbox's webhook
 * config only accepts an endpoint URL, not custom headers, so a shared-secret header is not
 * an option here).
 *
 * TODO before go-live: confirm the header name and encoding against
 * https://donorbox.zendesk.com/hc/en-us/articles/17982194843028 (blocked/authenticated
 * while writing this class) or by asking Andy Proag directly. HEADER_NAME below is a
 * best-effort default (Stripe/GitHub-style signing), not a confirmed value.
 */
public with sharing class DonorboxSignatureVerifier {

    @TestVisible
    private static final String HEADER_NAME = 'Donorbox-Signature';

    public static String getHeaderName() {
        return HEADER_NAME;
    }

    public static Boolean isValid(String rawBody, String signatureHeaderValue, String secret) {
        if (String.isBlank(rawBody) || String.isBlank(signatureHeaderValue) || String.isBlank(secret)) {
            return false;
        }

        String provided = signatureHeaderValue.trim().toLowerCase();
        if (provided.startsWith('sha256=')) {
            provided = provided.substringAfter('sha256=');
        }

        String computed = computeHexDigest(rawBody, secret);
        return computed.equalsIgnoreCase(provided);
    }

    private static String computeHexDigest(String rawBody, String secret) {
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(rawBody), Blob.valueOf(secret));
        return EncodingUtil.convertToHex(mac);
    }
}
