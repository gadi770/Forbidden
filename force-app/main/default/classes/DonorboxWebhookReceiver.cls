/**
 * Inbound REST endpoint for Donorbox custom webhooks (v2 payload).
 * URL: /services/apexrest/donorbox/webhook
 *
 * Handles: donation.created, donation.updated, donation.chargeback_created/_won/_lost,
 * donor.created, donor.updated. campaign.*, plan.*, purchase.* and ticket.* events are
 * received but not mapped to Salesforce yet - confirm with Forbidden Stories whether
 * event ticket sales need to flow in before wiring those.
 *
 * Donor matching model (Contact + Account) is a placeholder: swap findOrCreateDonor()
 * for Person Accounts if that's the model retained for Forbidden Stories.
 */
@RestResource(urlMapping='/donorbox/webhook/*')
global with sharing class DonorboxWebhookReceiver {

    private static final Set<String> DONATION_EVENTS = new Set<String>{
        'donation.created',
        'donation.updated',
        'donation.chargeback_created',
        'donation.chargeback_won',
        'donation.chargeback_lost'
    };
    private static final Set<String> CHARGEBACK_EVENTS = new Set<String>{
        'donation.chargeback_created',
        'donation.chargeback_won',
        'donation.chargeback_lost'
    };
    private static final Set<String> DONOR_ONLY_EVENTS = new Set<String>{ 'donor.created', 'donor.updated' };

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        String rawBody = req.requestBody != null ? req.requestBody.toString() : null;
        if (String.isBlank(rawBody)) {
            writeResponse(res, 400, 'empty_body');
            return;
        }

        if (!isAuthorized(req, rawBody)) {
            writeResponse(res, 401, 'unauthorized');
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
        String eventName = DonorboxPayloadReader.getEventName(payload);
        if (String.isBlank(eventName)) {
            throw new DonorboxWebhookException('Payload is missing event_name.');
        }

        if (DONATION_EVENTS.contains(eventName)) {
            processDonationEvent(payload, eventName, rawBody);
        } else if (DONOR_ONLY_EVENTS.contains(eventName)) {
            findOrCreateDonor(DonorboxPayloadReader.getDonorMap(payload));
        } else {
            System.debug(LoggingLevel.INFO, 'Unhandled Donorbox event_name: ' + eventName);
        }
    }

    private static void processDonationEvent(Map<String, Object> payload, String eventName, String rawBody) {
        Map<String, Object> donation = DonorboxPayloadReader.getDonationMap(payload);
        if (donation == null) {
            throw new DonorboxWebhookException('Payload is missing the donation object.');
        }

        String donationId = DonorboxPayloadReader.getDonationId(donation);
        if (String.isBlank(donationId)) {
            throw new DonorboxWebhookException('Donation payload is missing an id, cannot guarantee idempotency.');
        }

        Id donorContactId = findOrCreateDonor(DonorboxPayloadReader.getDonorMap(payload));

        Opportunity opp = mapToOpportunity(donation, donationId, eventName, rawBody, donorContactId);
        upsert opp Opportunity.Fields.Donorbox_Donation_Id__c;
    }

    /**
     * Placeholder donor matching: Contact + (business) Account, matched by email.
     * Replace with Person Account logic if that model is confirmed for this org.
     */
    private static Id findOrCreateDonor(Map<String, Object> donorMap) {
        String email = DonorboxPayloadReader.getDonorEmail(donorMap);
        if (String.isBlank(email)) {
            return null;
        }

        List<Contact> existing = [SELECT Id FROM Contact WHERE Email = :email LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }

        String firstName = DonorboxPayloadReader.getDonorFirstName(donorMap);
        String lastName = DonorboxPayloadReader.getDonorLastName(donorMap);
        if (String.isBlank(lastName)) {
            lastName = email;
        }

        Account acc = new Account(Name = trimToLabel(firstName, lastName));
        insert acc;

        Contact c = new Contact(FirstName = firstName, LastName = lastName, Email = email, AccountId = acc.Id);
        insert c;
        return c.Id;
    }

    private static String trimToLabel(String firstName, String lastName) {
        String label = (String.isBlank(firstName) ? '' : firstName + ' ') + lastName;
        return String.isBlank(label) ? 'Donorbox Donor' : label;
    }

    private static Opportunity mapToOpportunity(
        Map<String, Object> donation,
        String donationId,
        String eventName,
        String rawBody,
        Id donorContactId
    ) {
        Boolean refunded = DonorboxPayloadReader.getAmountRefunded(donation) > 0;
        Boolean chargebackLost = eventName == 'donation.chargeback_lost';

        Opportunity opp = new Opportunity();
        opp.Donorbox_Donation_Id__c = donationId;
        opp.Donorbox_Event_Type__c = eventName;
        opp.Donorbox_Raw_Payload__c = rawBody.length() > 32768 ? rawBody.substring(0, 32768) : rawBody;
        opp.Donorbox_Refunded__c = refunded;
        opp.Donorbox_Recurring__c = DonorboxPayloadReader.isRecurring(donation);
        opp.Donorbox_Plan_Id__c = DonorboxPayloadReader.getPlanId(donation);
        opp.Donorbox_Chargeback_Status__c = CHARGEBACK_EVENTS.contains(eventName)
            ? eventName.substringAfter('chargeback_')
            : null;
        opp.Name = 'Donorbox Donation ' + donationId;
        opp.Amount = DonorboxPayloadReader.getAmount(donation);
        opp.CloseDate = Date.today();
        opp.StageName = (refunded || chargebackLost) ? 'Closed Lost' : 'Closed Won';
        if (donorContactId != null) {
            opp.ContactId = donorContactId;
        }
        return opp;
    }

    private static Boolean isAuthorized(RestRequest req, String rawBody) {
        Donorbox_Integration__c settings = Donorbox_Integration__c.getOrgDefaults();
        String secret = settings != null ? settings.Webhook_Secret__c : null;
        String signature = req.headers.get(DonorboxSignatureVerifier.getHeaderName());
        return DonorboxSignatureVerifier.isValid(rawBody, signature, secret);
    }

    private static void writeResponse(RestResponse res, Integer statusCode, String status) {
        res.statusCode = statusCode;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'status' => status }));
    }

    public class DonorboxWebhookException extends Exception {}
}
