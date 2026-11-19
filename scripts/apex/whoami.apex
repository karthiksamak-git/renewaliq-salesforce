// Prints the running user's username. A scratch org's admin username is
// generated, so anything that has to name a user (the platform event subscriber
// config, for example) is built from this at setup time instead of being committed.
//
//     sf apex run --file scripts/apex/whoami.apex --target-org <alias>
System.debug('RIQ_USERNAME=' + UserInfo.getUserName());
System.debug('RIQ_ORG_ID=' + UserInfo.getOrganizationId());
