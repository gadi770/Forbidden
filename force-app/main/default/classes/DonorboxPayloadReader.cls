/**
 * All Donorbox-payload-shape assumptions live here, isolated from DonorboxWebhookReceiver.
 * Once the exact JSON sent by Donorbox is confirmed (see the sample Andy Proag shared),
 * only this class should need edits - update the candidate key lists below.
 */
public with sharing class DonorboxPayloadReader {

    // Ordered candidate keys: first match wins. Extend/reorder once the real payload is known.
    private static final List<String> DONATION_ID_KEYS = new List<String>{ 'id', 'donation_id' };
    private static final List<String> EVENT_TYPE_KEYS = new List<String>{ 'type', 'event', 'status' };
    private static final List<String> AMOUNT_KEYS = new List<String>{ 'amount', 'total_amount' };
    private static final List<String> EMAIL_KEYS = new List<String>{ 'email', 'donor_email' };
    private static final List<String> FIRST_NAME_KEYS = new List<String>{ 'first_name', 'donor_first_name' };
    private static final List<String> LAST_NAME_KEYS = new List<String>{ 'last_name', 'donor_last_name' };
    private static final Set<String> REFUND_EVENT_MARKERS = new Set<String>{ 'refunded', 'refund', 'donation.refunded' };

    public static String getDonationId(Map<String, Object> payload) {
        Object raw = firstValue(payload, DONATION_ID_KEYS, null);
        return raw == null ? null : String.valueOf(raw);
    }

    public static String getEventType(Map<String, Object> payload) {
        Object raw = firstValue(payload, EVENT_TYPE_KEYS, null);
        return raw == null ? null : String.valueOf(raw);
    }

    public static Decimal getAmount(Map<String, Object> payload) {
        Object raw = firstValue(payload, AMOUNT_KEYS, null);
        if (raw == null) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(raw));
        } catch (Exception e) {
            return null;
        }
    }

    public static String getDonorEmail(Map<String, Object> payload) {
        return stringValue(firstValue(payload, EMAIL_KEYS, donorMap(payload)));
    }

    public static String getDonorFirstName(Map<String, Object> payload) {
        return stringValue(firstValue(payload, FIRST_NAME_KEYS, donorMap(payload)));
    }

    public static String getDonorLastName(Map<String, Object> payload) {
        return stringValue(firstValue(payload, LAST_NAME_KEYS, donorMap(payload)));
    }

    public static Boolean isRefunded(Map<String, Object> payload, String eventType) {
        if (String.isNotBlank(eventType) && REFUND_EVENT_MARKERS.contains(eventType.toLowerCase())) {
            return true;
        }
        Object statusRaw = payload.get('status');
        return statusRaw != null && REFUND_EVENT_MARKERS.contains(String.valueOf(statusRaw).toLowerCase());
    }

    /**
     * Some Donorbox payloads nest donor details under a "donor" object rather than at the top level.
     * Falls back to that nested map when a top-level key is missing.
     */
    private static Map<String, Object> donorMap(Map<String, Object> payload) {
        Object nested = payload.get('donor');
        return nested instanceof Map<String, Object> ? (Map<String, Object>) nested : null;
    }

    private static Object firstValue(Map<String, Object> payload, List<String> keys, Map<String, Object> fallbackMap) {
        for (String key : keys) {
            if (payload.containsKey(key) && payload.get(key) != null) {
                return payload.get(key);
            }
            if (fallbackMap != null && fallbackMap.containsKey(key) && fallbackMap.get(key) != null) {
                return fallbackMap.get(key);
            }
        }
        return null;
    }

    private static String stringValue(Object raw) {
        return raw == null ? null : String.valueOf(raw);
    }
}
