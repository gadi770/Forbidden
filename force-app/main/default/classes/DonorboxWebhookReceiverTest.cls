@IsTest
private class DonorboxWebhookReceiverTest {

    private static final String SECRET = 'test-secret';

    @TestSetup
    static void setup() {
        Donorbox_Integration__c settings = Donorbox_Integration__c.getOrgDefaults();
        settings.Webhook_Secret__c = SECRET;
        upsert settings;
    }

    @IsTest
    static void rejectsRequestWithoutSignature() {
        RestResponse res = callWebhook(donationPayload('4001', 'donation.created', '50.0', '0.0'), null);
        System.assertEquals(401, res.statusCode);
    }

    @IsTest
    static void rejectsInvalidSignature() {
        RestResponse res = callWebhookRaw(donationPayload('4002', 'donation.created', '50.0', '0.0'), 'deadbeef');
        System.assertEquals(401, res.statusCode);
    }

    @IsTest
    static void rejectsInvalidJson() {
        RestResponse res = callWebhook('not-json', SECRET);
        System.assertEquals(400, res.statusCode);
    }

    @IsTest
    static void createsDonorAndDonationOpportunity() {
        String body = donationPayload('1001', 'donation.created', '50.00', '0.0');

        RestResponse res = callWebhook(body, SECRET);
        System.assertEquals(200, res.statusCode);

        Opportunity opp = [
            SELECT Id, Amount, StageName, Donorbox_Donation_Id__c, Donorbox_Refunded__c, ContactId
            FROM Opportunity
            WHERE Donorbox_Donation_Id__c = '1001'
        ];
        System.assertEquals(50.00, opp.Amount);
        System.assertEquals('Closed Won', opp.StageName);
        System.assertEquals(false, opp.Donorbox_Refunded__c);
        System.assertNotEquals(null, opp.ContactId);

        Contact c = [SELECT Email FROM Contact WHERE Id = :opp.ContactId];
        System.assertEquals('donor@example.com', c.Email);
    }

    @IsTest
    static void sameDonationIdIsIdempotent() {
        String body = donationPayload('2002', 'donation.created', '25.00', '0.0');

        callWebhook(body, SECRET);
        callWebhook(body, SECRET);

        List<Opportunity> opps = [SELECT Id FROM Opportunity WHERE Donorbox_Donation_Id__c = '2002'];
        System.assertEquals(1, opps.size());
    }

    @IsTest
    static void donationUpdatedWithRefundMarksOpportunityLost() {
        callWebhook(donationPayload('3003', 'donation.created', '10.00', '0.0'), SECRET);

        RestResponse res = callWebhook(donationPayload('3003', 'donation.updated', '10.00', '10.0'), SECRET);
        System.assertEquals(200, res.statusCode);

        Opportunity opp = [
            SELECT StageName, Donorbox_Refunded__c
            FROM Opportunity
            WHERE Donorbox_Donation_Id__c = '3003'
        ];
        System.assertEquals(true, opp.Donorbox_Refunded__c);
        System.assertEquals('Closed Lost', opp.StageName);
    }

    @IsTest
    static void chargebackLostMarksOpportunityLost() {
        callWebhook(donationPayload('5005', 'donation.created', '75.00', '0.0'), SECRET);

        RestResponse res = callWebhook(donationPayload('5005', 'donation.chargeback_lost', '75.00', '0.0'), SECRET);
        System.assertEquals(200, res.statusCode);

        Opportunity opp = [
            SELECT StageName, Donorbox_Chargeback_Status__c
            FROM Opportunity
            WHERE Donorbox_Donation_Id__c = '5005'
        ];
        System.assertEquals('lost', opp.Donorbox_Chargeback_Status__c);
        System.assertEquals('Closed Lost', opp.StageName);
    }

    @IsTest
    static void donorCreatedUpsertsContactWithoutOpportunity() {
        String body = JSON.serialize(new Map<String, Object>{
            'event_id' => '7159',
            'event_name' => 'donor.created',
            'donor' => new Map<String, Object>{
                'id' => '35',
                'first_name' => 'Alex',
                'last_name' => 'Martin',
                'email' => 'alex.martin@example.com'
            }
        });

        RestResponse res = callWebhook(body, SECRET);
        System.assertEquals(200, res.statusCode);

        List<Contact> contacts = [SELECT Id FROM Contact WHERE Email = 'alex.martin@example.com'];
        System.assertEquals(1, contacts.size());
    }

    private static String donationPayload(String donationId, String eventName, String amount, String amountRefunded) {
        return JSON.serialize(new Map<String, Object>{
            'event_id' => '9999',
            'event_name' => eventName,
            'donation' => new Map<String, Object>{
                'id' => donationId,
                'amount' => amount,
                'amount_refunded' => amountRefunded,
                'status' => 'paid',
                'recurring' => false,
                'donor' => new Map<String, Object>{
                    'id' => '59',
                    'first_name' => 'Donor',
                    'last_name' => 'Example',
                    'email' => 'donor@example.com'
                }
            }
        });
    }

    private static RestResponse callWebhook(String body, String secret) {
        String signature = String.isBlank(secret)
            ? null
            : EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', Blob.valueOf(body), Blob.valueOf(secret)));
        return callWebhookRaw(body, signature);
    }

    private static RestResponse callWebhookRaw(String body, String signatureHeaderValue) {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/donorbox/webhook';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        if (signatureHeaderValue != null) {
            req.addHeader(DonorboxSignatureVerifier.getHeaderName(), signatureHeaderValue);
        }

        RestResponse res = new RestResponse();
        RestContext.request = req;
        RestContext.response = res;

        DonorboxWebhookReceiver.handlePost();

        return RestContext.response;
    }
}
