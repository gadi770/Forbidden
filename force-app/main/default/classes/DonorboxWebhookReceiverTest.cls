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
    static void rejectsRequestWithoutSecret() {
        RestResponse res = callWebhook('{"id":"123"}', null);
        System.assertEquals(401, res.statusCode);
    }

    @IsTest
    static void rejectsInvalidJson() {
        RestResponse res = callWebhook('not-json', SECRET);
        System.assertEquals(400, res.statusCode);
    }

    @IsTest
    static void rejectsPayloadWithoutDonationId() {
        RestResponse res = callWebhook('{"email":"donor@example.com"}', SECRET);
        System.assertEquals(500, res.statusCode);
    }

    @IsTest
    static void createsDonorAndDonationOpportunity() {
        String body = JSON.serialize(new Map<String, Object>{
            'id' => '1001',
            'type' => 'donation',
            'amount' => '50.00',
            'email' => 'donor@example.com',
            'first_name' => 'Jane',
            'last_name' => 'Doe'
        });

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
        String body = JSON.serialize(new Map<String, Object>{
            'id' => '2002',
            'type' => 'donation',
            'amount' => '25.00',
            'email' => 'repeat@example.com',
            'first_name' => 'Sam',
            'last_name' => 'Smith'
        });

        callWebhook(body, SECRET);
        callWebhook(body, SECRET);

        List<Opportunity> opps = [SELECT Id FROM Opportunity WHERE Donorbox_Donation_Id__c = '2002'];
        System.assertEquals(1, opps.size());
    }

    @IsTest
    static void marksOpportunityAsRefunded() {
        String body = JSON.serialize(new Map<String, Object>{
            'id' => '3003',
            'type' => 'donation.refunded',
            'amount' => '10.00',
            'email' => 'refund@example.com',
            'last_name' => 'Refunded Donor'
        });

        RestResponse res = callWebhook(body, SECRET);
        System.assertEquals(200, res.statusCode);

        Opportunity opp = [
            SELECT StageName, Donorbox_Refunded__c
            FROM Opportunity
            WHERE Donorbox_Donation_Id__c = '3003'
        ];
        System.assertEquals(true, opp.Donorbox_Refunded__c);
        System.assertEquals('Closed Lost', opp.StageName);
    }

    private static RestResponse callWebhook(String body, String secret) {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/donorbox/webhook';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        if (secret != null) {
            req.addHeader('X-Webhook-Secret', secret);
        }

        RestResponse res = new RestResponse();
        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        DonorboxWebhookReceiver.handlePost();
        Test.stopTest();

        return RestContext.response;
    }
}
