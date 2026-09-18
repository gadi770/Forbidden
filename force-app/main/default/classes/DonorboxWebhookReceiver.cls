/**
 * Inbound REST endpoint for Donorbox custom webhooks.
 * URL: /services/apexrest/donorbox/webhook
 *
 * IMPORTANT - field mapping is provisional:
 * The exact Donorbox JSON payload (https://donorbox.zendesk.com/hc/en-us/articles/4733681068820-Custom-Webhooks)
 * could not be inspected while writing this class. Payload access is untyped (Map<String, Object>)
 * so this class deploys and runs even if a few key names below turn out to be wrong -
 * only the constants in DonorboxPayloadKeys need to change once the real payload is confirmed.
 *
 * Donor matching model (Contact + Account) is a placeholder: swap findOrCreateDonor()
 * for Person Accounts if that's the model retained for Forbidden Stories.
 */
@RestResource(urlMapping='/donorbox/webhook/*')
global with sharing class DonorboxWebhookReceiver {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        if (!isAuthorized(req)) {
            writeResponse(res, 401, 'unauthorized');
            return;
        }

        String rawBody = req.requestBody != null ? req.requestBody.toString() : null;
        if (String.isBlank(rawBody)) {
            writeResponse(res, 400, 'empty_body');
            return;
        }

        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
        } catch (Exception parseEx) {
            writeResponse(res, 400, 'invalid_json');
            return;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            process(payload, rawBody);
            writeResponse(res, 200, 'ok');
        } catch (Exception e) {
            Database.rollback(sp);
            // 5xx tells Donorbox to retry the delivery; keep server errors distinct from validation errors.
            System.debug(LoggingLevel.ERROR, 'Donorbox webhook processing failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            writeResponse(res, 500, 'processing_failed');
        }
    }

    private static void process(Map<String, Object> payload, String rawBody) {
        String donationId = DonorboxPayloadReader.getDonationId(payload);
        if (String.isBlank(donationId)) {
            throw new DonorboxWebhookException('Payload is missing a donation id, cannot guarantee idempotency.');
        }

        String eventType = DonorboxPayloadReader.getEventType(payload);
        Id donorContactId = findOrCreateDonor(payload);

        Opportunity opp = mapToOpportunity(payload, donationId, eventType, rawBody, donorContactId);
        upsert opp Opportunity.Fields.Donorbox_Donation_Id__c;
    }

    /**
     * Placeholder donor matching: Contact + (business) Account, matched by email.
     * Replace with Person Account logic if that model is confirmed for this org.
     */
    private static Id findOrCreateDonor(Map<String, Object> payload) {
        String email = DonorboxPayloadReader.getDonorEmail(payload);
        if (String.isBlank(email)) {
            return null;
        }

        List<Contact> existing = [
            SELECT Id
            FROM Contact
            WHERE Email = :email
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }

        String firstName = DonorboxPayloadReader.getDonorFirstName(payload);
        String lastName = DonorboxPayloadReader.getDonorLastName(payload);
        if (String.isBlank(lastName)) {
            lastName = String.isBlank(email) ? 'Donorbox Donor' : email;
        }

        Account acc = new Account(Name = trimToLabel(firstName, lastName));
        insert acc;

        Contact c = new Contact(
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            AccountId = acc.Id
        );
        insert c;
        return c.Id;
    }

    private static String trimToLabel(String firstName, String lastName) {
        String label = (String.isBlank(firstName) ? '' : firstName + ' ') + lastName;
        return String.isBlank(label) ? 'Donorbox Donor' : label;
    }

    private static Opportunity mapToOpportunity(
        Map<String, Object> payload,
        String donationId,
        String eventType,
        String rawBody,
        Id donorContactId
    ) {
        Decimal amount = DonorboxPayloadReader.getAmount(payload);
        Boolean refunded = DonorboxPayloadReader.isRefunded(payload, eventType);

        Opportunity opp = new Opportunity();
        opp.Donorbox_Donation_Id__c = donationId;
        opp.Donorbox_Event_Type__c = eventType;
        opp.Donorbox_Raw_Payload__c = rawBody.length() > 32768 ? rawBody.substring(0, 32768) : rawBody;
        opp.Donorbox_Refunded__c = refunded;
        opp.Name = 'Donorbox Donation ' + donationId;
        opp.Amount = amount;
        opp.CloseDate = Date.today();
        opp.StageName = refunded ? 'Closed Lost' : 'Closed Won';
        if (donorContactId != null) {
            opp.ContactId = donorContactId;
        }
        return opp;
    }

    private static Boolean isAuthorized(RestRequest req) {
        Donorbox_Integration__c settings = Donorbox_Integration__c.getOrgDefaults();
        String expectedSecret = settings != null ? settings.Webhook_Secret__c : null;
        String providedSecret = req.headers.get('X-Webhook-Secret');
        return String.isNotBlank(expectedSecret) && expectedSecret.equals(providedSecret);
    }

    private static void writeResponse(RestResponse res, Integer statusCode, String status) {
        res.statusCode = statusCode;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'status' => status }));
    }

    public class DonorboxWebhookException extends Exception {}
}
