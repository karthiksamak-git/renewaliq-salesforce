import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { publish, MessageContext } from 'lightning/messageService';
import SCORE_REFRESH from '@salesforce/messageChannel/RIQ_Score_Refresh__c';
import getSignalTypes from '@salesforce/apex/RIQ_AccountHealthController.getSignalTypes';
import logSignal from '@salesforce/apex/RIQ_AccountHealthController.logSignal';

/** Severity scale, 1 = cosmetic, 5 = existential. */
const SEVERITY_OPTIONS = [
  { label: '1 — Minor', value: '1' },
  { label: '2 — Low', value: '2' },
  { label: '3 — Moderate', value: '3' },
  { label: '4 — High', value: '4' },
  { label: '5 — Critical', value: '5' }
];

/** How long to wait before asking the score card to refresh. */
const SCORE_SETTLE_MS = 4000;

export default class RiqSignalLogger extends LightningElement {
  /** Account record page context. */
  @api recordId;

  signalTypes = [];
  signalType;
  severity = '3';
  occurredOn = RiqSignalLogger.todayIso();
  notes = '';

  errorMessage;
  fieldErrors = {};
  isSaving = false;
  isScoreUpdating = false;
  refreshTimer;

  @wire(MessageContext)
  messageContext;

  connectedCallback() {
    this.loadSignalTypes();
  }

  disconnectedCallback() {
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = undefined;
    }
  }

  async loadSignalTypes() {
    try {
      const types = await getSignalTypes();
      this.signalTypes = (types || []).map((type) => ({ label: type, value: type }));
    } catch (error) {
      this.errorMessage = this.reduceError(error);
    }
  }

  /* ------------------------------------------------------------ handlers */

  handleTypeChange(event) {
    this.signalType = event.detail.value;
  }

  handleSeverityChange(event) {
    this.severity = event.detail.value;
  }

  handleDateChange(event) {
    this.occurredOn = event.detail.value;
  }

  handleNotesChange(event) {
    this.notes = event.detail.value;
  }

  handleReset() {
    this.signalType = undefined;
    this.severity = '3';
    this.occurredOn = RiqSignalLogger.todayIso();
    this.notes = '';
    this.fieldErrors = {};
    this.errorMessage = undefined;
  }

  /**
   * Client-side validation exists to give instant feedback, not to enforce
   * anything: RIQ_AccountHealthController.logSignal re-validates every field
   * because a browser is not a security boundary.
   */
  validate() {
    const errors = {};

    if (!this.signalType) {
      errors.signalType = 'Choose the type of signal.';
    }

    const severity = Number(this.severity);

    if (!Number.isInteger(severity) || severity < 1 || severity > 5) {
      errors.severity = 'Severity must be between 1 and 5.';
    }

    if (!this.occurredOn) {
      errors.occurredOn = 'Choose the date the signal happened.';
    } else if (this.occurredOn > RiqSignalLogger.todayIso()) {
      errors.occurredOn = 'A signal cannot be dated in the future.';
    }

    this.fieldErrors = errors;
    return Object.keys(errors).length === 0;
  }

  async handleSubmit(event) {
    event.preventDefault();

    if (!this.validate()) {
      return;
    }

    this.isSaving = true;
    this.errorMessage = undefined;

    try {
      await logSignal({
        accountId: this.recordId,
        signalType: this.signalType,
        severity: Number(this.severity),
        occurredOn: this.occurredOn,
        notes: this.notes
      });

      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Signal logged',
          message: 'The health score recalculates in the background.',
          variant: 'success'
        })
      );

      this.handleReset();
      this.isScoreUpdating = true;

      // Scoring is asynchronous: the signal trigger enqueues a Queueable.
      // Showing a "score updating" state and refreshing after it settles
      // is honest; showing an instant new score would be a lie.
      // Waiting a bounded time for the background job is the point of this timer.
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      this.refreshTimer = setTimeout(() => {
        this.isScoreUpdating = false;
        this.requestScoreRefresh();
      }, SCORE_SETTLE_MS);
    } catch (error) {
      this.errorMessage = this.reduceError(error);

      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Could not log the signal',
          message: this.errorMessage,
          variant: 'error'
        })
      );
    } finally {
      this.isSaving = false;
    }
  }

  requestScoreRefresh() {
    if (!this.messageContext) {
      return;
    }

    publish(this.messageContext, SCORE_REFRESH, { accountId: this.recordId });
  }

  /* ------------------------------------------------------------- getters */

  get typeError() {
    return this.fieldErrors.signalType;
  }

  get severityError() {
    return this.fieldErrors.severity;
  }

  get dateError() {
    return this.fieldErrors.occurredOn;
  }

  get severityOptions() {
    return SEVERITY_OPTIONS;
  }

  get today() {
    return RiqSignalLogger.todayIso();
  }

  get saveDisabled() {
    return this.isSaving;
  }

  /* ------------------------------------------------------------- helpers */

  /**
   * @returns {string} Today as YYYY-MM-DD in the user's time zone, which is
   *          what lightning-input type="date" expects.
   */
  static todayIso() {
    const now = new Date();
    const local = new Date(now.getTime() - now.getTimezoneOffset() * 60000);
    return local.toISOString().slice(0, 10);
  }

  reduceError(error) {
    if (!error) {
      return 'Something went wrong.';
    }

    if (Array.isArray(error.body)) {
      return error.body.map((entry) => entry.message).join(', ');
    }

    if (error.body && error.body.message) {
      return error.body.message;
    }

    if (error.message) {
      return error.message;
    }

    return 'Something went wrong.';
  }
}
