import {
	bytesToHex,
	cre,
	getNetwork,
	type HTTPPayload,
	hexToBase64,
	Runner,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import { encodeAbiParameters, parseAbiParameters } from 'viem'
import { z } from 'zod'
import './abi'

// ─── Configuration Schema ───────────────────────────────────────────────────

const configSchema = z.object({
	evms: z.array(
		z.object({
			clearingHouseAddress: z.string(),
			chainSelectorName: z.string(),
			gasLimit: z.string(),
		}),
	),
})

type Config = z.infer<typeof configSchema>

// ─── Trade Payload Schema ──────────────────────────────────────────────────

/**
 * Schema for validating the incoming trade payload.
 * Matches the structure defined in contracts/scripts-js/trade.json
 */
const tradePayloadSchema = z.object({
	trade: z.object({
		tradeId: z.string(),
		partyA: z.string(),
		partyB: z.string(),
		notional: z.string(),
		fixedRateBps: z.number(),
		startDate: z.number(),
		maturityDate: z.number(),
		paymentInterval: z.number(),
		dayCountConvention: z.number(),
		floatingRateIndex: z.string(),
		nonce: z.number(),
		deadline: z.number(),
		collateralToken: z.string(),
	}),
	sigA: z.string(),
	sigB: z.string(),
	metadata: z
		.object({
			notionalFormatted: z.string(),
			fixedRateFormatted: z.string(),
			tenorDays: z.number(),
			paymentIntervalDays: z.number(),
			partyAFormatted: z.string(),
			partyBFormatted: z.string(),
		})
		.optional(),
})

type ValidatedTradePayload = z.infer<typeof tradePayloadSchema>

// ─── Utility Functions ──────────────────────────────────────────────────────

const safeJsonStringify = (obj: any): string =>
	JSON.stringify(obj, (_, value) => (typeof value === 'bigint' ? value.toString() : value), 2)

/**
 * Parse and validate the incoming trade payload
 */
const parseTradePayload = (input: Buffer): ValidatedTradePayload => {
	const payloadJson = JSON.parse(input.toString())
	return tradePayloadSchema.parse(payloadJson)
}

/**
 * Convert a hex string to a 32-byte padded bytes32
 */
const toBytes32 = (hexStr: string): `0x${string}` => {
	// Remove 0x prefix if present
	const cleanHex = hexStr.startsWith('0x') ? hexStr.slice(2) : hexStr
	// Pad to 64 characters (32 bytes)
	const paddedHex = cleanHex.padStart(64, '0')
	return `0x${paddedHex}`
}

// ─── Core Workflow Logic ───────────────────────────────────────────────────

/**
 * Execute the trade submission to the ClearingHouse contract.
 * This function:
 * 1. Validates the trade payload
 * 2. Encodes the function call data for submitMatchedTrade
 * 3. Generates a DON-signed report
 * 4. Submits the transaction to the ClearingHouse contract
 */
const submitTradeToClearingHouse = (
	runtime: Runtime<Config>,
	evmClient: cre.capabilities.EVMClient,
	payload: ValidatedTradePayload,
): string => {
	const evmConfig = runtime.config.evms[0]

	runtime.log(`Submitting trade to ClearingHouse: ${payload.trade.tradeId}`)

	// Validate addresses
	const trade = payload.trade

	// Log the trade details
	runtime.log(`Trade Details:`)
	runtime.log(`  Trade ID: ${trade.tradeId}`)
	runtime.log(`  Party A: ${trade.partyA}`)
	runtime.log(`  Party B: ${trade.partyB}`)
	runtime.log(`  Notional: ${trade.notional}`)
	runtime.log(`  Fixed Rate: ${trade.fixedRateBps} bps`)
	runtime.log(`  Start Date: ${new Date(trade.startDate * 1000).toISOString()}`)
	runtime.log(`  Maturity Date: ${new Date(trade.maturityDate * 1000).toISOString()}`)
	runtime.log(`  Payment Interval: ${trade.paymentInterval} seconds`)
	runtime.log(`  Day Count Convention: ${trade.dayCountConvention}`)
	runtime.log(`  Floating Rate Index: ${trade.floatingRateIndex}`)
	runtime.log(`  Nonce: ${trade.nonce}`)
	runtime.log(`  Deadline: ${new Date(trade.deadline * 1000).toISOString()}`)
	runtime.log(`  Collateral Token: ${trade.collateralToken}`)

	// Create the trade object that matches the tuple structure
	const tradeData = {
		tradeId: toBytes32(trade.tradeId),
		partyA: toBytes32(trade.partyA),
		partyB: toBytes32(trade.partyB),
		notional: BigInt(trade.notional),
		fixedRateBps: BigInt(trade.fixedRateBps),
		startDate: BigInt(trade.startDate),
		maturityDate: BigInt(trade.maturityDate),
		paymentInterval: BigInt(trade.paymentInterval),
		dayCountConvention: trade.dayCountConvention,
		floatingRateIndex: toBytes32(trade.floatingRateIndex),
		nonce: BigInt(trade.nonce),
		deadline: BigInt(trade.deadline),
		collateralToken: trade.collateralToken as `0x${string}`,
	}

	// Convert tradeData object to positional array matching the tuple order
	const tradeDataArray = [
		tradeData.tradeId,
		tradeData.partyA,
		tradeData.partyB,
		tradeData.notional,
		tradeData.fixedRateBps,
		tradeData.startDate,
		tradeData.maturityDate,
		tradeData.paymentInterval,
		BigInt(tradeData.dayCountConvention),  // Convert to BigInt for consistency
		tradeData.floatingRateIndex,
		tradeData.nonce,
		tradeData.deadline,
		tradeData.collateralToken,
	];

	// Encode the full report with report type prefix: abi.encode(uint8(0), trade, sigA, sigB)
	// ReportType = 0 indicates trade submission
	// This matches the contract's expected format in _processReport()
	const fullAbiParams = parseAbiParameters(
		'uint8,(bytes32,bytes32,bytes32,uint256,uint256,uint256,uint256,uint256,uint8,bytes32,uint256,uint256,address),bytes,bytes',
	)
	const callData = encodeAbiParameters(fullAbiParams, [
		BigInt(0), // Report type: 0 = trade submission
		tradeDataArray,
		payload.sigA,
		payload.sigB,
	])

	runtime.log(`Encoded call data: ${callData}`)

	// Generate a DON-signed report using consensus capability
	const reportResponse = runtime
		.report({
			encodedPayload: hexToBase64(callData),
			encoderName: 'evm',
			signingAlgo: 'ecdsa',
			hashingAlgo: 'keccak256',
		})
		.result()

	// Submit the report to the ClearingHouse contract
	const resp = evmClient
		.writeReport(runtime, {
			receiver: evmConfig.clearingHouseAddress,
			report: reportResponse,
			gasConfig: {
				gasLimit: evmConfig.gasLimit,
			},
		})
		.result()

	const txStatus = resp.txStatus

	if (txStatus !== TxStatus.SUCCESS) {
		throw new Error(`Failed to submit trade: ${resp.errorMessage || txStatus}`)
	}

	const txHash = bytesToHex(resp.txHash || new Uint8Array(32))
	runtime.log(`Trade submitted successfully! TxHash: ${txHash}`)
	runtime.log(`   Verify execution: https://sepolia.etherscan.io/tx/${txHash}`)

	return txHash
}

// ─── HTTP Trigger Handler ───────────────────────────────────────────────────

const onHTTPTrigger = (
	runtime: Runtime<Config>,
	evmClient: cre.capabilities.EVMClient,
	payload: HTTPPayload,
): string => {
	runtime.log('HTTP trigger received for create-trade-workflow')

	// Require payload
	if (!payload.input || payload.input.length === 0) {
		throw new Error('HTTP trigger payload is required')
	}

	runtime.log(`Payload bytes: ${payload.input.toString()}`)

	try {
		// Parse and validate the trade payload
		const tradePayload = parseTradePayload(payload.input)

		runtime.log(`Parsed trade payload: ${safeJsonStringify(tradePayload)}`)

		// Execute the trade submission
		const txHash = submitTradeToClearingHouse(runtime, evmClient, tradePayload)

		return `Trade submitted successfully! TxHash: ${txHash}`
	} catch (error) {
		runtime.log(`Error processing trade payload: ${error}`)
		throw new Error(`Failed to process trade payload: ${error}`)
	}
}

// ─── Workflow Initialization ───────────────────────────────────────────────

const initWorkflow = (config: Config) => {
	const httpTrigger = new cre.capabilities.HTTPCapability()

	// Initialize EVM client for the configured chain
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.evms[0].chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(
			`Network not found for chain selector name: ${config.evms[0].chainSelectorName}`,
		)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	return [
		cre.handler(
			httpTrigger.trigger({}),
			(runtime, payload) => onHTTPTrigger(runtime, evmClient, payload),
		),
	]
}

// ─── Main Entry Point ───────────────────────────────────────────────────────

export async function main() {
	const runner = await Runner.newRunner<Config>({
		configSchema,
	})
	await runner.run(initWorkflow)
}

main()
