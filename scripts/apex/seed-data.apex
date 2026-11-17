/*******************************************************************************************
 * RenewalIQ - synthetic demo data for a portfolio org.
 *
 * Creates 50 FICTIONAL Indian B2B customers. The names, domains and people are invented:
 * this is demo data for a portfolio project, not a list of real companies or real
 * customers. ARR is in Indian Rupees, cities are Indian, and the signal notes describe
 * Indian operating context (GST invoices, QBRs, procurement).
 *
 * Usage:
 *   sf apex run --file scripts/apex/seed-data.apex --target-org <alias>
 *
 * Re-runnable: an account whose name already exists is skipped. To start clean, run
 * scripts/apex/reset-demo-data.apex first.
 *
 * Scores are never written here. Signals are inserted through the normal object, the
 * scoring engine runs through RIQ_HealthScoreRecalculator.process, and the distribution
 * printed at the end is whatever the engine produced.
 *******************************************************************************************/

Decimal[] arrTiers = new Decimal[]{
    500000, 750000, 900000, 1200000, 1500000, 1800000,       // 5 L - 18 L
    2200000, 2800000, 3600000, 4500000, 5500000, 7000000,    // 22 L - 70 L
    9000000, 12000000, 18000000, 25000000, 35000000, 48000000 // 90 L - 4.8 Cr
};

// Name | Industry | City | State
List<List<String>> rows = new List<List<String>>{
    new List<String>{ 'RupeeRoute Payments', 'Fintech', 'Bengaluru', 'Karnataka' },
    new List<String>{ 'NiveshLedger Capital', 'Fintech', 'Mumbai', 'Maharashtra' },
    new List<String>{ 'PaySetu Technologies', 'Fintech', 'Pune', 'Maharashtra' },
    new List<String>{ 'VaultBridge Lending', 'Fintech', 'Hyderabad', 'Telangana' },
    new List<String>{ 'NeoKhata Finance', 'Fintech', 'Ahmedabad', 'Gujarat' },
    new List<String>{ 'VidyaLoop Learning', 'Edtech', 'Bengaluru', 'Karnataka' },
    new List<String>{ 'SkillKart Academy', 'Edtech', 'Chennai', 'Tamil Nadu' },
    new List<String>{ 'Pathshala Cloud', 'Edtech', 'Pune', 'Maharashtra' },
    new List<String>{ 'ExamBridge EduTech', 'Edtech', 'New Delhi', 'Delhi' },
    new List<String>{ 'GurukulSphere Learning', 'Edtech', 'Kolkata', 'West Bengal' },
    new List<String>{ 'CargoChetak Logistics', 'Logistics', 'Mumbai', 'Maharashtra' },
    new List<String>{ 'LastMileYatra Logistics', 'Logistics', 'Gurugram', 'Haryana' },
    new List<String>{ 'FleetMandi Mobility', 'Logistics', 'Hyderabad', 'Telangana' },
    new List<String>{ 'BharatHaul Freight', 'Logistics', 'Ahmedabad', 'Gujarat' },
    new List<String>{ 'ColdChainSetu Logistics', 'Logistics', 'Chennai', 'Tamil Nadu' },
    new List<String>{ 'Sundar Precision Works', 'Manufacturing', 'Pune', 'Maharashtra' },
    new List<String>{ 'Deccan Alloy Works', 'Manufacturing', 'Hyderabad', 'Telangana' },
    new List<String>{ 'VayuForge Industries', 'Manufacturing', 'Ahmedabad', 'Gujarat' },
    new List<String>{ 'Shakti Machine Tools', 'Manufacturing', 'Coimbatore', 'Tamil Nadu' },
    new List<String>{ 'PrecisionKart Components', 'Manufacturing', 'Bengaluru', 'Karnataka' },
    new List<String>{ 'ArogyaGrid Health', 'Healthcare', 'Bengaluru', 'Karnataka' },
    new List<String>{ 'MediSetu Diagnostics', 'Healthcare', 'Mumbai', 'Maharashtra' },
    new List<String>{ 'CareKarma Clinics', 'Healthcare', 'Chennai', 'Tamil Nadu' },
    new List<String>{ 'Nirog Health Systems', 'Healthcare', 'Kolkata', 'West Bengal' },
    new List<String>{ 'PulseSathi Hospitals', 'Healthcare', 'Hyderabad', 'Telangana' },
    new List<String>{ 'BazaarNest Retail', 'Retail', 'Mumbai', 'Maharashtra' },
    new List<String>{ 'KiranaConnect Retail', 'Retail', 'New Delhi', 'Delhi' },
    new List<String>{ 'MetroBasket Stores', 'Retail', 'Pune', 'Maharashtra' },
    new List<String>{ 'ShopSagar Retail', 'Retail', 'Ahmedabad', 'Gujarat' },
    new List<String>{ 'Aangan Bazaar', 'Retail', 'Kolkata', 'West Bengal' },
    new List<String>{ 'CogniStack Systems', 'IT Services', 'Bengaluru', 'Karnataka' },
    new List<String>{ 'DevSetu Consulting', 'IT Services', 'Pune', 'Maharashtra' },
    new List<String>{ 'CloudShala Services', 'IT Services', 'Hyderabad', 'Telangana' },
    new List<String>{ 'Tarka Software Labs', 'IT Services', 'Chennai', 'Tamil Nadu' },
    new List<String>{ 'NexaBridge IT', 'IT Services', 'Noida', 'Uttar Pradesh' },
    new List<String>{ 'Mitti Home', 'D2C', 'New Delhi', 'Delhi' },
    new List<String>{ 'SpiceRoute Foods', 'D2C', 'Mumbai', 'Maharashtra' },
    new List<String>{ 'ChaiCraft Beverages', 'D2C', 'Pune', 'Maharashtra' },
    new List<String>{ 'VastraThread Apparel', 'D2C', 'Kolkata', 'West Bengal' },
    new List<String>{ 'BloomKart Beauty', 'D2C', 'Bengaluru', 'Karnataka' },
    new List<String>{ 'KineticRides Mobility', 'Logistics', 'Chennai', 'Tamil Nadu' },
    new List<String>{ 'SolarSutra Energy', 'Manufacturing', 'Ahmedabad', 'Gujarat' },
    new List<String>{ 'EduNova Labs', 'Edtech', 'Hyderabad', 'Telangana' },
    new List<String>{ 'Medhaya Analytics', 'IT Services', 'Bengaluru', 'Karnataka' },
    new List<String>{ 'AgriSetu Foods', 'D2C', 'Pune', 'Maharashtra' },
    new List<String>{ 'TextileTales Mills', 'Manufacturing', 'Kolkata', 'West Bengal' },
    new List<String>{ 'PrintPeak Media', 'D2C', 'Mumbai', 'Maharashtra' },
    new List<String>{ 'GigGully Marketplaces', 'Retail', 'Bengaluru', 'Karnataka' },
    new List<String>{ 'TalentTarang HR Tech', 'IT Services', 'New Delhi', 'Delhi' },
    new List<String>{ 'FreshRoute Grocers', 'Retail', 'Chennai', 'Tamil Nadu' }
};

// ---------------------------------------------------------------------------------------
// 1. Skip accounts that were already seeded, so re-running does not duplicate data.
// ---------------------------------------------------------------------------------------
List<String> companyNames = new List<String>();
for (List<String> row : rows) {
    companyNames.add(row[0]);
}

Set<String> existingNames = new Set<String>();
for (Account existingAccount : [SELECT Name FROM Account WHERE Name IN :companyNames]) {
    existingNames.add(existingAccount.Name);
}

// ---------------------------------------------------------------------------------------
// 2. Build the accounts.
//
//    ARR is deliberately skewed: 30 small (5 L - 18 L), 14 mid (22 L - 70 L) and 6 large
//    (90 L - 4.8 Cr), which is what a real Indian B2B book looks like. Contract end dates
//    run across the next 400 days with four recently expired, so the 120 day renewal
//    playbook has something to work on in every window.
// ---------------------------------------------------------------------------------------
List<Account> accountsToInsert = new List<Account>();

for (Integer i = 0; i < rows.size(); i++) {
    List<String> row = rows[i];

    if (existingNames.contains(row[0])) {
        continue;
    }

    Integer bandIndex;
    if (i < 30) {
        bandIndex = Math.mod(i, 6);
    } else if (i < 44) {
        bandIndex = 6 + Math.mod(i, 6);
    } else {
        bandIndex = 12 + Math.mod(i, 6);
    }

    // Renewals are lumpy in real books: most contracts renew inside the next four
    // months (which is what the 120 day playbook and the 90 day default window look
    // at), the rest are spread out to just over a year, and a few have already
    // lapsed. A uniform spread over 400 days leaves the table almost empty.
    Integer contractOffset;
    if (Math.mod(i, 13) == 0) {
        contractOffset = -5 - Math.mod(i, 20);
    } else if (Math.mod(i, 5) < 3) {
        contractOffset = 1 + Math.mod(i * 37, 120);
    } else {
        contractOffset = 121 + Math.mod(i * 53, 280);
    }

    accountsToInsert.add(
        new Account(
            Name = row[0],
            Industry = row[1],
            BillingCity = row[2],
            BillingState = row[3],
            BillingCountry = 'India',
            Description = 'RenewalIQ demo data - a synthetic account for a portfolio project. Not a real customer.',
            RIQ_ARR__c = arrTiers[bandIndex],
            RIQ_Contract_End_Date__c = Date.today().addDays(contractOffset)
        )
    );
}

List<Account> insertedAccounts = new List<Account>();
Integer accountFailures = 0;

if (!accountsToInsert.isEmpty()) {
    List<Database.SaveResult> accountResults = Database.insert(accountsToInsert, false);

    for (Integer i = 0; i < accountResults.size(); i++) {
        if (accountResults[i].isSuccess()) {
            insertedAccounts.add(accountsToInsert[i]);
        } else {
            accountFailures++;
            System.debug(
                LoggingLevel.ERROR,
                'Failed to insert Account ' + accountsToInsert[i].Name + ': ' + accountResults[i].getErrors()[0].getMessage()
            );
        }
    }
}

// ---------------------------------------------------------------------------------------
// 3. Signal pools per archetype. Healthy accounts skew positive, Critical accounts skew
//    negative, so the engine produces a believable spread once it runs.
// ---------------------------------------------------------------------------------------
// "Type|Severity|DaysAgo". The mix is tuned against the real scoring rules
// (score = 100 - sum(baseWeight * severity * linearDecay)) so the engine lands in the
// intended band, and the ages are spread across the 120 day window so trends have shape.
Map<String, List<String>> signalsByArchetype = new Map<String, List<String>>{
    'Healthy' => new List<String>{
        'Positive Expansion|2|50',
        'NPS Detractor|2|25',
        'Missed QBR|2|70'
    },
    'Watch' => new List<String>{
        'NPS Detractor|2|20',
        'Missed QBR|2|60',
        'Low Product Usage|1|35'
    },
    'At Risk' => new List<String>{
        'Support Escalation|3|55',
        'Missed QBR|2|40',
        'NPS Detractor|2|15',
        'Low Product Usage|2|85'
    },
    'Critical A' => new List<String>{
        'Support Escalation|4|35',
        'Late Payment|2|28',
        'Low Product Usage|1|70'
    },
    'Critical B' => new List<String>{
        'Executive Sponsor Left|4|30',
        'Late Payment|2|45',
        'Missed QBR|3|95'
    }
};

Map<String, String> notesBySignalType = new Map<String, String>{
    'Support Escalation' => 'P1 ticket escalated to the engineering team; the customer is waiting on a fix.',
    'Low Product Usage' => 'Weekly active users fell below the trailing 90 day average.',
    'Missed QBR' => 'The quarterly business review was cancelled twice by the customer operations team.',
    'Executive Sponsor Left' => 'The executive sponsor moved to another company; no replacement is named yet.',
    'Late Payment' => 'Repeated GST invoice mismatches raised by the billing contact; payment is over 30 days late.',
    'NPS Detractor' => 'Survey score of 4 or below from the primary contact.',
    'Positive Expansion' => 'A new business unit onboarded and seat count increased this quarter.'
};

// ---------------------------------------------------------------------------------------
// 4. Generate the signals: 15 healthy, 15 watch, 12 at risk, 8 critical, all dated inside
//    the last 120 days and spread over that window so the trends have shape.
// ---------------------------------------------------------------------------------------
List<RIQ_Health_Signal__c> signalsToInsert = new List<RIQ_Health_Signal__c>();

for (Integer i = 0; i < insertedAccounts.size(); i++) {
    // Walk the list with a stride so each band gets a mix of small, mid and large
    // accounts instead of every large account landing in the same band. 7 and 50
    // share no factor, so the walk visits every position exactly once.
    Integer slot = Math.mod(i * 7, insertedAccounts.size());
    String archetype;
    if (slot < 15) {
        archetype = 'Healthy';
    } else if (slot < 30) {
        archetype = 'Watch';
    } else if (slot < 42) {
        archetype = 'At Risk';
    } else {
        archetype = 'Critical';
    }

    String recipeKey = archetype == 'Critical'
        ? (Math.mod(i, 2) == 0 ? 'Critical A' : 'Critical B')
        : archetype;
    List<String> recipe = signalsByArchetype.get(recipeKey);

    for (String raw : recipe) {
        List<String> parts = raw.split('\\|');
        String signalType = parts[0];
        Integer severity = Integer.valueOf(parts[1]);
        Integer daysAgo = Integer.valueOf(parts[2]) + Math.mod(i, 7) - 3;
        daysAgo = Math.max(1, Math.min(118, daysAgo));

        signalsToInsert.add(
            new RIQ_Health_Signal__c(
                Account__c = insertedAccounts[i].Id,
                Signal_Type__c = signalType,
                Severity__c = severity,
                Occurred_On__c = Date.today().addDays(-daysAgo),
                Notes__c = notesBySignalType.get(signalType)
            )
        );
    }
}

Integer signalFailures = 0;
if (!signalsToInsert.isEmpty()) {
    List<Database.SaveResult> signalResults = Database.insert(signalsToInsert, false);

    for (Database.SaveResult signalResult : signalResults) {
        if (!signalResult.isSuccess()) {
            signalFailures++;
        }
    }
}

// ---------------------------------------------------------------------------------------
// 5. Score through the real engine. No score, status or churn value is written by this
//    script: RIQ_HealthScoreRecalculator is the same code the nightly batch runs.
// ---------------------------------------------------------------------------------------
List<Account> scoped = [
    SELECT Id
    FROM Account
    WHERE Name IN :companyNames
];
Set<Id> accountIds = new Map<Id, Account>(scoped).keySet();

RIQ_HealthScoreRecalculator.ProcessResult result = RIQ_HealthScoreRecalculator.process(accountIds);

// ---------------------------------------------------------------------------------------
// 6. Report. The distribution below is read back from the org after scoring.
// ---------------------------------------------------------------------------------------
System.debug(LoggingLevel.ERROR, '=== RenewalIQ seed complete ===');
System.debug(
    LoggingLevel.ERROR,
    'Accounts inserted: ' + insertedAccounts.size() +
    ' (skipped, already present: ' + existingNames.size() +
    ', insert failures: ' + accountFailures + ')'
);
System.debug(
    LoggingLevel.ERROR,
    'Signals inserted: ' + (signalsToInsert.size() - signalFailures) + ', signal failures: ' + signalFailures
);
System.debug(
    LoggingLevel.ERROR,
    'Scoring: processed ' + result.processedCount +
    ', updated ' + result.updatedCount +
    ', history rows ' + result.historyCount +
    ', status changes ' + result.statusChangeCount +
    ', failures ' + result.failureCount
);

System.debug(LoggingLevel.ERROR, 'Healthy: ' + [SELECT COUNT() FROM Account WHERE Name IN :companyNames AND RIQ_Health_Status__c = 'Healthy']);
System.debug(LoggingLevel.ERROR, 'Watch: ' + [SELECT COUNT() FROM Account WHERE Name IN :companyNames AND RIQ_Health_Status__c = 'Watch']);
System.debug(LoggingLevel.ERROR, 'At Risk: ' + [SELECT COUNT() FROM Account WHERE Name IN :companyNames AND RIQ_Health_Status__c = 'At Risk']);
System.debug(LoggingLevel.ERROR, 'Critical: ' + [SELECT COUNT() FROM Account WHERE Name IN :companyNames AND RIQ_Health_Status__c = 'Critical']);
System.debug(
    LoggingLevel.ERROR,
    'Total ARR in the demo book: ' + RIQ_CurrencyFormatter.formatInr([SELECT SUM(RIQ_ARR__c) total FROM Account WHERE Name IN :companyNames][0].get('total') == null
        ? 0
        : (Decimal) [SELECT SUM(RIQ_ARR__c) total FROM Account WHERE Name IN :companyNames][0].get('total'))
);
