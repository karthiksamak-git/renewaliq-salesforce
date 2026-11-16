import { LightningElement } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe } from 'lightning/empApi';
import CHARTJS from '@salesforce/resourceUrl/chartjs';
import getKpis from '@salesforce/apex/RIQ_DashboardController.getKpis';
import getStatusDistribution from '@salesforce/apex/RIQ_DashboardController.getStatusDistribution';
import getAtRiskAccounts from '@salesforce/apex/RIQ_DashboardController.getAtRiskAccounts';
import getOwners from '@salesforce/apex/RIQ_DashboardController.getOwners';
import recalculate from '@salesforce/apex/RIQ_AccountHealthController.recalculate';
import { buildDonutSegments, formatCompactCurrency, formatPercent, statusColor, daysLabel } from 'c/riqUtils';

/** Platform event channel published by the scoring engine. */
const EVENT_CHANNEL = '/event/RIQ_Health_Status_Change__e';
/** Rows fetched for the drill-down table; the Apex layer clamps to 200. */
const MAX_ROWS = 100;
/** Datatable column to server sort key. */
const SORT_KEY_BY_COLUMN = {
  recordUrl: 'name',
  ownerName: 'owner',
  status: 'status',
  score: 'score',
  churnDisplay: 'churn',
  arrDisplay: 'arr',
  renewalDisplay: 'renewal'
};
/** Server sort key back to datatable column, so the arrow lands on the right header. */
const COLUMN_BY_SORT_KEY = {
  name: 'recordUrl',
  owner: 'ownerName',
  status: 'status',
  score: 'score',
  churn: 'churnDisplay',
  arr: 'arrDisplay',
  renewal: 'renewalDisplay'
};

export default class RiqCommandCenter extends LightningElement {
  kpis;
  slices = [];
  segments = [];
  rows = [];
  owners = [];
  isLoading = true;
  errorMessage;

  ownerId = '';
  statusFilter = 'All';
  windowDays = '90';
  sortBy = 'score';
  sortDirection = 'desc';

  chart;
  chartAvailable = false;
  chartUnavailable = false;
  chartAttempted = false;
  renderedSignature;
  subscription;

  connectedCallback() {
    this.loadOwners();
    this.loadAll();
    this.subscribeToEvents();
  }

  disconnectedCallback() {
    if (this.subscription) {
      unsubscribe(this.subscription, () => {});
      this.subscription = undefined;
    }
  }

  renderedCallback() {
    if (!this.chartAttempted) {
      this.chartAttempted = true;
      this.loadChartLibrary();
      return;
    }

    if (this.chartAvailable && this.slices.length > 0) {
      this.drawChart();
    }
  }

  /* ------------------------------------------------------------------ data */

  async loadOwners() {
    try {
      this.owners = await getOwners();
    } catch {
      // The owner filter is a convenience; the dashboard still works
      // without it, so this failure is not surfaced as a page error.
      this.owners = [];
    }
  }

  async loadAll() {
    this.isLoading = true;
    this.errorMessage = undefined;

    const scope = this.ownerId || null;

    try {
      const [kpis, slices, rows] = await Promise.all([
        getKpis({ ownerId: scope, renewalWindowDays: Number(this.windowDays) }),
        getStatusDistribution({ ownerId: scope }),
        getAtRiskAccounts({
          statusFilter: this.statusFilter,
          ownerId: scope,
          renewalWindowDays: Number(this.windowDays),
          sortBy: this.sortBy,
          sortDirection: this.sortDirection,
          maxRows: MAX_ROWS
        })
      ]);

      this.kpis = kpis;
      this.slices = slices;
      this.segments = buildDonutSegments(slices, 54);
      this.rows = (rows || []).map((row) => ({
        ...row,
        churnDisplay: formatPercent(row.churnProbability),
        arrDisplay: formatCompactCurrency(row.arr),
        renewalDisplay: daysLabel(row.daysToRenewal)
      }));

      if (this.chartAvailable) {
        this.drawChart();
      }
    } catch (error) {
      this.errorMessage = this.reduceError(error);
      this.rows = [];
      this.segments = [];
    } finally {
      this.isLoading = false;
    }
  }

  /* ----------------------------------------------------------------- chart */

  loadChartLibrary() {
    loadScript(this, CHARTJS)
      .then(() => {
        if (typeof window !== 'undefined' && typeof window.Chart === 'function') {
          this.chartAvailable = true;
          this.drawChart();
        } else {
          // Lightning Web Security can hide a script's globals; the
          // SVG donut is the deliberate fallback.
          this.chartUnavailable = true;
        }
      })
      .catch(() => {
        this.chartUnavailable = true;
      });
  }

  drawChart() {
    const canvas = this.template.querySelector('canvas.riq-donut');

    if (!canvas || typeof window === 'undefined' || typeof window.Chart !== 'function') {
      return;
    }

    const signature = JSON.stringify(this.slices.map((slice) => [slice.label, slice.count]));

    if (signature === this.renderedSignature) {
      return;
    }

    this.renderedSignature = signature;

    if (this.chart) {
      this.chart.destroy();
      this.chart = undefined;
    }

    this.chart = new window.Chart(canvas, {
      type: 'doughnut',
      data: {
        labels: this.slices.map((slice) => slice.label),
        datasets: [
          {
            data: this.slices.map((slice) => slice.count),
            backgroundColor: this.slices.map((slice) => statusColor(slice.label)),
            borderWidth: 0
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        cutout: '62%',
        plugins: {
          legend: { display: false }
        }
      }
    });
  }

  /* ------------------------------------------------------- live updates */

  subscribeToEvents() {
    subscribe(EVENT_CHANNEL, -1, (event) => this.handlePlatformEvent(event))
      .then((response) => {
        this.subscription = response;
      })
      .catch(() => {
        // Live updates are an enhancement: the table is still correct on
        // load and after a manual refresh, so a refused subscription is
        // not worth an error banner.
      });
  }

  handlePlatformEvent(event) {
    const payload = event && event.data ? event.data.payload : null;

    if (!payload) {
      return;
    }

    const from = payload.OldStatus__c || 'unscored';
    const to = payload.NewStatus__c || 'unknown';
    const score = payload.Score__c === undefined ? '—' : payload.Score__c;

    this.dispatchEvent(
      new ShowToastEvent({
        title: 'Health status changed',
        message: `${from} → ${to} · score ${score}`,
        variant: 'info'
      })
    );

    this.loadAll();
  }

  /* ----------------------------------------------------------- handlers */

  handleOwnerChange(event) {
    this.ownerId = event.detail.value;
    this.loadAll();
  }

  handleStatusChange(event) {
    this.statusFilter = event.detail.value;
    this.loadAll();
  }

  handleWindowChange(event) {
    this.windowDays = event.detail.value;
    this.loadAll();
  }

  handleSort(event) {
    const { fieldName, sortDirection } = event.detail;

    this.sortBy = SORT_KEY_BY_COLUMN[fieldName] || 'score';
    this.sortDirection = sortDirection;
    this.loadAll();
  }

  async handleRowAction(event) {
    const action = event.detail.action;
    const row = event.detail.row;

    if (!action || action.name !== 'recalculate') {
      return;
    }

    try {
      const card = await recalculate({ accountId: row.accountId });

      this.dispatchEvent(
        new ShowToastEvent({
          title: `Recalculated ${card.accountName}`,
          message: `Score ${card.score} · ${card.status}`,
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
    }

    await this.loadAll();
  }

  handleRetry() {
    this.loadAll();
  }

  /* ------------------------------------------------------------ getters */

  get columns() {
    return [
      {
        label: 'Account',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' },
        sortable: true,
        initialWidth: 220
      },
      { label: 'Owner', fieldName: 'ownerName', type: 'text', sortable: true },
      { label: 'Status', fieldName: 'status', type: 'text', sortable: true, initialWidth: 110 },
      { label: 'Score', fieldName: 'score', type: 'number', sortable: true, initialWidth: 80 },
      { label: 'Churn', fieldName: 'churnDisplay', type: 'text', sortable: true, initialWidth: 90 },
      { label: 'ARR', fieldName: 'arrDisplay', type: 'text', sortable: true, initialWidth: 100 },
      { label: 'Renewal', fieldName: 'renewalDisplay', type: 'text', sortable: true, initialWidth: 120 },
      {
        type: 'action',
        typeAttributes: {
          rowActions: [{ label: 'Recalculate', name: 'recalculate' }]
        }
      }
    ];
  }

  get sortedByColumn() {
    return COLUMN_BY_SORT_KEY[this.sortBy] || 'score';
  }

  get kpiTiles() {
    if (!this.kpis) {
      return [];
    }

    return [
      {
        key: 'arr',
        label: 'Total ARR',
        value: formatCompactCurrency(this.kpis.totalArr),
        hint: `${this.kpis.accountCount} accounts in scope`,
        boxClass: 'slds-box slds-theme_default riq-kpi'
      },
      {
        key: 'risk',
        label: 'ARR at risk',
        value: formatCompactCurrency(this.kpis.arrAtRisk),
        hint: `${this.kpis.criticalCount} critical`,
        boxClass: 'slds-box slds-theme_default riq-kpi riq-kpi_risk'
      },
      {
        key: 'score',
        label: 'Average score',
        value:
          this.kpis.averageScore === null || this.kpis.averageScore === undefined ? '—' : `${this.kpis.averageScore}`,
        hint: 'out of 100',
        boxClass: 'slds-box slds-theme_default riq-kpi'
      },
      {
        key: 'renewals',
        label: 'Renewals due',
        value: `${this.kpis.renewalsDue}`,
        hint: `next ${this.kpis.renewalWindowDays} days`,
        boxClass: 'slds-box slds-theme_default riq-kpi'
      }
    ];
  }

  get totalAccounts() {
    return this.kpis ? this.kpis.accountCount : 0;
  }

  get ownerOptions() {
    return [
      { label: 'All owners', value: '' },
      ...this.owners.map((owner) => ({ label: owner.ownerName, value: owner.ownerId }))
    ];
  }

  get statusOptions() {
    return [
      { label: 'At Risk + Critical', value: 'All' },
      { label: 'Critical', value: 'Critical' },
      { label: 'At Risk', value: 'At Risk' },
      { label: 'Watch', value: 'Watch' },
      { label: 'Healthy', value: 'Healthy' }
    ];
  }

  get windowOptions() {
    return [
      { label: 'Next 30 days', value: '30' },
      { label: 'Next 60 days', value: '60' },
      { label: 'Next 90 days', value: '90' },
      { label: 'Next 120 days', value: '120' },
      { label: 'Next 12 months', value: '365' }
    ];
  }

  get hasRows() {
    return this.rows.length > 0;
  }

  get showEmpty() {
    return !this.isLoading && !this.errorMessage && this.rows.length === 0;
  }

  get showTable() {
    return !this.isLoading && !this.errorMessage && this.rows.length > 0;
  }

  /* ------------------------------------------------------------- helpers */

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
