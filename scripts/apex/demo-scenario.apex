/*******************************************************************************************
 * RenewalIQ - live demo scenario.
 *
 * Picks three accounts from the Indian demo book and pushes them in opposite directions
 * so a live demo shows real status changes:
 *
 *   - a healthy account with a distant renewal,
 *   - an account inside the 90 day renewal window that drops into At Risk,
 *   - an account days from renewal that drops into Critical,
 *
 * then re-scores them through the same entry point the Queueable and the nightly batch
 * use (RIQ_HealthScoreRecalculator.process), so the Command Center, the record page card
 * and the playbook tasks all agree on one number.
 *
 * Usage:
 *   sf apex run --file scripts/apex/demo-scenario.apex --target-org <alias>
 *
 * Re-runnable: accounts are matched by name and updated in place, and each run adds one
 * more round of signals (which is realistic - signals accumulate). Everything created
 * here carries the "RenewalIQ demo data" description, so reset-demo-data.apex removes it.
 *******************************************************************************************/

List<String> demoNames = new List<String>{
    'RupeeRoute Payments',
    'CargoChetak Logistics',
    'ArogyaGrid Health'
};

// ARR in rupees and how many days from today the contract ends.
List<Decimal> demoArr = new List<Decimal>{ 4800000, 12500000, 9200000 };
List<Integer> daysToRenewal = new List<Integer>{ 64, 22, 5 };

// Signals per account, written as "Type|Severity|DaysAgo".
Map<Integer, List<String>> signalsByAccount = new Map<Integer, List<String>>{
    0 => new List<String>{ 'NPS Detractor|2|120', 'Positive Expansion|2|40', 'Missed QBR|1|25' },
    1 => new List<String>{
        'Support Escalation|4|18',
        'Low Product Usage|4|30',
        'Missed QBR|3|52',
        'NPS Detractor|3|9'
    },
    2 => new List<String>{
        'Executive Sponsor Left|5|6',
        'Support Escalation|5|11',
        'Late Payment|4|33',
        'Low Product Usage|5|20',
        'NPS Detractor|5|4'
    }
};

// ---------------------------------------------------------------------------------------
// 1. Create or update the three accounts.
// ---------------------------------------------------------------------------------------
Map<String, Account> existingByName = new Map<String, Account>();
for (Account existing : [SELECT Id, Name FROM Account WHERE Name IN :demoNames]) {
    existingByName.put(existing.Name, existing);
}

List<Account> accounts = new List<Account>();
List<Account> toInsert = new List<Account>();

for (Integer i = 0; i < demoNames.size(); i++) {
    Account account = existingByName.get(demoNames[i]);

    if (account == null) {
        account = new Account(
            Name = demoNames[i],
            BillingCountry = 'India',
            Description = 'RenewalIQ demo data - created by the demo scenario script.'
        );
        toInsert.add(account);
    }

    account.RIQ_ARR__c = demoArr[i];
    account.RIQ_Contract_End_Date__c = Date.today().addDays(daysToRenewal[i]);
    accounts.add(account);
}

if (!toInsert.isEmpty()) {
    insert toInsert;
}

update accounts;

// ---------------------------------------------------------------------------------------
// 2. Log the signals. The trigger queues a recalculation, which is exactly what the
//    signal logger component does when a CSM submits the form.
// ---------------------------------------------------------------------------------------
List<RIQ_Health_Signal__c> signals = new List<RIQ_Health_Signal__c>();

for (Integer i = 0; i < accounts.size(); i++) {
    for (String raw : signalsByAccount.get(i)) {
        List<String> parts = raw.split('\\|');

        signals.add(
            new RIQ_Health_Signal__c(
                Account__c = accounts[i].Id,
                Signal_Type__c = parts[0],
                Severity__c = Integer.valueOf(parts[1]),
                Occurred_On__c = Date.today().addDays(-Integer.valueOf(parts[2])),
                Notes__c = 'Signal logged during the RenewalIQ demo walkthrough.'
            )
        );
    }
}

if (!signals.isEmpty()) {
    insert signals;
}

// ---------------------------------------------------------------------------------------
// 3. Score synchronously through the shared entry point, so the demo does not depend on
//    the Queueable having run by the time you open a page.
// ---------------------------------------------------------------------------------------
Set<Id> accountIds = new Map<Id, Account>(accounts).keySet();
RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(accountIds);

// ---------------------------------------------------------------------------------------
// 4. Report, so the run itself tells you what to look at.
// ---------------------------------------------------------------------------------------
String orgUrl = URL.getOrgDomainUrl().toExternalForm();

System.debug(LoggingLevel.ERROR, '=== RenewalIQ demo scenario ===');
System.debug(
    LoggingLevel.ERROR,
    'Scored ' + result.processedCount +
    ', updated ' + result.updatedCount +
    ', history rows ' + result.historyCount +
    ', status changes ' + result.statusChangeCount +
    ', failures ' + result.failureCount
);

for (Account account : [
    SELECT Id, Name, RIQ_Health_Score__c, RIQ_Health_Status__c, RIQ_Churn_Probability__c,
        RIQ_ARR__c, RIQ_Contract_End_Date__c, Owner.Name
    FROM Account
    WHERE Id IN :accountIds
    ORDER BY RIQ_Health_Score__c ASC
]) {
    System.debug(
        LoggingLevel.ERROR,
        account.Name +
        ' | score ' + account.RIQ_Health_Score__c +
        ' | ' + account.RIQ_Health_Status__c +
        ' | churn ' + account.RIQ_Churn_Probability__c + '%' +
        ' | ARR ' + RIQ_CurrencyFormatter.formatInrCompact(account.RIQ_ARR__c) +
        ' | renewal ' + account.RIQ_Contract_End_Date__c +
        ' | owner ' + account.Owner.Name
    );
    System.debug(LoggingLevel.ERROR, '  record page: ' + orgUrl + '/lightning/r/Account/' + account.Id + '/view');
}

System.debug(LoggingLevel.ERROR, 'Command Center: ' + orgUrl + '/lightning/n/RIQ_Command_Center');
System.debug(
    LoggingLevel.ERROR,
    'Open executive outreach tasks: ' +
    [SELECT COUNT() FROM Task WHERE Subject LIKE 'Executive outreach:%' AND IsClosed = false]
);
System.debug(
    LoggingLevel.ERROR,
    'Open renewal opportunities: ' +
    [SELECT COUNT() FROM Opportunity WHERE Type = 'Renewal' AND IsClosed = false]
);
System.debug(LoggingLevel.ERROR, '=== done ===');
