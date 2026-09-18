/**
 * Reads fields out of a Donorbox webhook v2 payload (untyped JSON map).
 * Schema confirmed from https://donorbox.zendesk.com/hc/en-us/articles/4733681068820
 * (donation.created / donation.updated / donation.chargeback_* / donor.created / donor.updated).
 *
 * Assumes the org's Donorbox webhook endpoint is configured for payload version v2
 * (a single JSON object, not the v1 array format).
 */
public with sharing class DonorboxPayloadReader {

    public static String getEventName(Map<String, Object> payload) {
        return stringValue(payload, 'event_name');
    }

    public static Map<String, Object> getDonationMap(Map<String, Object> payload) {
        return asMap(payload.get('donation'));
    }

    /**
     * donor.* events carry the donor fields at the top-level "donor" key.
     * donation.* events carry a nested donor object under donation.donor.
     */
    public static Map<String, Object> getDonorMap(Map<String, Object> payload) {
        Map<String, Object> topLevelDonor = asMap(payload.get('donor'));
        if (topLevelDonor != null) {
            return topLevelDonor;
        }
        Map<String, Object> donation = getDonationMap(payload);
        return donation != null ? asMap(donation.get('donor')) : null;
    }

    public static String getDonationId(Map<String, Object> donation) {
        return stringValue(donation, 'id');
    }

    public static Decimal getAmount(Map<String, Object> donation) {
        return decimalValue(donation, 'amount');
    }

    public static Decimal getAmountRefunded(Map<String, Object> donation) {
        Decimal value = decimalValue(donation, 'amount_refunded');
        return value == null ? 0 : value;
    }

    public static Boolean isRecurring(Map<String, Object> donation) {
        Object raw = donation == null ? null : donation.get('recurring');
        return raw instanceof Boolean ? (Boolean) raw : false;
    }

    public static String getPlanId(Map<String, Object> donation) {
        return stringValue(donation, 'plan_id');
    }

    public static String getDonorEmail(Map<String, Object> donor) {
        return stringValue(donor, 'email');
    }

    public static String getDonorFirstName(Map<String, Object> donor) {
        return stringValue(donor, 'first_name');
    }

    public static String getDonorLastName(Map<String, Object> donor) {
        return stringValue(donor, 'last_name');
    }

    private static Map<String, Object> asMap(Object raw) {
        return raw instanceof Map<String, Object> ? (Map<String, Object>) raw : null;
    }

    private static String stringValue(Map<String, Object> source, String key) {
        if (source == null || source.get(key) == null) {
            return null;
        }
        return String.valueOf(source.get(key));
    }

    private static Decimal decimalValue(Map<String, Object> source, String key) {
        String raw = stringValue(source, key);
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            return Decimal.valueOf(raw);
        } catch (Exception e) {
            return null;
        }
    }
}
