import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, MessageContext } from 'lightning/messageService';
import SCORE_REFRESH from '@salesforce/messageChannel/RIQ_Score_Refresh__c';
import getHealthCard from '@salesforce/apex/RIQ_AccountHealthController.getHealthCard';
import recalculate from '@salesforce/apex/RIQ_AccountHealthController.recalculate';
import {
  buildSparklinePoints,
  daysLabel,
  formatCompactCurrency,
  formatPercent,
  gaugeDashArray,
  scoreLabel,
  statusTheme
} from 'c/riqUtils';

export default class RiqHealthScoreCard extends LightningElement {
  /** Account record page context. */
  @api recordId;

  card;
  messageContext;
  errorMessage;
  isLoading = true;
  isRecalculating = false;
  wiredResult;
  subscription;

  /**
   * Subscribing from the wire handler instead of connectedCallback matters:
   * the message context can resolve after the element connects, and a
   * subscription made with an undefined context would never fire.
   */
  @wire(MessageContext)
  wiredMessageContext(context) {
    if (!context) {
      return;
    }

    this.messageContext = context;
    this.subscribeToRefresh();
  }

  /**
   * The card is a pure read, so it is wired and cacheable. After a mutation
   * (recalculate, or a signal logged by riqSignalLogger) the cache is cleared
   * with refreshApex rather than by re-querying blindly.
   */
  @wire(getHealthCard, { accountId: '$recordId' })
  wiredCard(result) {
    this.wiredResult = result;
    const { data, error } = result;

    if (data) {
      this.card = data;
      this.errorMessage = undefined;
    } else if (error) {
      this.errorMessage = this.reduceError(error);
    }

    this.isLoading = false;
  }

  disconnectedCallback() {
    if (this.subscription) {
      unsubscribe(this.subscription);
      this.subscription = undefined;
    }
  }

  /** The signal logger asks the card to refresh once scoring has had time to run. */
  subscribeToRefresh() {
    if (this.subscription || !this.messageContext) {
      return;
    }

    this.subscription = subscribe(this.messageContext, SCORE_REFRESH, (message) => {
      if (!message || !this.recordId || message.accountId === this.recordId) {
        this.refresh();
      }
    });
  }

  async refresh() {
    if (!this.wiredResult) {
      return;
    }

    try {
      await refreshApex(this.wiredResult);
    } catch (error) {
      this.errorMessage = this.reduceError(error);
    }
  }

  async handleRecalculate() {
    this.isRecalculating = true;

    try {
      // Non-cacheable on purpose: this mutates the score, and the method
      // returns the fresh card so the new number renders immediately.
      this.card = await recalculate({ accountId: this.recordId });

      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Health score recalculated',
          message: `Score ${this.card.score} · ${this.card.status}`,
          variant: 'success'
        })
      );
    } catch (error) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Could not recalculate',
          message: this.reduceError(error),
          variant: 'error'
        })
      );
    } finally {
      this.isRecalculating = false;
    }

    await this.refresh();
  }

  /* ------------------------------------------------------------ getters */

  get hasCard() {
    return !!this.card;
  }

  get scoreDisplay() {
    return this.card && this.card.score !== null && this.card.score !== undefined ? `${this.card.score}` : '—';
  }

  get gaugeLabel() {
    return this.card ? scoreLabel(this.card.score) : 'Not scored';
  }

  get gaugeDash() {
    return this.card ? gaugeDashArray(this.card.score, 52) : gaugeDashArray(0, 52);
  }

  get gaugeColor() {
    const status = this.card ? this.card.status : null;

    if (status === 'Critical') {
      return '#ba0517';
    }

    if (status === 'At Risk') {
      return '#fe9339';
    }

    if (status === 'Watch') {
      return '#0176d3';
    }

    return '#2e844a';
  }

  get statusVariant() {
    return this.card ? statusTheme(this.card.status) : 'inverse';
  }

  get statusLabel() {
    return this.card && this.card.status ? this.card.status : 'Not scored';
  }

  get statusIcon() {
    const status = this.card ? this.card.status : null;

    if (status === 'Critical' || status === 'At Risk') {
      return 'utility:warning';
    }

    if (status === 'Watch') {
      return 'utility:info';
    }

    return 'utility:success';
  }

  get churnDisplay() {
    return this.card ? formatPercent(this.card.churnProbability) : '—';
  }

  get arrDisplay() {
    return this.card ? formatCompactCurrency(this.card.arr) : '—';
  }

  get renewalDisplay() {
    if (!this.card || !this.card.contractEndDate) {
      return '—';
    }

    return this.card.contractEndDate;
  }

  get lastScoredDisplay() {
    if (!this.card || !this.card.lastScored) {
      return 'Never scored';
    }

    return new Intl.DateTimeFormat('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit'
    }).format(new Date(this.card.lastScored));
  }

  get drivers() {
    if (!this.card || !this.card.drivers) {
      return [];
    }

    return this.card.drivers.map((driver, index) => ({
      key: `${driver.signalType}-${index}`,
      signalType: driver.signalType || 'Signal',
      severity: driver.severity === null || driver.severity === undefined ? '' : `severity ${driver.severity}`,
      points:
        driver.points === null || driver.points === undefined
          ? ''
          : `${driver.points > 0 ? '−' : '+'}${Math.abs(Math.round(driver.points))} pts`,
      explanation: driver.explanation || ''
    }));
  }

  get hasDrivers() {
    return this.drivers.length > 0;
  }

  get hasHistory() {
    return !!(this.card && this.card.history && this.card.history.length > 1);
  }

  get sparklinePoints() {
    if (!this.card || !this.card.history) {
      return '';
    }

    return buildSparklinePoints(
      this.card.history.map((point) => point.score),
      240,
      56
    );
  }

  get historySummary() {
    if (!this.card || !this.card.history || this.card.history.length === 0) {
      return 'No history yet';
    }

    const first = this.card.history[0];
    const last = this.card.history[this.card.history.length - 1];
    const delta = (last.score || 0) - (first.score || 0);
    const sign = delta > 0 ? '+' : '';

    return `${this.card.history.length} points · ${sign}${delta} over the window`;
  }

  get daysToRenewalDisplay() {
    if (!this.card || !this.card.contractEndDate) {
      return '—';
    }

    const today = new Date();
    const end = new Date(this.card.contractEndDate);
    const days = Math.round((end - today) / (1000 * 60 * 60 * 24));

    return daysLabel(days);
  }

  get canRecalculate() {
    return !!(this.card && this.card.canRecalculate);
  }

  get recalculationHint() {
    return this.canRecalculate
      ? 'Re-scores this account from its current signals.'
      : 'Your permission set does not allow recalculating scores.';
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
