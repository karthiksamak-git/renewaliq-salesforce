/**
 * @description The playbook that turns "this account just got worse" into work.
 *
 * Two motions, both idempotent:
 *   1. An executive outreach Task for the account owner (High priority when the
 *      account is Critical, Normal for At Risk).
 *   2. A renewal Opportunity when the contract ends inside the renewal window
 *      and the account has no open renewal yet.
 *
 * "Renewal Opportunity" is defined explicitly as Type = 'Renewal' with the
 * opportunity still open. Nothing else counts, so a genuine upsell sitting in
 * the pipeline cannot accidentally suppress the renewal motion, and a closed
 * renewal in a previous term cannot either.
 *
 * Bulk safety: one Account query, one Task query, one Opportunity query, one
 * Task insert and one Opportunity insert for the whole event batch. Duplicates
 * are removed twice - across the event batch in memory, and against what is
 * already open in the org - because platform events are delivered at least
 * once.
 */
public with sharing class RIQ_PlaybookService {
    /** Task subject prefix; the account name is appended. */
    public static final String TASK_SUBJECT_PREFIX = 'Executive outreach: ';
    /** Only this Opportunity Type counts as a renewal. */
    public static final String RENEWAL_OPPORTUNITY_TYPE = 'Renewal';
    /** A renewal is opened when the contract ends inside this many days. */
    public static final Integer RENEWAL_WINDOW_DAYS = 120;
    /** Outreach is due this many days after the status change. */
    public static final Integer TASK_DUE_IN_DAYS = 3;
    /** Stage a freshly created renewal starts in. */
    public static final String RENEWAL_STAGE = 'Prospecting';
    /** Statuses that trigger the human playbook. */
    private static final Set<String> PLAYBOOK_STATUSES = new Set<String>{ 'At Risk', 'Critical' };

    /**
     * @description Handles one delivered batch of status-change events.
     * @param rawEvents Trigger.new from RIQ_HealthStatusChangeTrigger.
     * @return What the batch created, for tests and logging.
     */
    public static PlaybookResult run(List<SObject> rawEvents) {
        PlaybookResult result = new PlaybookResult();

        if (rawEvents == null || rawEvents.isEmpty()) {
            return result;
        }

        // Collapse the batch to the newest event per account first: a burst of
        // signals can publish several transitions for one account, and a CSM
        // needs one task, not three.
        Map<Id, RIQ_Health_Status_Change__e> latestEventByAccount = new Map<Id, RIQ_Health_Status_Change__e>();

        for (SObject rawEvent : rawEvents) {
            RIQ_Health_Status_Change__e event = (RIQ_Health_Status_Change__e) rawEvent;

            if (event.AccountId__c == null || !PLAYBOOK_STATUSES.contains(event.NewStatus__c)) {
                continue;
            }

            latestEventByAccount.put(Id.valueOf(event.AccountId__c), event);
        }

        if (latestEventByAccount.isEmpty()) {
            return result;
        }

        Set<Id> accountIds = latestEventByAccount.keySet();
        // SYSTEM_MODE throughout this class. The subscriber runs as the Automated
        // Process user, which owns none of these records and holds no RenewalIQ
        // permission set; enforcing the scheduling user's sharing here would make
        // the playbook silently stop working the moment an account changed owner.
        Map<Id, Account> accountsById = new Map<Id, Account>(
            new RIQ_AccountSelector(AccessLevel.SYSTEM_MODE).getByIds(accountIds)
        );
        Map<Id, Set<String>> openTaskSubjects = getOpenOutreachSubjects(accountIds);
        Set<Id> accountsWithOpenRenewal = getAccountsWithOpenRenewal(accountIds);

        List<Task> tasksToInsert = new List<Task>();
        List<Opportunity> opportunitiesToInsert = new List<Opportunity>();

        for (Id accountId : accountIds) {
            Account account = accountsById.get(accountId);

            if (account == null) {
                // Account deleted between publish and subscribe: nothing to do.
                result.skippedCount++;
                continue;
            }

            RIQ_Health_Status_Change__e event = latestEventByAccount.get(accountId);
            String subject = TASK_SUBJECT_PREFIX + account.Name;

            if (hasOpenTask(openTaskSubjects, accountId, subject)) {
                result.skippedCount++;
            } else {
                tasksToInsert.add(buildOutreachTask(account, subject, event.NewStatus__c));
                rememberTask(openTaskSubjects, accountId, subject);
            }

            if (isRenewalWindowOpen(account) && !accountsWithOpenRenewal.contains(accountId)) {
                opportunitiesToInsert.add(buildRenewalOpportunity(account));
                accountsWithOpenRenewal.add(accountId);
            }
        }

        result.tasksCreated = insertTasks(tasksToInsert);
        result.opportunitiesCreated = insertOpportunities(opportunitiesToInsert);
        result.failureCount = (tasksToInsert.size() - result.tasksCreated) + (opportunitiesToInsert.size() - result.opportunitiesCreated);
        result.insightJobQueued = enqueueInsightJob(accountIds);

        return result;
    }

    /**
     * @description Hands insight generation to a Queueable instead of calling the
     * model here. This runs inside a platform event trigger, which already holds
     * uncommitted DML, so a callout is illegal and a slow model would hold the
     * subscriber transaction open. Failure to enqueue is not a playbook failure:
     * the task and the renewal still matter more than a summary.
     * @param accountIds Accounts that moved into a risky band.
     * @return True when the job was accepted.
     */
    private static Boolean enqueueInsightJob(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return false;
        }

        try {
            System.enqueueJob(new RIQ_AiInsightQueueable(accountIds));
            return true;
        } catch (Exception enqueueFailure) {
            RIQ_Logger.warn('RIQ_PlaybookService', 'Insight job was not enqueued.', enqueueFailure);
            return false;
        }
    }

    /**
     * @description Builds the owner's outreach task.
     * @param account Account that changed.
     * @param subject Pre-computed, dedupe-safe subject.
     * @param newStatus The band the account moved into.
     * @return Unsaved Task.
     */
    private static Task buildOutreachTask(Account account, String subject, String newStatus) {
        return new Task(
            Subject = subject,
            WhatId = account.Id,
            OwnerId = account.OwnerId,
            ActivityDate = Date.today().addDays(TASK_DUE_IN_DAYS),
            Priority = newStatus == 'Critical' ? 'High' : 'Normal',
            Status = 'Not Started',
            Description = 'RenewalIQ moved this account to ' + newStatus + '. Confirm executive sponsorship and the renewal plan.'
        );
    }

    /**
     * @description Builds the renewal opportunity from the contract data.
     * @param account Account inside the renewal window.
     * @return Unsaved Opportunity.
     */
    private static Opportunity buildRenewalOpportunity(Account account) {
        return new Opportunity(
            Name = account.Name + ' Renewal',
            AccountId = account.Id,
            Type = RENEWAL_OPPORTUNITY_TYPE,
            StageName = RENEWAL_STAGE,
            CloseDate = account.RIQ_Contract_End_Date__c,
            Amount = account.RIQ_ARR__c
        );
    }

    /**
     * @description "Within 120 days" means the contract ends today through
     * today + 120, inclusive. Already-expired contracts are excluded on
     * purpose: they belong to a collections/win-back motion, not to a renewal
     * playbook whose value is the time left to act.
     * @param account Account to test.
     * @return True when a renewal should be opened.
     */
    private static Boolean isRenewalWindowOpen(Account account) {
        if (account.RIQ_Contract_End_Date__c == null) {
            return false;
        }

        Integer daysToContractEnd = Date.today().daysBetween(account.RIQ_Contract_End_Date__c);
        return daysToContractEnd >= 0 && daysToContractEnd <= RENEWAL_WINDOW_DAYS;
    }

    /**
     * @description Loads the open outreach tasks for the whole batch in one
     * query, keyed by account, so idempotency costs one SOQL rather than one
     * per event.
     * @param accountIds Accounts in this batch.
     * @return Account id to set of open outreach subjects.
     */
    private static Map<Id, Set<String>> getOpenOutreachSubjects(Set<Id> accountIds) {
        Map<Id, Set<String>> subjectsByAccount = new Map<Id, Set<String>>();
        String subjectPattern = TASK_SUBJECT_PREFIX + '%';

        for (Task existingTask : [
            SELECT Id, WhatId, Subject
            FROM Task
            WHERE WhatId IN :accountIds AND IsClosed = FALSE AND Subject LIKE :subjectPattern
            WITH SYSTEM_MODE
        ]) {
            rememberTask(subjectsByAccount, existingTask.WhatId, existingTask.Subject);
        }

        return subjectsByAccount;
    }

    /**
     * @description Accounts that already have an open renewal, so a second
     * event cannot create a second one.
     * @param accountIds Accounts in this batch.
     * @return Account ids with an open Type = 'Renewal' opportunity.
     */
    private static Set<Id> getAccountsWithOpenRenewal(Set<Id> accountIds) {
        Set<Id> accountIdsWithRenewal = new Set<Id>();

        for (Opportunity renewal : [
            SELECT AccountId
            FROM Opportunity
            WHERE AccountId IN :accountIds AND Type = :RENEWAL_OPPORTUNITY_TYPE AND IsClosed = FALSE
            WITH SYSTEM_MODE
        ]) {
            accountIdsWithRenewal.add(renewal.AccountId);
        }

        return accountIdsWithRenewal;
    }

    /**
     * @param subjectsByAccount In-memory index of open outreach subjects.
     * @param accountId Account to check.
     * @param subject Exact subject the playbook would create.
     * @return True when that task is already open.
     */
    private static Boolean hasOpenTask(Map<Id, Set<String>> subjectsByAccount, Id accountId, String subject) {
        Set<String> subjects = subjectsByAccount.get(accountId);
        return subjects != null && subjects.contains(subject);
    }

    /**
     * @param subjectsByAccount In-memory index of open outreach subjects.
     * @param accountId Account the task belongs to.
     * @param subject Subject to record.
     */
    private static void rememberTask(Map<Id, Set<String>> subjectsByAccount, Id accountId, String subject) {
        if (accountId == null) {
            return;
        }

        if (!subjectsByAccount.containsKey(accountId)) {
            subjectsByAccount.put(accountId, new Set<String>());
        }

        subjectsByAccount.get(accountId).add(subject);
    }

    /**
     * @param tasks Tasks to insert.
     * @return Number inserted successfully.
     */
    private static Integer insertTasks(List<Task> tasks) {
        if (tasks.isEmpty()) {
            return 0;
        }

        Integer inserted = 0;
        for (Database.SaveResult saveResult : Database.insert(tasks, false, AccessLevel.SYSTEM_MODE)) {
            if (saveResult.isSuccess()) {
                inserted++;
            } else {
                RIQ_Logger.error('RIQ_PlaybookService', 'Could not create an outreach task.', null, String.valueOf(saveResult.getId()));
            }
        }

        return inserted;
    }

    /**
     * @param opportunities Opportunities to insert.
     * @return Number inserted successfully.
     */
    private static Integer insertOpportunities(List<Opportunity> opportunities) {
        if (opportunities.isEmpty()) {
            return 0;
        }

        Integer inserted = 0;
        for (Database.SaveResult saveResult : Database.insert(opportunities, false, AccessLevel.SYSTEM_MODE)) {
            if (saveResult.isSuccess()) {
                inserted++;
            } else {
                RIQ_Logger.error('RIQ_PlaybookService', 'Could not create a renewal opportunity.', null, String.valueOf(saveResult.getId()));
            }
        }

        return inserted;
    }

    /**
     * @description What one event batch produced.
     */
    public class PlaybookResult {
        /** Outreach tasks created. */
        public Integer tasksCreated = 0;
        /** Renewal opportunities created. */
        public Integer opportunitiesCreated = 0;
        /** Events or motions skipped as duplicates or out of scope. */
        public Integer skippedCount = 0;
        /** Inserts that failed. */
        public Integer failureCount = 0;
        /** True when background insight generation was accepted for this batch. */
        public Boolean insightJobQueued = false;
    }
}
