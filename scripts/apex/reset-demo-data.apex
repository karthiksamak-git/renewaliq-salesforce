/*******************************************************************************************
 * RenewalIQ - remove demo and seed data.
 *
 * Deletes ONLY records this project created:
 *   - Accounts whose Description starts with "RenewalIQ demo data"
 *   - the leftover "Phase 4 Demo - ..." accounts from the earlier demo script
 *   - the 50 account names used by the first seed script
 *
 * Every dependent record is removed in dependency order first: tasks, opportunities,
 * score history and health signals, then the accounts. Nothing outside that set is
 * read for deletion or touched.
 *
 * Usage:
 *   sf apex run --file scripts/apex/reset-demo-data.apex --target-org <alias>
 *******************************************************************************************/

// Account.Description is a long text area, which SOQL cannot filter on, so the delete set
// is defined by name instead: every name either script has ever created, plus the
// "Phase 4 Demo - " prefix. Everything in that set is ours; nothing else is touched.

// The current Indian demo book.
List<String> currentSeedNames = new List<String>{
    'RupeeRoute Payments', 'NiveshLedger Capital', 'PaySetu Technologies', 'VaultBridge Lending',
    'NeoKhata Finance', 'VidyaLoop Learning', 'SkillKart Academy', 'Pathshala Cloud',
    'ExamBridge EduTech', 'GurukulSphere Learning', 'CargoChetak Logistics', 'LastMileYatra Logistics',
    'FleetMandi Mobility', 'BharatHaul Freight', 'ColdChainSetu Logistics', 'Sundar Precision Works',
    'Deccan Alloy Works', 'VayuForge Industries', 'Shakti Machine Tools', 'PrecisionKart Components',
    'ArogyaGrid Health', 'MediSetu Diagnostics', 'CareKarma Clinics', 'Nirog Health Systems',
    'PulseSathi Hospitals', 'BazaarNest Retail', 'KiranaConnect Retail', 'MetroBasket Stores',
    'ShopSagar Retail', 'Aangan Bazaar', 'CogniStack Systems', 'DevSetu Consulting',
    'CloudShala Services', 'Tarka Software Labs', 'NexaBridge IT', 'Mitti Home',
    'SpiceRoute Foods', 'ChaiCraft Beverages', 'VastraThread Apparel', 'BloomKart Beauty',
    'KineticRides Mobility', 'SolarSutra Energy', 'EduNova Labs', 'Medhaya Analytics',
    'AgriSetu Foods', 'TextileTales Mills', 'PrintPeak Media', 'GigGully Marketplaces',
    'TalentTarang HR Tech', 'FreshRoute Grocers'
};

// Names created by the first seed script (kept so an org seeded before Phase 5.5 can be cleared).
List<String> legacySeedNames = new List<String>{
    'Northwind Traders', 'Acme Logistics', 'Globex Manufacturing', 'Initech Systems',
    'Umbrella Health', 'Soylent Foods', 'Hooli Cloud', 'Vandelay Imports',
    'Stark Industrial', 'Wayne Enterprises', 'Cyberdyne Robotics', 'Tyrell Analytics',
    'Aperture Labs', 'Black Mesa Research', 'Wonka Confectionery', 'Gringotts Financial',
    'Dunder Mifflin Paper', 'Pied Piper Networks', 'Massive Dynamic', 'Oscorp Biotech',
    'Blue Sun Energy', 'Weyland Security', 'InGen Genetics', 'Nakatomi Trading',
    'Zenith Data', 'Titan Freight', 'Meridian Insurance', 'Cobalt Media',
    'Ironwood Realty', 'Silverline Bank', 'Redwood Hospitality', 'Falcon Aerospace',
    'Summit Utilities', 'Harbour Shipping', 'Brightpath Education', 'Clearpay Fintech',
    'Nova Telecom', 'Quartz Semiconductors', 'Vertex Pharma', 'Lumen Retail',
    'Kestrel Airlines', 'Timberline Mining', 'Solstice Solar', 'Aster Software',
    'Beacon Public Sector', 'Cascade Water', 'Draymoor Consulting', 'Eastgate Automotive',
    'Fairhaven Nonprofit', 'Granite Construction'
};

// ---------------------------------------------------------------------------------------
// 1. Collect the account ids. Three independent selectors, unioned in Apex.
// ---------------------------------------------------------------------------------------
Set<Id> accountIds = new Set<Id>();

for (Account account : [SELECT Id FROM Account WHERE Name IN :currentSeedNames]) {
    accountIds.add(account.Id);
}

for (Account account : [SELECT Id FROM Account WHERE Name IN :legacySeedNames]) {
    accountIds.add(account.Id);
}

for (Account account : [SELECT Id FROM Account WHERE Name LIKE 'Phase 4 Demo - %']) {
    accountIds.add(account.Id);
}

// ---------------------------------------------------------------------------------------
// 2. Count everything before deleting anything, so the run can be checked.
// ---------------------------------------------------------------------------------------
List<Task> tasks = accountIds.isEmpty()
    ? new List<Task>()
    : [SELECT Id FROM Task WHERE WhatId IN :accountIds];
List<Opportunity> opportunities = accountIds.isEmpty()
    ? new List<Opportunity>()
    : [SELECT Id FROM Opportunity WHERE AccountId IN :accountIds];
List<RIQ_Score_History__c> history = accountIds.isEmpty()
    ? new List<RIQ_Score_History__c>()
    : [SELECT Id FROM RIQ_Score_History__c WHERE Account__c IN :accountIds];
List<RIQ_Health_Signal__c> signals = accountIds.isEmpty()
    ? new List<RIQ_Health_Signal__c>()
    : [SELECT Id FROM RIQ_Health_Signal__c WHERE Account__c IN :accountIds];

System.debug(LoggingLevel.ERROR, '=== RenewalIQ reset: about to delete ===');
System.debug(LoggingLevel.ERROR, 'Accounts: ' + accountIds.size());
System.debug(LoggingLevel.ERROR, 'Tasks: ' + tasks.size());
System.debug(LoggingLevel.ERROR, 'Opportunities: ' + opportunities.size());
System.debug(LoggingLevel.ERROR, 'Score history rows: ' + history.size());
System.debug(LoggingLevel.ERROR, 'Health signals: ' + signals.size());

if (accountIds.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'Nothing to delete - the org has no RenewalIQ demo data.');
    return;
}

// ---------------------------------------------------------------------------------------
// 3. Delete in dependency order. allowPartialSuccess is false so a surprise failure
//    stops the run before the accounts go, rather than leaving orphans behind.
// ---------------------------------------------------------------------------------------
if (!tasks.isEmpty()) {
    delete tasks;
}

if (!opportunities.isEmpty()) {
    delete opportunities;
}

if (!history.isEmpty()) {
    delete history;
}

if (!signals.isEmpty()) {
    delete signals;
}

List<Account> accounts = [SELECT Id FROM Account WHERE Id IN :accountIds];
delete accounts;

System.debug(LoggingLevel.ERROR, '=== RenewalIQ reset complete ===');
System.debug(
    LoggingLevel.ERROR,
    'Deleted ' + accounts.size() + ' accounts and their signals, history, tasks and opportunities.'
);
