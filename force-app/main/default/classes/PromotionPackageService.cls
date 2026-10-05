public with sharing class PromotionPackageService {

    public class PackageResult {
        @AuraEnabled public String packageCvId;
        @AuraEnabled public String destructiveCvId;
    }

    public class IgnoredComponent {
        @AuraEnabled public String story;
        @AuraEnabled public String metadataType;
        @AuraEnabled public String name;
    }

    // Components that are listed in the promotion's "Ignored changes" file AND still present in its
    // "Copado Promotion changes" file. Copado adds a removed component to Ignored changes but does not
    // remove it from Copado Promotion changes, so these would wrongly end up in package.xml.
    @AuraEnabled
    public static List<IgnoredComponent> getIgnoredComponents(Id promotionId) {
        List<IgnoredComponent> found = new List<IgnoredComponent>();

        Set<Id> docIds = linkedDocumentIds(promotionId);
        if (docIds.isEmpty()) return found;

        List<Object> ignored = readJsonFile(docIds, 'Ignored changes%', 'Ignored changes');
        if (ignored == null || ignored.isEmpty()) return found;

        List<Object> components = readJsonFile(docIds, 'Copado Promotion changes%', 'Promotion');
        if (components == null) return found;

        Set<String> keys = buildIgnoredKeys(ignored);
        Set<String> seen = new Set<String>();
        for (Object obj : components) {
            Map<String, Object> comp = (Map<String, Object>) obj;
            String mdType = text(comp.get('t'));
            String apiName = text(comp.get('n'));
            if (String.isBlank(mdType) || String.isBlank(apiName)) continue;
            if (!isIgnored(comp, keys)) continue;
            String story = text(comp.get('u'));
            if (!seen.add(story + '|' + mdType + '|' + apiName)) continue;

            IgnoredComponent ic = new IgnoredComponent();
            ic.story = story;
            ic.metadataType = mdType;
            ic.name = apiName;
            found.add(ic);
        }
        return found;
    }

    @AuraEnabled
    public static PackageResult generatePackageXml(Id promotionId, Boolean excludeIgnored) {
        Set<Id> docIds = linkedDocumentIds(promotionId);

        if (docIds.isEmpty()) {
            throw new AuraHandledException(
                'No Copado Promotion JSON found on this record. ' +
                'Ensure the promotion has components attached.'
            );
        }

        List<Object> components = readJsonFile(docIds, 'Copado Promotion changes%', 'Promotion');
        if (components == null) {
            throw new AuraHandledException('No Copado Promotion JSON found on this record.');
        }

        Set<String> ignoredKeys = new Set<String>();
        if (excludeIgnored == true) {
            List<Object> ignored = readJsonFile(docIds, 'Ignored changes%', 'Ignored changes');
            if (ignored != null) ignoredKeys = buildIgnoredKeys(ignored);
        }

        Map<String, List<String>> packageTypes    = new Map<String, List<String>>();
        Map<String, List<String>> destructiveTypes = new Map<String, List<String>>();

        for (Object obj : components) {
            Map<String, Object> comp   = (Map<String, Object>) obj;
            String mdType  = (String) comp.get('t');
            String apiName = (String) comp.get('n');
            String action  = (String) comp.get('a');
            if (String.isBlank(mdType) || String.isBlank(apiName)) continue;
            if (isIgnored(comp, ignoredKeys)) continue;

            if ('Delete'.equalsIgnoreCase(action)) {
                if (!destructiveTypes.containsKey(mdType)) destructiveTypes.put(mdType, new List<String>());
                destructiveTypes.get(mdType).add(apiName);
            } else {
                // Add, RetrieveOnly, Full — all go in package.xml with specific API name
                if (!packageTypes.containsKey(mdType)) packageTypes.put(mdType, new List<String>());
                packageTypes.get(mdType).add(apiName);
            }
        }

        if (packageTypes.isEmpty() && destructiveTypes.isEmpty()) {
            throw new AuraHandledException(
                excludeIgnored == true
                    ? 'No components left in the Promotion JSON after excluding the ignored changes.'
                    : 'No components found in the Promotion JSON.'
            );
        }

        PackageResult result = new PackageResult();

        if (!packageTypes.isEmpty()) {
            ContentVersion cv = new ContentVersion(
                Title          = 'package.xml',
                PathOnClient   = 'package.xml',
                VersionData    = Blob.valueOf(buildXml(packageTypes)),
                IsMajorVersion = false
            );
            insert cv;
            result.packageCvId = (String) [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;
        }

        if (!destructiveTypes.isEmpty()) {
            ContentVersion cv = new ContentVersion(
                Title          = 'destructiveChanges.xml',
                PathOnClient   = 'destructiveChanges.xml',
                VersionData    = Blob.valueOf(buildXml(destructiveTypes)),
                IsMajorVersion = false
            );
            insert cv;
            result.destructiveCvId = (String) [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;
        }

        return result;
    }

    private static Set<Id> linkedDocumentIds(Id promotionId) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :promotionId
        ]) { docIds.add(cdl.ContentDocumentId); }
        return docIds;
    }

    // Latest version of the newest file whose title matches; null when there is no such file.
    private static List<Object> readJsonFile(Set<Id> docIds, String titlePattern, String label) {
        List<ContentVersion> cvList = [
            SELECT VersionData FROM ContentVersion
            WHERE ContentDocumentId IN :docIds
            AND Title LIKE :titlePattern
            AND IsLatest = true
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (cvList.isEmpty()) return null;
        try {
            return (List<Object>) JSON.deserializeUntyped(cvList[0].VersionData.toString());
        } catch (Exception e) {
            throw new AuraHandledException('Failed to parse ' + label + ' JSON: ' + e.getMessage());
        }
    }

    private static String text(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    // Keys: S|story|type|name (ignored entry names a story), N|type|name (ignored entry has no story),
    // T|type|name (any ignored entry - used for promotion entries that carry no story).
    private static Set<String> buildIgnoredKeys(List<Object> ignored) {
        Set<String> keys = new Set<String>();
        for (Object obj : ignored) {
            Map<String, Object> comp = (Map<String, Object>) obj;
            String story = text(comp.get('u'));
            String mdType = text(comp.get('t'));
            String apiName = text(comp.get('n'));
            if (String.isBlank(mdType) || String.isBlank(apiName)) continue;
            keys.add('T|' + mdType + '|' + apiName);
            if (String.isBlank(story)) {
                keys.add('N|' + mdType + '|' + apiName);
            } else {
                keys.add('S|' + story + '|' + mdType + '|' + apiName);
            }
        }
        return keys;
    }

    private static Boolean isIgnored(Map<String, Object> comp, Set<String> keys) {
        if (keys.isEmpty()) return false;
        String story = text(comp.get('u'));
        String mdType = text(comp.get('t'));
        String apiName = text(comp.get('n'));
        if (keys.contains('N|' + mdType + '|' + apiName)) return true;
        if (String.isBlank(story)) return keys.contains('T|' + mdType + '|' + apiName);
        return keys.contains('S|' + story + '|' + mdType + '|' + apiName);
    }

    private static String buildXml(Map<String, List<String>> typeToMembers) {
        List<String> sortedTypes = new List<String>(typeToMembers.keySet());
        sortedTypes.sort();

        String xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
                   + '<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n';

        for (String mdType : sortedTypes) {
            List<String> members = typeToMembers.get(mdType);
            members.sort();
            xml += '    <types>\n';
            for (String member : members) {
                xml += '        <members>' + escapeXml(member) + '</members>\n';
            }
            xml += '        <name>' + mdType + '</name>\n';
            xml += '    </types>\n';
        }

        xml += '    <version>67.0</version>\n</Package>';
        return xml;
    }

    // ── Deployment Zip ───────────────────────────────────────────────────────

    @AuraEnabled
    public static String startZipGeneration(Id promotionId) {
        List<copado__JobTemplate__c> templates = [
            SELECT Id FROM copado__JobTemplate__c
            WHERE Name = 'Generate Deployment Zip'
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            throw new AuraHandledException('Copado Job Template "Generate Deployment Zip" not found.');
        }

        copado__JobExecution__c je = new copado__JobExecution__c(
            copado__Template__c = templates[0].Id,
            copado__Status__c   = 'Not Started',
            copado__DataJSON__c = JSON.serialize(new Map<String, Object>{ 'PROMOTION_ID' => (String) promotionId })
        );
        insert je;

        List<String> copyFields = copyableStepFields();

        List<SObject> templateSteps = Database.query(
            'SELECT ' + String.join(copyFields, ', ')
            + ' FROM copado__JobStep__c'
            + ' WHERE copado__JobTemplate__c = \'' + templates[0].Id + '\''
            + ' ORDER BY copado__Order__c'
        );

        if (!templateSteps.isEmpty()) {
            insert cloneSteps(templateSteps, je.Id, copyFields);
        }

        update new copado__JobExecution__c(Id = je.Id, copado__Status__c = 'Queued');
        return je.Id;
    }

    // Writable, non-calculated copado__JobStep__c fields that are copied from the template step.
    @TestVisible
    private static List<String> copyableStepFields() {
        Map<String, Schema.SObjectField> stepSchema = copado__JobStep__c.getSObjectType()
            .getDescribe().fields.getMap();

        Set<String> skipFields = new Set<String>{
            'id', 'isdeleted', 'systemmodstamp', 'createddate', 'createdbyid',
            'lastmodifieddate', 'lastmodifiedbyid', 'ownerid',
            'copado__jobexecution__c',
            'copado__jobtemplate__c'
        };

        List<String> copyFields = new List<String>();
        for (String fn : stepSchema.keySet()) {
            if (skipFields.contains(fn.toLowerCase())) continue;
            Schema.DescribeFieldResult dfr = stepSchema.get(fn).getDescribe();
            if (dfr.isCalculated() || !dfr.isCreateable()) continue;
            copyFields.add(fn);
        }
        return copyFields;
    }

    @TestVisible
    private static List<copado__JobStep__c> cloneSteps(
        List<SObject> templateSteps, Id jobExecutionId, List<String> copyFields
    ) {
        List<copado__JobStep__c> jeSteps = new List<copado__JobStep__c>();
        for (SObject ts : templateSteps) {
            copado__JobStep__c step = new copado__JobStep__c(
                copado__JobExecution__c = jobExecutionId
            );
            for (String fn : copyFields) {
                Object val = ts.get(fn);
                if (val != null) step.put(fn, val);
            }
            jeSteps.add(step);
        }
        return jeSteps;
    }

    @AuraEnabled
    public static Map<String, String> checkZipStatus(Id jobExecutionId, Id promotionId) {
        List<copado__JobExecution__c> jes = [
            SELECT copado__Status__c, copado__ErrorMessage__c
            FROM copado__JobExecution__c
            WHERE Id = :jobExecutionId
            LIMIT 1
        ];

        if (jes.isEmpty()) {
            Map<String, String> notFound = new Map<String, String>();
            notFound.put('status', 'Failed');
            notFound.put('error', 'Job Execution not found.');
            return notFound;
        }

        return zipStatusResult(jes[0].copado__Status__c, jes[0].copado__ErrorMessage__c, promotionId);
    }

    // Maps a Job Execution status to the result the LWC polls for.
    @TestVisible
    private static Map<String, String> zipStatusResult(String status, String errorMessage, Id promotionId) {
        Map<String, String> result = new Map<String, String>();

        if (new Set<String>{ 'Not Started', 'In Progress', 'Queued' }.contains(status)) {
            result.put('status', 'In Progress');
            return result;
        }

        if ('Error'.equals(status) || 'Failed'.equals(status) || 'Cancelled'.equals(status)) {
            result.put('status', 'Failed');
            result.put('error', String.isNotBlank(errorMessage)
                ? errorMessage
                : 'Job failed. Check the Job Executions tab on the Promotion for details.');
            return result;
        }

        if ('Successful'.equals(status) || 'Success'.equals(status)) {
            Set<Id> docIds = new Set<Id>();
            for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :promotionId
            ]) docIds.add(cdl.ContentDocumentId);

            if (!docIds.isEmpty()) {
                List<ContentVersion> zips = [
                    SELECT Id FROM ContentVersion
                    WHERE ContentDocumentId IN :docIds
                    AND Title = 'deployment.zip'
                    AND PathOnClient = 'deployment.zip'
                    AND IsLatest = true
                    ORDER BY CreatedDate DESC LIMIT 1
                ];
                if (!zips.isEmpty()) {
                    result.put('status', 'Successful');
                    result.put('cvId', zips[0].Id);
                    return result;
                }
            }
            result.put('status', 'Failed');
            result.put('error', 'Job completed but deployment.zip not found on the Promotion record.');
            return result;
        }

        result.put('status', 'In Progress');
        return result;
    }

    private static String escapeXml(String s) {
        if (s == null) return '';
        return s.replace('&', '&amp;')
                .replace('<', '&lt;')
                .replace('>', '&gt;')
                .replace('"', '&quot;')
                .replace('\'', '&apos;');
    }
}
