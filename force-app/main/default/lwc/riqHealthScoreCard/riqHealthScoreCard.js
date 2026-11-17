import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, MessageContext } from 'lightning/messageService';
import SCORE_REFRESH from '@salesforce/messageChannel/RIQ_Score_Refresh__c';
import getHealthCard from '@salesforce/apex/RIQ_AccountHealthController.getHealthCard';
import recalculate from '@salesforce/apex/RIQ_AccountHealthController.recalculate';
import generateInsight from '@salesforce/apex/RIQ_AccountHealthController.generateInsight';
import {
  buildSparklinePoints,
  daysLabel,
  formatDate,
  formatDateTime,
  formatInr,
  formatInrCompact,
  formatPercent,
  gaugeDashArray,
  scoreLabel,
  statusBadgeStyle,
  statusColor,
  statusIcon,
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
  isGenerating = false;
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

  /**
   * Generates the written insight. The callout happens inside the Apex method,
   * before any DML, so the platform's "callouts precede DML" rule is respected;
   * the returned card is the written-through value, not an optimistic guess.
   */
  async handleGenerateInsight() {
    this.isGenerating = true;

    try {
      this.card = await generateInsight({ accountId: this.recordId });

      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Insight generated',
          message:
            this.card.aiSource === 'AI'
              ? 'Written by the AI model.'
              : 'Written by the built-in rules: the AI model is switched off or unavailable.',
          variant: 'success'
        })
      );
    } catch (error) {
      this.dispatchEvent(
        new ShowToastEvent({
          title: 'Could not generate an insight',
          message: this.reduceError(error),
          variant: 'error'
        })
      );
    } finally {
      this.isGenerating = false;
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
    return this.card ? statusColor(this.card.status) : statusColor('Healthy');
  }

  get statusVariant() {
    return this.card ? statusTheme(this.card.status) : 'inverse';
  }

  get statusLabel() {
    return this.card && this.card.status ? this.card.status : 'Not scored';
  }

  get statusIcon() {
    return statusIcon(this.card ? this.card.status : null);
  }

  get statusStyle() {
    return statusBadgeStyle(this.card ? this.card.status : null);
  }

  get churnDisplay() {
    return this.card ? formatPercent(this.card.churnProbability) : '—';
  }

  /** Compact on the card, with the exact rupee amount one hover away. */
  get arrDisplay() {
    return this.card ? formatInrCompact(this.card.arr) : '—';
  }

  get arrFull() {
    return this.card ? formatInr(this.card.arr) : '—';
  }

  get renewalDisplay() {
    if (!this.card || !this.card.contractEndDate) {
      return '—';
    }

    return formatDate(this.card.contractEndDate);
  }

  get lastScoredDisplay() {
    if (!this.card || !this.card.lastScored) {
      return 'Never scored';
    }

    return formatDateTime(this.card.lastScored);
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
    const end = new Date(`${this.card.contractEndDate}T00:00:00Z`);
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

  get hasInsight() {
    return !!(this.card && this.card.aiSummary);
  }

  get showGenerateButton() {
    return !!(this.card && this.card.canGenerateInsight);
  }

  /**
   * The badge is the honesty mechanism: a fallback summary must never look
   * like something the model wrote.
   */
  get insightSourceLabel() {
    if (!this.card || !this.card.aiSource) {
      return 'Not generated';
    }

    return this.card.aiSource === 'AI' ? 'AI generated' : 'Rule based';
  }

  get insightBadgeClass() {
    return this.card && this.card.aiSource === 'AI' ? 'riq-insight__badge riq-insight__badge_ai' : 'riq-insight__badge';
  }

  get insightSummary() {
    return this.card ? this.card.aiSummary : null;
  }

  get insightNextAction() {
    return this.card ? this.card.nextBestAction : null;
  }

  get insightReasons() {
    return this.card && this.card.aiRiskReasons ? this.card.aiRiskReasons : [];
  }

  get insightGeneratedDisplay() {
    if (!this.card || !this.card.aiGeneratedOn) {
      return null;
    }

    return formatDateTime(this.card.aiGeneratedOn);
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
