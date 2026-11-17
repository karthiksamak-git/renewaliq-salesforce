/**
 * @description Boundary tests for the Indian currency formatter: zero, small
 * amounts, the lakh boundary, the crore boundary, decimals, negatives and null.
 */
@IsTest
private class RIQ_CurrencyFormatter_Test {
    @IsTest
    static void formatsIndianGrouping() {
        System.assertEquals('₹0', RIQ_CurrencyFormatter.formatInr(0));
        System.assertEquals('₹999', RIQ_CurrencyFormatter.formatInr(999));
        System.assertEquals('₹45,000', RIQ_CurrencyFormatter.formatInr(45000));
        System.assertEquals('₹99,999', RIQ_CurrencyFormatter.formatInr(99999));
        System.assertEquals('₹1,00,000', RIQ_CurrencyFormatter.formatInr(100000));
        System.assertEquals('₹12,50,000', RIQ_CurrencyFormatter.formatInr(1250000));
        System.assertEquals('₹99,99,999', RIQ_CurrencyFormatter.formatInr(9999999));
        System.assertEquals('₹1,00,00,000', RIQ_CurrencyFormatter.formatInr(10000000));
        System.assertEquals('₹4,25,00,000', RIQ_CurrencyFormatter.formatInr(42500000));
    }

    @IsTest
    static void roundsPaiseAndKeepsSigns() {
        System.assertEquals('₹12,34,568', RIQ_CurrencyFormatter.formatInr(1234567.89));
        System.assertEquals('-₹1,50,000', RIQ_CurrencyFormatter.formatInr(-150000));
        System.assertEquals('—', RIQ_CurrencyFormatter.formatInr(null));
    }

    @IsTest
    static void compactsAtTheLakhAndCroreBoundaries() {
        System.assertEquals('₹99,999', RIQ_CurrencyFormatter.formatInrCompact(99999));
        System.assertEquals('₹1 L', RIQ_CurrencyFormatter.formatInrCompact(100000));
        System.assertEquals('₹1.5 L', RIQ_CurrencyFormatter.formatInrCompact(150000));
        System.assertEquals('₹12.5 L', RIQ_CurrencyFormatter.formatInrCompact(1250000));
        System.assertEquals('₹12.5 L', RIQ_CurrencyFormatter.formatInrCompact(1255000));
        // Truncated, never rounded up into a crore that is not there.
        System.assertEquals('₹99.9 L', RIQ_CurrencyFormatter.formatInrCompact(9999999));
        System.assertEquals('₹1 Cr', RIQ_CurrencyFormatter.formatInrCompact(10000000));
        System.assertEquals('₹4.25 Cr', RIQ_CurrencyFormatter.formatInrCompact(42500000));
    }

    @IsTest
    static void compactsSmallAndNegativeAmounts() {
        System.assertEquals('₹0', RIQ_CurrencyFormatter.formatInrCompact(0));
        System.assertEquals('₹45,000', RIQ_CurrencyFormatter.formatInrCompact(45000));
        System.assertEquals('-₹1.5 L', RIQ_CurrencyFormatter.formatInrCompact(-150000));
        System.assertEquals('-₹2.5 Cr', RIQ_CurrencyFormatter.formatInrCompact(-25000000));
        System.assertEquals('—', RIQ_CurrencyFormatter.formatInrCompact(null));
    }
}
