@IsTest
private class PromotionPackageServiceTest {

    // Promotion changes: KeepMe (US-1), OnlyIgnored (US-1), SharedName (US-1 and US-2)
    private static final String PROMOTION_JSON =
        '[{"u":"US-1","t":"ApexClass","n":"KeepMe","a":"Add"},' +
        '{"u":"US-1","t":"ApexClass","n":"OnlyIgnored","a":"Add"},' +
        '{"u":"US-1","t":"ApexClass","n":"SharedName","a":"Add"},' +
        '{"u":"US-2","t":"ApexClass","n":"SharedName","a":"Add"}]';

    // Ignored changes: OnlyIgnored (US-1) and SharedName (US-1) - US-2's SharedName is NOT ignored
    private static final String IGNORED_JSON =
        '[{"u":"US-1","t":"ApexClass","n":"OnlyIgnored","a":"Add"},' +
        '{"u":"US-1","t":"ApexClass","n":"SharedName","a":"Add"}]';

    private static Id holderRecord() {
        Account holder = new Account(Name = 'Promotion holder');
        insert holder;
        return holder.Id;
    }

    private static void attachFile(Id parentId, String title, String body) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.json',
            VersionData = Blob.valueOf(body)
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(ContentDocumentId = docId, LinkedEntityId = parentId, ShareType = 'V');
    }

    private static String generatedPackageXml() {
        return [
            SELECT VersionData FROM ContentVersion
            WHERE Title = 'package.xml' ORDER BY CreatedDate DESC LIMIT 1
        ].VersionData.toString();
    }

    private static Integer occurrences(String haystack, String needle) {
        return haystack.split(needle, -1).size() - 1;
    }

    @IsTest
    static void noIgnoredFile_returnsNothing() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', PROMOTION_JSON);

        System.assertEquals(0, PromotionPackageService.getIgnoredComponents(promotionId).size());
    }

    @IsTest
    static void ignoredFile_returnsOnlyComponentsStillInPromotionJson() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', PROMOTION_JSON);
        attachFile(promotionId, 'Ignored changes', IGNORED_JSON);

        List<PromotionPackageService.IgnoredComponent> found = PromotionPackageService.getIgnoredComponents(promotionId);

        System.assertEquals(2, found.size());
        Set<String> names = new Set<String>();
        for (PromotionPackageService.IgnoredComponent c : found) {
            System.assertEquals('US-1', c.story);
            System.assertEquals('ApexClass', c.metadataType);
            names.add(c.name);
        }
        System.assert(names.contains('OnlyIgnored'));
        System.assert(names.contains('SharedName'));
    }

    @IsTest
    static void ignoredComponentNotInPromotionJson_isNotReported() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', '[{"u":"US-1","t":"ApexClass","n":"KeepMe","a":"Add"}]');
        attachFile(promotionId, 'Ignored changes', '[{"u":"US-1","t":"ApexClass","n":"NotInPromotion","a":"Add"}]');

        System.assertEquals(0, PromotionPackageService.getIgnoredComponents(promotionId).size());
    }

    @IsTest
    static void excludeIgnored_dropsOnlyTheIgnoredStoryEntries() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', PROMOTION_JSON);
        attachFile(promotionId, 'Ignored changes', IGNORED_JSON);

        PromotionPackageService.generatePackageXml(promotionId, true);
        String xml = generatedPackageXml();

        System.assert(xml.contains('<members>KeepMe</members>'));
        System.assert(!xml.contains('OnlyIgnored'), 'a component only ignored must be left out');
        System.assertEquals(1, occurrences(xml, '<members>SharedName</members>'),
            'SharedName from US-2 is not ignored and must stay (once)');
    }

    @IsTest
    static void includeIgnored_keepsEverything() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', PROMOTION_JSON);
        attachFile(promotionId, 'Ignored changes', IGNORED_JSON);

        PromotionPackageService.generatePackageXml(promotionId, false);
        String xml = generatedPackageXml();

        System.assert(xml.contains('<members>KeepMe</members>'));
        System.assert(xml.contains('<members>OnlyIgnored</members>'));
        System.assertEquals(2, occurrences(xml, '<members>SharedName</members>'));
    }

    @IsTest
    static void ignoredEntryWithoutStory_excludesThatComponentForEveryStory() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', PROMOTION_JSON);
        attachFile(promotionId, 'Ignored changes', '[{"t":"ApexClass","n":"SharedName","a":"Add"}]');

        PromotionPackageService.generatePackageXml(promotionId, true);
        String xml = generatedPackageXml();

        System.assert(!xml.contains('SharedName'));
        System.assert(xml.contains('<members>OnlyIgnored</members>'));
    }

    @IsTest
    static void everythingIgnored_throws() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', '[{"u":"US-1","t":"ApexClass","n":"OnlyIgnored","a":"Add"}]');
        attachFile(promotionId, 'Ignored changes', '[{"u":"US-1","t":"ApexClass","n":"OnlyIgnored","a":"Add"}]');

        Boolean thrown = false;
        try {
            PromotionPackageService.generatePackageXml(promotionId, true);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.assert(thrown, 'expected an error when nothing is left to package');
    }

    @IsTest
    static void invalidIgnoredJson_throws() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', PROMOTION_JSON);
        attachFile(promotionId, 'Ignored changes', 'not json');

        Boolean thrown = false;
        try {
            PromotionPackageService.getIgnoredComponents(promotionId);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.assert(thrown, 'a corrupt Ignored changes file must not be silently skipped');
    }

    @IsTest
    static void noFilesOnRecord_throws() {
        Id promotionId = holderRecord();

        Boolean thrown = false;
        try {
            PromotionPackageService.generatePackageXml(promotionId, false);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.assert(thrown);
    }

    // ── Deployment zip: status mapping ───────────────────────────────────────

    @IsTest
    static void zipStatus_runningStatusesReportInProgress() {
        Id promotionId = holderRecord();
        for (String status : new List<String>{ 'Not Started', 'In Progress', 'Queued', 'Something else' }) {
            System.assertEquals('In Progress', PromotionPackageService.zipStatusResult(status, null, promotionId).get('status'), status);
        }
    }

    @IsTest
    static void zipStatus_failureStatusesReportFailedWithMessage() {
        Id promotionId = holderRecord();
        for (String status : new List<String>{ 'Error', 'Failed', 'Cancelled' }) {
            Map<String, String> result = PromotionPackageService.zipStatusResult(status, 'boom', promotionId);
            System.assertEquals('Failed', result.get('status'));
            System.assertEquals('boom', result.get('error'));
        }
    }

    @IsTest
    static void zipStatus_failureWithoutMessageUsesDefaultText() {
        Map<String, String> result = PromotionPackageService.zipStatusResult('Error', null, holderRecord());

        System.assertEquals('Failed', result.get('status'));
        System.assert(result.get('error').startsWith('Job failed.'));
    }

    @IsTest
    static void zipStatus_successWithZipReturnsItsVersionId() {
        Id promotionId = holderRecord();

        // attachFile() names files "<title>.json"; the real zip is stored with PathOnClient deployment.zip
        ContentVersion real = new ContentVersion(
            Title = 'deployment.zip', PathOnClient = 'deployment.zip', VersionData = Blob.valueOf('x')
        );
        insert real;
        Id realDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :real.Id].ContentDocumentId;
        insert new ContentDocumentLink(ContentDocumentId = realDocId, LinkedEntityId = promotionId, ShareType = 'V');

        Map<String, String> result = PromotionPackageService.zipStatusResult('Successful', null, promotionId);

        System.assertEquals('Successful', result.get('status'));
        System.assertEquals(String.valueOf(real.Id), result.get('cvId'));
    }

    @IsTest
    static void zipStatus_successWithoutAnyFilesReportsFailed() {
        Map<String, String> result = PromotionPackageService.zipStatusResult('Success', null, holderRecord());

        System.assertEquals('Failed', result.get('status'));
        System.assert(result.get('error').contains('deployment.zip not found'));
    }

    @IsTest
    static void zipStatus_successButNoZipAmongFilesReportsFailed() {
        Id promotionId = holderRecord();
        attachFile(promotionId, 'Copado Promotion changes', PROMOTION_JSON);

        Map<String, String> result = PromotionPackageService.zipStatusResult('Successful', null, promotionId);

        System.assertEquals('Failed', result.get('status'));
    }

    @IsTest
    static void checkZipStatus_unknownJobExecutionReportsNotFound() {
        Id fakeJobExecutionId = Id.valueOf(copado__JobExecution__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Map<String, String> result = PromotionPackageService.checkZipStatus(fakeJobExecutionId, holderRecord());

        System.assertEquals('Failed', result.get('status'));
        System.assertEquals('Job Execution not found.', result.get('error'));
    }

    // ── Deployment zip: starting the job ─────────────────────────────────────

    @IsTest
    static void startZipGeneration_withoutTemplateThrows() {
        Boolean thrown = false;
        try {
            PromotionPackageService.startZipGeneration(holderRecord());
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.assert(thrown, 'the "Generate Deployment Zip" template is not available in a test context');
    }

    @IsTest
    static void copyableStepFields_excludesSystemAndParentFields() {
        List<String> fields = PromotionPackageService.copyableStepFields();
        Set<String> lower = new Set<String>();
        for (String f : fields) lower.add(f.toLowerCase());

        System.assert(!fields.isEmpty());
        System.assert(!lower.contains('id'));
        System.assert(!lower.contains('createddate'));
        System.assert(!lower.contains('copado__jobexecution__c'));
        System.assert(!lower.contains('copado__jobtemplate__c'));
    }

    @IsTest
    static void cloneSteps_copiesValuesOntoNewJobExecution() {
        Id fakeJobExecutionId = Id.valueOf(copado__JobExecution__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
        copado__JobStep__c templateStep = new copado__JobStep__c(copado__Order__c = 3);

        List<copado__JobStep__c> clones = PromotionPackageService.cloneSteps(
            new List<SObject>{ templateStep }, fakeJobExecutionId, new List<String>{ 'copado__Order__c' }
        );

        System.assertEquals(1, clones.size());
        System.assertEquals(fakeJobExecutionId, clones[0].copado__JobExecution__c);
        System.assertEquals(3, Integer.valueOf(clones[0].copado__Order__c));
    }
}
