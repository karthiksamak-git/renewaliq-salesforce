/**
 * Pure helpers shared by the RenewalIQ components.
 *
 * Nothing here touches the DOM, Apex or the wire service, which is the whole
 * point: every formula below (donut geometry, sparkline scaling, status colour,
 * Indian currency formatting) is unit tested directly instead of through a
 * rendered component.
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

const STATUS_ICON = {
  Critical: 'utility:warning',
  'At Risk': 'utility:warning',
  Watch: 'utility:info',
  Healthy: 'utility:success'
};

const FALLBACK_COLOR = '#747474';

/** One lakh is 100,000; one crore is 10,000,000. */
const LAKH = 100000;
const CRORE = 10000000;

const INR_WHOLE = new Intl.NumberFormat('en-IN', {
  style: 'currency',
  currency: 'INR',
  maximumFractionDigits: 0
});

const IST_DATE = new Intl.DateTimeFormat('en-IN', {
  day: '2-digit',
  month: 'short',
  year: 'numeric',
  timeZone: 'Asia/Kolkata'
});

const IST_DATE_TIME = new Intl.DateTimeFormat('en-IN', {
  day: '2-digit',
  month: 'short',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  timeZone: 'Asia/Kolkata',
  timeZoneName: 'short'
});

/**
 * @param {string} status Health status.
 * @returns {string} SLDS theme name for a badge or icon.
 */
export function statusTheme(status) {
  return STATUS_THEME[status] || 'inverse';
}

/**
 * @param {string} status Health status.
 * @returns {string} Hex colour used in SVG, chart series and status badges.
 */
export function statusColor(status) {
  return STATUS_COLOR[status] || FALLBACK_COLOR;
}

/**
 * Status is never communicated by colour alone: the badge also carries an icon
 * and the written status, so it survives colour blindness and greyscale print.
 *
 * @param {string} status Health status.
 * @returns {string} SLDS icon name for the status.
 */
export function statusIcon(status) {
  return STATUS_ICON[status] || 'utility:help';
}

/**
 * @param {string} status Health status.
 * @returns {string} Inline style for a bordered status badge in the donut colour.
 */
export function statusBadgeStyle(status) {
  const color = statusColor(status);
  return `color: ${color}; border-color: ${color};`;
}

/**
 * @param {number|string} value Amount in Indian Rupees.
 * @returns {boolean} True when the value is a usable number.
 */
function isAmount(value) {
  if (value === null || value === undefined || value === '') {
    return false;
  }

  return Number.isFinite(Number(value));
}

/**
 * @param {number} amount Number to render.
 * @returns {string} Integer formatted with Indian digit grouping.
 */
function groupIndian(amount) {
  const rounded = Math.round(amount);
  const digits = String(Math.abs(rounded));

  if (digits.length <= 3) {
    return (rounded < 0 ? '-' : '') + digits;
  }

  const head = digits.slice(0, digits.length - 3);
  const tail = digits.slice(digits.length - 3);
  const groups = [];

  for (let end = head.length; end > 0; end -= 2) {
    groups.unshift(head.slice(Math.max(0, end - 2), end));
  }

  return (rounded < 0 ? '-' : '') + `${groups.join(',')},${tail}`;
}

/**
 * @param {number} amount Amount in Indian Rupees.
 * @returns {string} Full amount with the rupee sign and Indian grouping.
 */
export function formatInr(value) {
  if (!isAmount(value)) {
    return '—';
  }

  const amount = Number(value);

  // Intl handles the rupee sign and Indian grouping; the fallback keeps the
  // output correct in an environment whose ICU data is trimmed.
  if (typeof INR_WHOLE.format === 'function') {
    const formatted = INR_WHOLE.format(Math.round(amount));

    if (formatted.indexOf('₹') !== -1) {
      return formatted;
    }
  }

  return `${amount < 0 ? '-₹' : '₹'}${groupIndian(Math.abs(amount))}`;
}

/**
 * @param {number} number Short number to render.
 * @param {number} digits Maximum fraction digits.
 * @returns {string} Truncated number with trailing zeros removed.
 */
function shortNumber(number, digits) {
  const factor = 10 ** digits;
  const truncated = Math.trunc(number * factor) / factor;

  return truncated.toFixed(digits).replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1');
}

/**
 * Compact Indian money for KPI tiles and table cells.
 *
 * Below one lakh the full amount is clearer than a unit, one lakh to under one
 * crore reads as "12.5 L", and one crore and above reads as "4.25 Cr". Values
 * are truncated rather than rounded up, so 99,99,999 never displays as "100 L".
 *
 * @param {number|string} value Amount in Indian Rupees.
 * @returns {string} Compact amount, em dash when unknown.
 */
export function formatInrCompact(value) {
  if (!isAmount(value)) {
    return '—';
  }

  const amount = Number(value);
  const absolute = Math.abs(amount);
  const sign = amount < 0 ? '-' : '';

  if (absolute >= CRORE) {
    return `${sign}₹${shortNumber(absolute / CRORE, 2)} Cr`;
  }

  if (absolute >= LAKH) {
    return `${sign}₹${shortNumber(absolute / LAKH, 1)} L`;
  }

  return formatInr(amount);
}

/**
 * @param {number|string} value Percentage.
 * @returns {string} Whole percent, em dash when unknown.
 */
export function formatPercent(value) {
  const percentage = Number(value);

  if (value === null || value === undefined || value === '' || Number.isNaN(percentage)) {
    return '—';
  }

  return `${Math.round(percentage)}%`;
}

/**
 * @param {string} value ISO date such as 2026-11-17.
 * @returns {string} Readable date in the Indian format, em dash when unknown.
 */
export function formatDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value || ''));

  if (!match) {
    return '—';
  }

  // Noon UTC keeps a date-only value on the same calendar day in IST.
  return IST_DATE.format(new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12)));
}

/**
 * @param {string} value ISO timestamp.
 * @returns {string} Date and time in IST, em dash when unknown.
 */
export function formatDateTime(value) {
  if (!value) {
    return '—';
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return '—';
  }

  return IST_DATE_TIME.format(date);
}

/**
 * @param {number} days Days until the contract ends.
 * @returns {string} Human label such as "12 days", "Today" or "5 days overdue".
 */
export function daysLabel(days) {
  if (days === null || days === undefined || Number.isNaN(Number(days))) {
    return '—';
  }

  const value = Number(days);

  if (value < 0) {
    const overdue = Math.abs(value);
    return `${overdue} ${overdue === 1 ? 'day' : 'days'} overdue`;
  }

  if (value === 0) {
    return 'Today';
  }

  return `${value} ${value === 1 ? 'day' : 'days'}`;
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
      icon: statusIcon(slice.label),
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
