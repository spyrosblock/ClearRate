import { bytesToHex, ConsensusAggregationByFields, handler, CronCapability, EVMClient, HTTPClient, getNetwork, hexToBase64, median, Runner, TxStatus, } from '@chainlink/cre-sdk';
import { encodeAbiParameters, parseAbiParameters } from 'viem';
import { z } from 'zod';
// ─── Configuration Schema ───────────────────────────────────────────────────
const configSchema = z.object({
    schedule: z.string(),
    sofrApiUrl: z.string(),
    sofrApiBackupUrl: z.string().optional(),
    evms: z.array(z.object({
        yieldCurveOracleAddress: z.string(),
        chainSelectorName: z.string(),
        gasLimit: z.string(),
    })),
});
// ─── Constants ──────────────────────────────────────────────────────────────
/** WAD precision (1e18) — matches Solidity contract precision */
const WAD = 10n ** 18n;
/**
 * Standard IRS tenor buckets in seconds.
 * These correspond to common swap tenors in the interest rate market:
 * 1M, 3M, 6M, 1Y, 2Y, 3Y, 5Y, 7Y, 10Y, 30Y
 */
const TENOR_BUCKETS = {
    '1M': 2592000n, // 30 days
    '3M': 7776000n, // 90 days
    '6M': 15552000n, // 180 days
    '1Y': 31536000n, // 365 days
    '2Y': 63072000n, // 730 days
    '3Y': 94608000n, // 1095 days
    '5Y': 157680000n, // 1825 days
    '10Y': 315360000n, // 3650 days
    '30Y': 946080000n, // 10950 days
};
// ─── Utility Functions ──────────────────────────────────────────────────────
const safeJsonStringify = (obj) => JSON.stringify(obj, (_, value) => (typeof value === 'bigint' ? value.toString() : value), 2);
/**
 * Convert an annual rate (percentage) to a discount factor for a given tenor.
 * Uses the formula: DF(t) = 1 / (1 + r)^t
 * where r is the annual rate and t is time in years.
 *
 * The result is scaled to WAD (1e18) precision for onchain storage.
 *
 * @param annualRatePercent - Annual rate as a percentage (e.g., 4.30 for 4.30%)
 * @param tenorSeconds - Tenor duration in seconds
 * @returns Discount factor in WAD precision
 */
function computeDiscountFactor(annualRatePercent, tenorSeconds) {
    const rate = annualRatePercent / 100.0;
    const yearsToMaturity = Number(tenorSeconds) / (365.0 * 24 * 60 * 60);
    const df = 1.0 / Math.pow(1.0 + rate, yearsToMaturity);
    // Scale to WAD precision — clamp to [0, 1e18] as the contract requires DF ∈ (0, WAD]
    const dfWad = BigInt(Math.round(df * 1e18));
    if (dfWad <= 0n)
        return 1n; // minimum valid DF
    if (dfWad > WAD)
        return WAD;
    return dfWad;
}
/**
 * Estimate a flat rate for a given tenor from SOFR averages.
 * Uses simple interpolation/extrapolation from the available average rates
 * (30-day, 90-day, 180-day) to produce a rate estimate for any tenor.
 *
 * For tenors beyond 180 days, we use the SOFR 180-day average as the base
 * rate with a small term premium adjustment.
 */
function estimateRateForTenor(sofrData, tenorSeconds) {
    const tenorDays = Number(tenorSeconds) / (24 * 60 * 60);
    if (tenorDays <= 30) {
        // For very short tenors, use the spot SOFR rate
        return sofrData.ratePercent;
    }
    else if (tenorDays <= 90) {
        // Interpolate between spot and 30-day average
        const t = (tenorDays - 30) / (90 - 30);
        return sofrData.ratePercent * (1 - t) + sofrData.averageRate30 * t;
    }
    else if (tenorDays <= 180) {
        // Interpolate between 30-day and 90-day averages
        const t = (tenorDays - 90) / (180 - 90);
        return sofrData.averageRate30 * (1 - t) + sofrData.averageRate90 * t;
    }
    else {
        // For longer tenors, use 180-day average plus a small term premium
        // Term premium: ~2bps per year beyond 6 months (simplified model)
        const yearsFromBase = (tenorDays - 180) / 365.0;
        const termPremiumBps = 2.0 * yearsFromBase;
        return sofrData.averageRate180 + termPremiumBps / 100.0;
    }
}
// ─── SOFR Data Fetching ─────────────────────────────────────────────────────
/**
 * Fetch SOFR rate data from the NY Fed Markets API.
 * This function is executed by each DON node independently;
 * results are aggregated via median consensus.
 *
 * Primary API: https://markets.newyorkfed.org/api/rates/secured/sofr-avg-ind/last/1.json
 * This endpoint returns SOFR Index, 30/90/180-day averages directly from NY Fed.
 * The Index is based on ISDA's compound formula.
 *
 * Falls back to legacy /rates/secured/sofr/ endpoint if needed.
 */
const fetchSOFRRate = (sendRequester, config) => {
    const response = sendRequester.sendRequest({
        method: 'GET',
        url: config.sofrApiUrl,
    }).result();
    if (response.statusCode !== 200) {
        throw new Error(`SOFR API request failed with status: ${response.statusCode}`);
    }
    // Handle both ArrayBuffer and string response bodies
    let responseText;
    if (typeof response.body === 'string') {
        responseText = response.body;
    }
    else if (response.body instanceof Uint8Array) {
        // For Uint8Array, convert to string
        responseText = Array.from(response.body).map(b => String.fromCharCode(b)).join('');
    }
    else {
        // Handle ArrayBuffer or unknown type - convert to string
        try {
            responseText = String(response.body);
        }
        catch {
            throw new Error('Unable to parse response body');
        }
    }
    const data = JSON.parse(responseText);
    // Try new SOFR Average and Index format first (sofr-avg-ind endpoint)
    if (data.sofrAvgInd && data.sofrAvgInd.length > 0) {
        const sofrEntry = data.sofrAvgInd[0];
        if (sofrEntry.sofrIndex === undefined) {
            throw new Error('SOFR Index is missing from API response');
        }
        // Convert Index to rate: The SOFR Index is published with 10 decimal places
        // To get the daily rate from Index: r = (Index_end / Index_start - 1)
        // But for simplicity, we use the 1-day average as the spot rate
        const spotRate = sofrEntry.sofr1DayAvg ?? 0;
        return {
            effectiveDate: sofrEntry.effectiveDate,
            ratePercent: spotRate,
            averageRate30: sofrEntry.sofr30DayAvg ?? spotRate,
            averageRate90: sofrEntry.sofr90DayAvg ?? sofrEntry.sofr30DayAvg ?? spotRate,
            averageRate180: sofrEntry.sofr180DayAvg ?? sofrEntry.sofr90DayAvg ?? sofrEntry.sofr30DayAvg ?? spotRate,
            sofrIndex: sofrEntry.sofrIndex,
        };
    }
    // Fallback to legacy format (refRates from /sofr/ endpoint)
    if (!data.refRates || data.refRates.length === 0) {
        throw new Error('No SOFR rate data returned from API');
    }
    // Find the SOFR rate entry (type === "SOFR")
    const sofrEntry = data.refRates.find(r => r.type === 'SOFR');
    if (!sofrEntry) {
        throw new Error('SOFR rate entry not found in API response');
    }
    if (sofrEntry.percentRate === undefined) {
        throw new Error('SOFR percentRate is missing from API response');
    }
    return {
        effectiveDate: sofrEntry.effectiveDate,
        ratePercent: sofrEntry.percentRate,
        averageRate30: sofrEntry.averageRate30 ?? sofrEntry.percentRate,
        averageRate90: sofrEntry.averageRate90 ?? sofrEntry.percentRate,
        averageRate180: sofrEntry.averageRate180 ?? sofrEntry.percentRate,
        sofrIndex: sofrEntry.index ?? 0,
    };
};
// ─── Yield Curve Bootstrap ──────────────────────────────────────────────────
/**
 * Bootstrap a yield curve from SOFR data.
 * Computes discount factors for each supported tenor bucket using the
 * fetched SOFR rates and average rates.
 *
 * @returns Arrays of tenors and their corresponding discount factors (WAD precision)
 */
function bootstrapYieldCurve(sofrData) {
    const tenors = [];
    const factors = [];
    // Sort tenor entries by duration for consistent ordering
    const sortedEntries = Object.entries(TENOR_BUCKETS).sort((a, b) => Number(a[1] - b[1]));
    for (const [label, tenorSeconds] of sortedEntries) {
        const estimatedRate = estimateRateForTenor(sofrData, tenorSeconds);
        const df = computeDiscountFactor(estimatedRate, tenorSeconds);
        tenors.push(tenorSeconds);
        factors.push(df);
    }
    return { tenors, factors };
}
// ─── Onchain Write: Update Discount Factors ─────────────────────────────────
/**
 * Write updated discount factors to the YieldCurveOracle contract.
 * Uses CRE's consensus-signed report mechanism to deliver the data
 * through the KeystoneForwarder → consumer contract flow.
 *
 * The encoded payload matches the `updateDiscountFactors(uint256[], uint256[])` signature.
 */
const writeDiscountFactors = (runtime, evmConfig, tenors, factors) => {
    const network = getNetwork({
        chainFamily: 'evm',
        chainSelectorName: evmConfig.chainSelectorName,
        isTestnet: true,
    });
    if (!network) {
        throw new Error(`Network not found for chain: ${evmConfig.chainSelectorName}`);
    }
    const evmClient = new EVMClient(network.chainSelector.selector);
    runtime.log(`Writing ${tenors.length} discount factors to YieldCurveOracle at ${evmConfig.yieldCurveOracleAddress}`);
    // ABI-encode the discount factor data as (uint256[], uint256[])
    const callData = encodeAbiParameters(parseAbiParameters('uint256[] tenors, uint256[] factors'), [tenors, factors]);
    // Step 1: Generate a consensus-signed report
    const reportResponse = runtime
        .report({
        encodedPayload: hexToBase64(callData),
        encoderName: 'evm',
        signingAlgo: 'ecdsa',
        hashingAlgo: 'keccak256',
    })
        .result();
    // Step 2: Submit the signed report to the consumer contract (proxy)
    const resp = evmClient
        .writeReport(runtime, {
        receiver: evmConfig.yieldCurveOracleAddress,
        report: reportResponse,
        gasConfig: {
            gasLimit: evmConfig.gasLimit,
        },
    })
        .result();
    if (resp.txStatus !== TxStatus.SUCCESS) {
        throw new Error(`Failed to write discount factors: ${resp.errorMessage || resp.txStatus}`);
    }
    const txHash = bytesToHex(resp.txHash || new Uint8Array(32));
    runtime.log(`Discount factors updated successfully. TxHash: ${txHash}`);
    return txHash;
};
// ─── Main Workflow Logic ────────────────────────────────────────────────────
/**
 * Core workflow execution:
 * 1. Fetch SOFR rate from NY Fed API (with DON consensus)
 * 2. Bootstrap yield curve — compute discount factors for all tenor buckets
 * 3. Write discount factors to YieldCurveOracle contract onchain
 */
const executeSofrWorkflow = (runtime) => {
    runtime.log('=== SOFR Rate Fetching Workflow Started ===');
    // ── Step 1: Fetch SOFR rate with consensus ──────────────────────────
    runtime.log(`Fetching SOFR rate from: ${runtime.config.sofrApiUrl}`);
    const httpCapability = new HTTPClient();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sofrData = httpCapability
        .sendRequest(runtime, fetchSOFRRate, ConsensusAggregationByFields({
        effectiveDate: median,
        ratePercent: median,
        averageRate30: median,
        averageRate90: median,
        averageRate180: median,
        sofrIndex: median,
    }))(runtime.config)
        .result();
    runtime.log(`SOFR Rate Data: ${safeJsonStringify(sofrData)}`);
    runtime.log(`SOFR Rate: ${sofrData.ratePercent}% (effective: ${sofrData.effectiveDate})`);
    // ── Step 2: Bootstrap yield curve ───────────────────────────────────
    runtime.log('Bootstrapping yield curve from SOFR data...');
    const { tenors, factors } = bootstrapYieldCurve(sofrData);
    // Log each tenor's discount factor for debugging
    const sortedEntries = Object.entries(TENOR_BUCKETS).sort((a, b) => Number(a[1] - b[1]));
    for (let i = 0; i < sortedEntries.length; i++) {
        const [label] = sortedEntries[i];
        const dfPercent = (Number(factors[i]) / 1e18 * 100).toFixed(6);
        runtime.log(`  ${label}: DF = ${factors[i].toString()} (${dfPercent}%)`);
    }
    // ── Step 3: Write discount factors onchain ──────────────────────────
    const evmConfig = runtime.config.evms[0];
    runtime.log('Writing discount factors to YieldCurveOracle...');
    const txHash = writeDiscountFactors(runtime, evmConfig, tenors, factors);
    runtime.log('=== SOFR Rate Fetching Workflow Completed ===');
    runtime.log(`SOFR Rate: ${sofrData.ratePercent}% | Tenors Updated: ${tenors.length} | TxHash: ${txHash}`);
    return txHash;
};
// ─── Trigger Handlers ───────────────────────────────────────────────────────
const onCronTrigger = (runtime, payload) => {
    if (!payload.scheduledExecutionTime) {
        throw new Error('Scheduled execution time is required');
    }
    runtime.log('SOFR workflow triggered by cron schedule');
    return executeSofrWorkflow(runtime);
};
// ─── Workflow Initialization ────────────────────────────────────────────────
const initWorkflow = (config) => {
    const cronTrigger = new CronCapability();
    return [
        handler(cronTrigger.trigger({
            schedule: config.schedule,
        }), onCronTrigger),
    ];
};
export async function main() {
    const runner = await Runner.newRunner({
        configSchema,
    });
    await runner.run(initWorkflow);
}
