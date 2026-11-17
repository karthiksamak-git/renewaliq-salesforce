// One live callout through the real External Credential (Groq), after the API key
// is stored on RIQ LLM Principal and RIQ AI Config.Default.Is_Enabled__c is true.
// Prints AI when the model answered, Rule-based when it fell back to rules.
Id accountId = [SELECT Id FROM Account ORDER BY LastModifiedDate DESC LIMIT 1].Id;
System.debug(RIQ_AccountHealthController.generateInsight(accountId).aiSource);
