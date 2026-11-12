/*******************************************************************************************
 * RenewalIQ - seed data for demos and manual verification.
 *
 * Creates 50 synthetic Accounts with varied ARR and contract end dates, then attaches
 * 200+ RIQ_Health_Signal__c records with a realistic distribution across the four
 * health archetypes (Healthy / Watch / At Risk / Critical).
 *
 * Usage:
 *   sf apex run --file scripts/apex/seed-data.apex --target-org <alias>
 *
 * The script is re-runnable: Accounts that already exist with the same Name are skipped.
 * To start over, delete the seeded Accounts first (their signals cascade):
 *   sf data delete bulk --sobject Account --file <names.csv> --target-org <alias>
 *
 * Scores are intentionally NOT written here - the scoring engine owns them from Phase 2.
 *******************************************************************************************/

List<String> companyNames = new List<String>{
    'Northwind Traders',
    'Acme Logistics',
    'Globex Manufacturing',
    'Initech Systems',
    'Umbrella Health',
    'Soylent Foods',
    'Hooli Cloud',
    'Vandelay Imports',
    'Stark Industrial',
    'Wayne Enterprises',
    'Cyberdyne Robotics',
    'Tyrell Analytics',
    'Aperture Labs',
    'Black Mesa Research',
    'Wonka Confectionery',
    'Gringotts Financial',
    'Dunder Mifflin Paper',
    'Pied Piper Networks',
    'Massive Dynamic',
    'Oscorp Biotech',
    'Blue Sun Energy',
    'Weyland Security',
    'InGen Genetics',
    'Nakatomi Trading',
    'Zenith Data',
    'Titan Freight',
    'Meridian Insurance',
    'Cobalt Media',
    'Ironwood Realty',
    'Silverline Bank',
    'Redwood Hospitality',
    'Falcon Aerospace',
    'Summit Utilities',
    'Harbour Shipping',
    'Brightpath Education',
    'Clearpay Fintech',
    'Nova Telecom',
    'Quartz Semiconductors',
    'Vertex Pharma',
    'Lumen Retail',
    'Kestrel Airlines',
    'Timberline Mining',
    'Solstice Solar',
    'Aster Software',
    'Beacon Public Sector',
    'Cascade Water',
    'Draymoor Consulting',
    'Eastgate Automotive',
    'Fairhaven Nonprofit',
    'Granite Construction'
};

// ---------------------------------------------------------------------------------------
// 1. Skip Accounts that were already seeded, so re-running does not duplicate data.
// ---------------------------------------------------------------------------------------
Set<String> existingNames = new Set<String>();
for (Account existingAccount : [SELECT Name FROM Account WHERE Name IN :companyNames]) {
    existingNames.add(existingAccount.Name);
}

// ---------------------------------------------------------------------------------------
// 2. Build the Accounts: ARR from 15k to 264k with a few enterprise-scale outliers,
//    and contract end dates spread from 30 days ago to roughly 13 months out.
// ---------------------------------------------------------------------------------------
List<Account> accountsToInsert = new List<Account>();
for (Integer i = 0; i < companyNames.size(); i++) {
    if (existingNames.contains(companyNames[i])) {
        continue;
    }

    Decimal arr = 15000 + (Math.mod(i, 10) * 27500);
    if (Math.mod(i, 7) == 0) {
        arr = arr * 3;
    }

    Integer contractOffset = Math.mod(i * 37, 430) - 30;

    accountsToInsert.add(
        new Account(
            Name = companyNames[i],
            Description = 'RenewalIQ seed account - synthetic data for demo and manual testing.',
            RIQ_ARR__c = arr,
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
            System.debug(LoggingLevel.ERROR, 'Failed to insert Account ' + accountsToInsert[i].Name);
        }
    }
}

// ---------------------------------------------------------------------------------------
// 3. Signal pools per archetype. Healthy accounts skew positive, Critical accounts skew
//    negative, so the scoring engine produces a believable spread once it runs.
// ---------------------------------------------------------------------------------------
Map<String, List<String>> signalPoolByArchetype = new Map<String, List<String>>{
    'Healthy' => new List<String>{ 'Positive Expansion', 'Positive Expansion', 'Missed QBR', 'NPS Detractor' },
    'Watch' => new List<String>{ 'Missed QBR', 'Low Product Usage', 'NPS Detractor', 'Positive Expansion' },
    'At Risk' => new List<String>{
        'Support Escalation',
        'Low Product Usage',
        'Late Payment',
        'Missed QBR',
        'NPS Detractor'
    },
    'Critical' => new List<String>{
        'Support Escalation',
        'Executive Sponsor Left',
        'Late Payment',
        'Low Product Usage',
        'NPS Detractor',
        'Missed QBR'
    }
};

Map<String, Integer> baseSignalCountByArchetype = new Map<String, Integer>{
    'Healthy' => 3,
    'Watch' => 4,
    'At Risk' => 5,
    'Critical' => 6
};

Map<String, String> notesBySignalType = new Map<String, String>{
    'Support Escalation' => 'P1 ticket escalated to engineering; the customer is waiting on a fix.',
    'Low Product Usage' => 'Weekly active users down versus the trailing 90 day average.',
    'Missed QBR' => 'Quarterly business review was cancelled twice by the customer.',
    'Executive Sponsor Left' => 'Champion left the company; no replacement identified yet.',
    'Late Payment' => 'Invoice past due by more than 30 days.',
    'NPS Detractor' => 'Survey response of 4 or below from the primary contact.',
    'Positive Expansion' => 'New business unit onboarded; seat count increased this quarter.'
};

// ---------------------------------------------------------------------------------------
// 4. Generate the signals. Index ranges assign the archetype so the demo org always has
//    a stable mix: 15 healthy, 15 watch, 12 at risk, 8 critical.
// ---------------------------------------------------------------------------------------
List<RIQ_Health_Signal__c> signalsToInsert = new List<RIQ_Health_Signal__c>();
for (Integer i = 0; i < insertedAccounts.size(); i++) {
    String archetype;
    if (i < 15) {
        archetype = 'Healthy';
    } else if (i < 30) {
        archetype = 'Watch';
    } else if (i < 42) {
        archetype = 'At Risk';
    } else {
        archetype = 'Critical';
    }

    List<String> pool = signalPoolByArchetype.get(archetype);
    Integer signalCount = baseSignalCountByArchetype.get(archetype) + Math.mod(i, 2);

    for (Integer s = 0; s < signalCount; s++) {
        String signalType = pool[Math.mod(i + s, pool.size())];

        Integer severity;
        if (signalType == 'Positive Expansion') {
            severity = 2;
        } else if (archetype == 'Critical') {
            severity = 4 + Math.mod(i + s, 2);
        } else if (archetype == 'At Risk') {
            severity = 3 + Math.mod(i + s, 3);
        } else {
            severity = 1 + Math.mod(i + s, 3);
        }

        Integer daysAgo = 3 + Math.mod((i * 11) + (s * 23), 170);

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
// 5. Report what happened so the result is visible in the CLI output.
// ---------------------------------------------------------------------------------------
System.debug(
    LoggingLevel.INFO,
    'RenewalIQ seed complete - accounts inserted: ' +
        insertedAccounts.size() +
        ' (existing skipped: ' +
        existingNames.size() +
        ', failures: ' +
        accountFailures +
        '), signals inserted: ' +
        (signalsToInsert.size() - signalFailures) +
        ', signal failures: ' +
        signalFailures
);
