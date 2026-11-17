import { LightningElement } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe } from 'lightning/empApi';
import CHARTJS from '@salesforce/resourceUrl/chartjs';
import getKpis from '@salesforce/apex/RIQ_DashboardController.getKpis';
import getStatusDistribution from '@salesforce/apex/RIQ_DashboardController.getStatusDistribution';
import getAtRiskAccounts from '@salesforce/apex/RIQ_DashboardController.getAtRiskAccounts';
import getRowCount from '@salesforce/apex/RIQ_DashboardController.getRowCount';
import getOwners from '@salesforce/apex/RIQ_DashboardController.getOwners';
import recalculate from '@salesforce/apex/RIQ_AccountHealthController.recalculate';
import {
  buildDonutSegments,
  daysLabel,
  formatDateTime,
  formatInr,
  formatInrCompact,
  formatPercent,
  statusBadgeStyle,
  statusColor,
  statusIcon
} from 'c/riqUtils';

/** Platform event channel published by the scoring engine. */
const EVENT_CHANNEL = '/event/RIQ_Health_Status_Change__e';
/** Rows fetched for the table; the Apex layer clamps to 200. */
const MAX_ROWS = 100;
/** Column key to server sort key. */
const SORT_KEY_BY_COLUMN = {
  account: 'name',
  owner: 'owner',
  score: 'score',
  status: 'status',
  churn: 'churn',
  arr: 'arr',
  renewal: 'renewal'
};
/** Plain-language name of each sortable field, used in the sort summary. */
const SORT_LABEL = {
  name: 'account name',
  owner: 'owner',
  score: 'health score',
  status: 'status',
  churn: 'churn risk',
  arr: 'ARR',
  renewal: 'renewal date'
};

export default class RiqCommandCenter extends LightningElement {
  kpis;
  slices = [];
  segments = [];
  rows = [];
  rowCount;
  owners = [];
  isLoading = true;
  errorMessage;

  ownerId = '';
  statusFilter = 'All';
  windowDays = '90';
  sortBy = 'score';
  sortDirection = 'asc';

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
    const windowDays = Number(this.windowDays);

    try {
      const [kpis, slices, rows, rowCount] = await Promise.all([
        getKpis({ ownerId: scope, renewalWindowDays: windowDays }),
        getStatusDistribution({ ownerId: scope }),
        getAtRiskAccounts({
          statusFilter: this.statusFilter,
          ownerId: scope,
          renewalWindowDays: windowDays,
          sortBy: this.sortBy,
          sortDirection: this.sortDirection,
          maxRows: MAX_ROWS
        }),
        getRowCount({
          statusFilter: this.statusFilter,
          ownerId: scope,
          renewalWindowDays: windowDays
        })
      ]);

      this.kpis = kpis;
      this.slices = slices;
      this.segments = buildDonutSegments(slices, 54);
      this.rowCount = rowCount;
      this.rows = (rows || []).map((row) => ({
        ...row,
        scoreDisplay: row.score === null || row.score === undefined ? '—' : `${row.score}`,
        churnDisplay: formatPercent(row.churnProbability),
        arrDisplay: formatInrCompact(row.arr),
        arrFull: formatInr(row.arr),
        renewalDisplay: daysLabel(row.daysToRenewal),
        lastScoredDisplay: row.lastScored ? formatDateTime(row.lastScored) : 'Never scored',
        statusLabel: row.status || 'Unscored',
        statusIcon: statusIcon(row.status),
        statusStyle: statusBadgeStyle(row.status),
        recalculateLabel: `Recalculate the score for ${row.name}`
      }));

      if (this.chartAvailable) {
        this.drawChart();
      }
    } catch (error) {
      this.errorMessage = this.reduceError(error);
      this.rows = [];
      this.segments = [];
      this.rowCount = 0;
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

  handleSortClick(event) {
    const column = event.currentTarget.dataset.key;
    const sortKey = SORT_KEY_BY_COLUMN[column];

    if (!sortKey) {
      return;
    }

    this.sortDirection = this.sortBy === sortKey && this.sortDirection === 'asc' ? 'desc' : 'asc';
    this.sortBy = sortKey;
    this.loadAll();
  }

  handleClearFilters() {
    this.ownerId = '';
    this.statusFilter = 'All';
    this.windowDays = '90';
    this.sortBy = 'score';
    this.sortDirection = 'asc';
    this.loadAll();
  }

  async handleRecalculate(event) {
    const accountId = event.currentTarget.dataset.id;
    const accountName = event.currentTarget.dataset.name;

    if (!accountId) {
      return;
    }

    try {
      const card = await recalculate({ accountId });

      this.dispatchEvent(
        new ShowToastEvent({
          title: `Recalculated ${card.accountName || accountName}`,
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
      { key: 'account', label: 'Account', sortKey: 'name', width: '16rem' },
      { key: 'owner', label: 'Owner', sortKey: 'owner', width: '10rem' },
      { key: 'score', label: 'Health score', sortKey: 'score', width: '8rem', numeric: true },
      { key: 'status', label: 'Status', sortKey: 'status', width: '9rem' },
      { key: 'churn', label: 'Churn risk', sortKey: 'churn', width: '7rem', numeric: true },
      { key: 'arr', label: 'ARR (INR)', sortKey: 'arr', width: '9rem', numeric: true },
      { key: 'renewal', label: 'Renewal', sortKey: 'renewal', width: '8rem' },
      { key: 'lastScored', label: 'Last scored', width: '12rem' },
      { key: 'actions', label: 'Actions', width: '5rem' }
    ].map((column) => ({
      ...column,
      sortable: !!column.sortKey,
      style: `width: ${column.width};`,
      sortTitle: `Sort by ${column.label}`,
      headerClass: column.numeric ? 'riq-th riq-th_num' : 'riq-th',
      ariaSort:
        column.sortKey && this.sortBy === column.sortKey
          ? this.sortDirection === 'asc'
            ? 'ascending'
            : 'descending'
          : 'none'
    }));
  }

  get kpiTiles() {
    if (!this.kpis) {
      return [];
    }

    return [
      {
        key: 'arr',
        label: 'Total ARR',
        value: formatInrCompact(this.kpis.totalArr),
        title: `${formatInr(this.kpis.totalArr)} total annual recurring revenue in scope.`,
        hint: `${this.kpis.accountCount} accounts in scope`
      },
      {
        key: 'risk',
        label: 'ARR at risk',
        value: formatInrCompact(this.kpis.arrAtRisk),
        title: `${formatInr(
          this.kpis.arrAtRisk
        )} — Yearly revenue from customers rated At Risk or Critical`,
        hint: 'At Risk and Critical customers'
      },
      {
        key: 'critical',
        label: 'Critical accounts',
        value: `${this.kpis.criticalCount}`,
        title: `${this.kpis.criticalCount} customers are rated Critical.`,
        hint: 'need executive attention'
      },
      {
        key: 'score',
        label: 'Average score',
        value:
          this.kpis.averageScore === null || this.kpis.averageScore === undefined
            ? '—'
            : `${this.kpis.averageScore}`,
        title: 'Average health score of the accounts in scope, out of 100.',
        hint: 'out of 100'
      },
      {
        key: 'renewals',
        label: 'Renewals due',
        value: `${this.kpis.renewalsDue}`,
        title: `${this.kpis.renewalsDue} contracts end in the next ${this.kpis.renewalWindowDays} days.`,
        hint: `next ${this.kpis.renewalWindowDays} days`
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

  /** "Showing 7 of 17" — the count is the filter total, not the row limit. */
  get visibleCountText() {
    const shown = this.rows.length;
    const total = this.rowCount === null || this.rowCount === undefined ? shown : this.rowCount;
    return `Showing ${shown} of ${total}`;
  }

  get sortSummary() {
    const label = SORT_LABEL[this.sortBy] || 'health score';

    if (this.sortBy === 'name' || this.sortBy === 'owner') {
      return this.sortDirection === 'asc' ? 'A to Z' : 'Z to A';
    }

    return this.sortDirection === 'asc' ? `Lowest ${label} first` : `Highest ${label} first`;
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
