/**
 * Pure helpers shared by the RenewalIQ components.
 *
 * Nothing here touches the DOM, Apex or the wire service, which is the whole
 * point: every formula below (donut geometry, sparkline scaling, status colour,
 * currency formatting) is unit tested directly instead of through a rendered
 * component.
 */

const STATUS_THEME = {
  Critical: 'error',
  'At Risk': 'warning',
  Watch: 'info',
  Healthy: 'success'
};

const STATUS_COLOR = {
  Critical: '#ba0517',
  'At Risk': '#fe9339',
  Watch: '#0176d3',
  Healthy: '#2e844a'
};

const FALLBACK_COLOR = '#747474';

/**
 * @param {string} status Health status.
 * @returns {string} SLDS theme name for a badge or icon.
 */
export function statusTheme(status) {
  return STATUS_THEME[status] || 'inverse';
}

/**
 * @param {string} status Health status.
 * @returns {string} Hex colour used in SVG and chart series.
 */
export function statusColor(status) {
  return STATUS_COLOR[status] || FALLBACK_COLOR;
}

/**
 * @param {number|string} value Amount.
 * @returns {string} Whole-dollar currency, em dash when unknown.
 */
export function formatCurrency(value) {
  const amount = Number(value);

  if (value === null || value === undefined || Number.isNaN(amount)) {
    return '—';
  }

  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 0
  }).format(amount);
}

/**
 * @param {number|string} value Amount.
 * @returns {string} Compact currency such as $1.2M, for KPI tiles.
 */
export function formatCompactCurrency(value) {
  const amount = Number(value);

  if (value === null || value === undefined || Number.isNaN(amount)) {
    return '—';
  }

  const absolute = Math.abs(amount);

  if (absolute >= 1000000000) {
    return `$${(amount / 1000000000).toFixed(1)}B`;
  }

  if (absolute >= 1000000) {
    return `$${(amount / 1000000).toFixed(1)}M`;
  }

  if (absolute >= 1000) {
    return `$${Math.round(amount / 1000)}K`;
  }

  return `$${Math.round(amount)}`;
}

/**
 * @param {number|string} value Percentage.
 * @returns {string} Whole percent, em dash when unknown.
 */
export function formatPercent(value) {
  const percentage = Number(value);

  if (value === null || value === undefined || Number.isNaN(percentage)) {
    return '—';
  }

  return `${Math.round(percentage)}%`;
}

/**
 * @param {number} days Days until the contract ends.
 * @returns {string} Human label such as "12d", "Today" or "5d overdue".
 */
export function daysLabel(days) {
  if (days === null || days === undefined || Number.isNaN(Number(days))) {
    return '—';
  }

  const value = Number(days);

  if (value < 0) {
    return `${Math.abs(value)}d overdue`;
  }

  if (value === 0) {
    return 'Today';
  }

  return `${value}d`;
}

/**
 * Turns status slices into stroke-dasharray geometry for an SVG donut.
 *
 * A circle's circumference is the full "100%"; each segment claims a slice of it
 * by dash length and is pushed forward with a negative offset.
 *
 * @param {Array<{label: string, count: number}>} slices Donut data.
 * @param {number} radius Circle radius in the SVG user units.
 * @returns {Array<object>} Segments ready for template iteration.
 */
export function buildDonutSegments(slices, radius = 54) {
  const safeSlices = slices || [];
  const circumference = 2 * Math.PI * radius;
  const total = safeSlices.reduce((sum, slice) => sum + (Number(slice.count) || 0), 0);
  const segments = [];
  let offset = 0;

  safeSlices.forEach((slice) => {
    const count = Number(slice.count) || 0;

    if (count <= 0 || total === 0) {
      return;
    }

    const length = (count / total) * circumference;

    const color = statusColor(slice.label);

    segments.push({
      label: slice.label,
      count,
      color,
      swatchStyle: `background-color: ${color}`,
      dashArray: `${length} ${circumference - length}`,
      dashOffset: offset === 0 ? 0 : -offset,
      percentage: Math.round((count / total) * 1000) / 10
    });

    offset += length;
  });

  return segments;
}

/**
 * Scales a series into SVG polyline points.
 *
 * @param {Array<number>} values Series, oldest first.
 * @param {number} width Drawing width.
 * @param {number} height Drawing height.
 * @returns {string} Space separated "x,y" pairs; empty for no data.
 */
export function buildSparklinePoints(values, width = 240, height = 56) {
  const numbers = (values || []).map(Number).filter((value) => Number.isFinite(value));

  if (numbers.length === 0) {
    return '';
  }

  if (numbers.length === 1) {
    return `0,${height / 2} ${width},${height / 2}`;
  }

  const maximum = Math.max(...numbers);
  const minimum = Math.min(...numbers);
  const span = maximum - minimum || 1;
  const step = width / (numbers.length - 1);

  return numbers
    .map((value, index) => {
      const x = Math.round(index * step * 100) / 100;
      const y = Math.round((height - ((value - minimum) / span) * height) * 100) / 100;
      return `${x},${y}`;
    })
    .join(' ');
}

/**
 * @param {number} score Score 0..100.
 * @param {number} radius Gauge radius in SVG user units.
 * @returns {string} stroke-dasharray for the filled portion of the ring.
 */
export function gaugeDashArray(score, radius = 52) {
  const circumference = 2 * Math.PI * radius;
  const clamped = Math.max(0, Math.min(100, Number(score) || 0));
  const filled = (clamped / 100) * circumference;

  return `${filled} ${circumference - filled}`;
}

/**
 * @param {number} score Score 0..100.
 * @returns {string} Accessible description of the gauge.
 */
export function scoreLabel(score) {
  if (score === null || score === undefined) {
    return 'Not scored';
  }

  return `${Math.round(Number(score))} out of 100`;
}
