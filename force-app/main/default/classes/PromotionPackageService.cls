public with sharing class PromotionPackageService {

    public class PackageResult {
        @AuraEnabled public String packageCvId;
        @AuraEnabled public String destructiveCvId;
    }

    @AuraEnabled
    public static PackageResult generatePackageXml(Id promotionId) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :promotionId
        ]) { docIds.add(cdl.ContentDocumentId); }

        if (docIds.isEmpty()) {
            throw new AuraHandledException(
                'No Copado Promotion JSON found on this record. ' +
                'Ensure the promotion has components attached.'
            );
        }

        List<ContentVersion> cvList = [
            SELECT VersionData FROM ContentVersion
            WHERE ContentDocumentId IN :docIds
            AND Title LIKE 'Copado Promotion changes%'
            AND IsLatest = true
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (cvList.isEmpty()) {
            throw new AuraHandledException('No Copado Promotion JSON found on this record.');
        }

        String jsonBody = cvList[0].VersionData.toString();
        List<Object> components;
        try {
            components = (List<Object>) JSON.deserializeUntyped(jsonBody);
        } catch (Exception e) {
            throw new AuraHandledException('Failed to parse Promotion JSON: ' + e.getMessage());
        }

        Map<String, List<String>> packageTypes    = new Map<String, List<String>>();
        Map<String, List<String>> destructiveTypes = new Map<String, List<String>>();

        for (Object obj : components) {
            Map<String, Object> comp   = (Map<String, Object>) obj;
            String mdType  = (String) comp.get('t');
            String apiName = (String) comp.get('n');
            String action  = (String) comp.get('a');
            if (String.isBlank(mdType) || String.isBlank(apiName)) continue;

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
            throw new AuraHandledException('No components found in the Promotion JSON.');
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

        List<SObject> templateSteps = Database.query(
            'SELECT ' + String.join(copyFields, ', ')
            + ' FROM copado__JobStep__c'
            + ' WHERE copado__JobTemplate__c = \'' + templates[0].Id + '\''
            + ' ORDER BY copado__Order__c'
        );

        if (!templateSteps.isEmpty()) {
            List<copado__JobStep__c> jeSteps = new List<copado__JobStep__c>();
            for (SObject ts : templateSteps) {
                copado__JobStep__c step = new copado__JobStep__c(
                    copado__JobExecution__c = je.Id
                );
                for (String fn : copyFields) {
                    Object val = ts.get(fn);
                    if (val != null) step.put(fn, val);
                }
                jeSteps.add(step);
            }
            insert jeSteps;
        }

        update new copado__JobExecution__c(Id = je.Id, copado__Status__c = 'Queued');
        return je.Id;
    }

    @AuraEnabled
    public static Map<String, String> checkZipStatus(Id jobExecutionId, Id promotionId) {
        List<copado__JobExecution__c> jes = [
            SELECT copado__Status__c, copado__ErrorMessage__c
            FROM copado__JobExecution__c
            WHERE Id = :jobExecutionId
            LIMIT 1
        ];

        Map<String, String> result = new Map<String, String>();
        if (jes.isEmpty()) {
            result.put('status', 'Failed');
            result.put('error', 'Job Execution not found.');
            return result;
        }

        String status = jes[0].copado__Status__c;

        if (new Set<String>{ 'Not Started', 'In Progress', 'Queued' }.contains(status)) {
            result.put('status', 'In Progress');
            return result;
        }

        if ('Error'.equals(status) || 'Failed'.equals(status) || 'Cancelled'.equals(status)) {
            result.put('status', 'Failed');
            result.put('error', String.isNotBlank(jes[0].copado__ErrorMessage__c)
                ? jes[0].copado__ErrorMessage__c
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
