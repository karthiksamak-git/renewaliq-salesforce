/**
 * @description Formats money for the Indian market: the rupee sign, Indian digit
 * grouping (last three digits, then groups of two) and the lakh/crore shorthand
 * Indian readers expect.
 *
 * Apex has no Intl, so this is deliberately hand-written and pure: no queries,
 * no DML, no dependencies. The Lightning components have their own copy in
 * riqUtils because a component cannot call Apex just to format a number; both
 * implementations are covered by their own boundary tests so they cannot drift
 * unnoticed.
 */
public with sharing class RIQ_CurrencyFormatter {
    /** Indian rupee sign. */
    public static final String RUPEE = '₹';

    /** One lakh. */
    private static final Decimal LAKH = 100000;

    /** One crore. */
    private static final Decimal CRORE = 10000000;

    /**
     * @description The full amount, for example ₹12,50,000.
     * @param value Amount, may be null or fractional.
     * @return Grouped amount, or an em dash when the value is null.
     */
    public static String formatInr(Decimal value) {
        if (value == null) {
            return '—';
        }

        Decimal rounded = value.setScale(0, RoundingMode.HALF_UP);
        String digits = rounded.abs().toPlainString();
        String sign = rounded < 0 ? '-' : '';

        return sign + RUPEE + groupIndian(digits);
    }

    /**
     * @description The short amount used in prose: below one lakh the full
     * amount, one lakh to under one crore as "12.5 L", one crore and above as
     * "4.25 Cr". Values are truncated so 99,99,999 never reads as "100 L".
     * @param value Amount, may be null.
     * @return Compact amount, or an em dash when the value is null.
     */
    public static String formatInrCompact(Decimal value) {
        if (value == null) {
            return '—';
        }

        String sign = value < 0 ? '-' : '';
        Decimal absolute = value.abs();

        if (absolute >= CRORE) {
            Decimal crores = absolute.divide(CRORE, 2, RoundingMode.DOWN);
            return sign + RUPEE + trimZeros(crores.toPlainString()) + ' Cr';
        }

        if (absolute >= LAKH) {
            Decimal lakhs = absolute.divide(LAKH, 1, RoundingMode.DOWN);
            return sign + RUPEE + trimZeros(lakhs.toPlainString()) + ' L';
        }

        return formatInr(value);
    }

    /**
     * @param digits Unsigned digits, no separators.
     * @return The same digits with Indian grouping.
     */
    private static String groupIndian(String digits) {
        if (digits.length() <= 3) {
            return digits;
        }

        String tail = digits.substring(digits.length() - 3);
        String head = digits.substring(0, digits.length() - 3);
        List<String> groups = new List<String>();

        // Collect the groups right to left, then write them out left to right:
        // Apex refuses to insert at index 0 of an empty list.
        while (head.length() > 2) {
            groups.add(head.substring(head.length() - 2));
            head = head.substring(0, head.length() - 2);
        }

        if (head.length() > 0) {
            groups.add(head);
        }

        String grouped = '';
        for (Integer i = groups.size() - 1; i >= 0; i--) {
            grouped += (grouped.length() == 0 ? '' : ',') + groups[i];
        }

        return grouped + ',' + tail;
    }

    /**
     * @param text Plain decimal string such as 12.50.
     * @return The same string without trailing fractional zeros.
     */
    private static String trimZeros(String text) {
        if (!text.contains('.')) {
            return text;
        }

        String trimmed = text;

        while (trimmed.endsWith('0')) {
            trimmed = trimmed.substring(0, trimmed.length() - 1);
        }

        return trimmed.endsWith('.') ? trimmed.substring(0, trimmed.length() - 1) : trimmed;
    }
}
