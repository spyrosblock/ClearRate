import {
	bytesToHex,
	ConsensusAggregationByFields,
	type CronPayload,
	handler,
	CronCapability,
	EVMClient,
	getNetwork,
	HTTPClient,
	type HTTPSendRequester,
	hexToBase64,
	median,
	Runner,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import { type Address, encodeAbiParameters, parseAbiParameters } from 'viem'
import { z } from 'zod'

// ─── Configuration Schema ───────────────────────────────────────────────────

const configSchema = z.object({
	schedule: z.string(),
	evms: z.array(
		z.object({
			liquidationEngineAddress: z.string(),
			chainSelectorName: z.string(),
			gasLimit: z.string(),
		}),
	),
	liquidationMonitoring: z.object({
		apiEndpoint: z.string(),
	}).optional(),
})

type Config = z.infer<typeof configSchema>

// ─── Liquidation Target Schema ─────────────────────────────────────────────

/**
 * Expected API response structure from the liquidation-monitoring/targets endpoint.
 * 
 * Example API response:
 * ```json
 * {
 *   "success": true,
 *   "liquidationTargets": [
 *     {
 *       "accountId": "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
 *       "collateralToken": "0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa",
 *       "totalCollateral": "1000000000000000000",
 *       "maintenanceMargin": "2000000000000000000",
 *       "startPremiumBps": 500
 *     }
 *   ],
 *   "count": 1
 * }
 * ```
 */
const liquidationTargetsResponseSchema = z.object({
	success: z.boolean(),
	liquidationTargets: z.array(
		z.object({
			accountId: z.string(),
			collateralToken: z.string(),
			totalCollateral: z.string(),
			maintenanceMargin: z.string(),
			startPremiumBps: z.number(),
		}),
	).optional(),
	count: z.number().optional(),
	message: z.string().optional(),
})

type LiquidationTargetsResponse = z.infer<typeof liquidationTargetsResponseSchema>

/**
 * Liquidation target data matching the contract's LiquidationTarget struct.
 */
interface LiquidationTarget {
	accountId: `0x${string}` // bytes32
	collateralToken: `0x${string}` // address
	startPremiumBps: bigint // uint256
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

/**
 * Convert a string to a valid address (20 bytes, lowercased)
 */
const toAddress = (hexStr: string): `0x${string}` => {
	// Remove 0x prefix if present
	const cleanHex = hexStr.startsWith('0x') ? hexStr.slice(2) : hexStr
	// Pad to 40 characters (20 bytes)
	const paddedHex = cleanHex.padStart(40, '0')
	return `0x${paddedHex.toLowerCase()}`
}

// ─── Liquidation Targets API Fetching ───────────────────────────────────────

/**
 * Fetch liquidation targets from the API.
 * This function retrieves accounts where total_collateral < maintenance_margin.
 */
const fetchLiquidationTargets = (
	runtime: Runtime<Config>,
	sendRequester: HTTPSendRequester,
	config: Config,
): LiquidationTargetsResponse => {
	if (!config.liquidationMonitoring?.apiEndpoint) {
		throw new Error('Liquidation Monitoring API endpoint is not configured')
	}

	runtime.log(`Fetching liquidation targets from: ${config.liquidationMonitoring.apiEndpoint}`)

	const response = sendRequester.sendRequest({
		method: 'GET',
		url: config.liquidationMonitoring.apiEndpoint,
	}).result()

	console.log('[DEBUG] Liquidation Targets API response status:', response.statusCode)
	console.log('[DEBUG] Liquidation Targets API response body:', JSON.stringify(response.body))

	if (response.statusCode !== 200) {
		throw new Error(`Liquidation Targets API request failed with status: ${response.statusCode}`)
	}

	const responseText = Buffer.from(response.body).toString('utf-8')
	const data = JSON.parse(responseText)

	// Validate the response
	const parsedData = liquidationTargetsResponseSchema.parse(data)

	if (!parsedData.success) {
		throw new Error(`Liquidation Targets API returned unsuccessful response: ${parsedData.message || 'Unknown error'}`)
	}

	const targetCount = parsedData.liquidationTargets?.length || 0
	runtime.log(`Found ${targetCount} liquidation targets`)

	return parsedData
}

// ─── Onchain Write: Liquidate Accounts on LiquidationEngine ─────────────────

/**
 * Write liquidation report to the LiquidationEngine contract.
 * Uses CRE's consensus-signed report mechanism to deliver the data
 * through the KeystoneForwarder → consumer contract flow.
 *
 * The encoded payload matches the `_processReport(bytes)` signature with reportType = 0.
 * ReportType = 0: Liquidate accounts (starts auctions for undercollateralized accounts)
 */
const writeLiquidationReport = (
	runtime: Runtime<Config>,
	evmConfig: Config['evms'][0],
	targets: LiquidationTarget[],
): string => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: evmConfig.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain: ${evmConfig.chainSelectorName}`)
	}

	const evmClient = new EVMClient(network.chainSelector.selector)

	runtime.log(
		`Processing ${targets.length} liquidation targets on LiquidationEngine at ${evmConfig.liquidationEngineAddress}`,
	)

	// Log each liquidation target
	for (let i = 0; i < targets.length; i++) {
		const t = targets[i]
		runtime.log(`  Target ${i + 1}: accountId=${t.accountId}, collateralToken=${t.collateralToken}`)
	}

	// ABI-encode the liquidation data as (uint8, LiquidationTarget[])
	// ReportType = 0 indicates liquidation
	// LiquidationTarget struct: (bytes32 accountId, address collateralToken, uint256 startPremiumBps)
	const liquidationParams = parseAbiParameters(
		'uint8, (bytes32 accountId, address collateralToken, uint256 startPremiumBps)[]',
	)

	// Create struct array as array of objects
	const liquidationTargets = targets.map((t) => ({
		accountId: t.accountId,
		collateralToken: t.collateralToken,
		startPremiumBps: t.startPremiumBps,
	}))

	const reportData = encodeAbiParameters(liquidationParams, [
		0, // Report type: 0 = Liquidation
		liquidationTargets,
	])

	runtime.log(`Encoded liquidation report data: ${reportData}`)

	// Step 1: Generate a consensus-signed report
	const reportResponse = runtime
		.report({
			encodedPayload: hexToBase64(reportData),
			encoderName: 'evm',
			signingAlgo: 'ecdsa',
			hashingAlgo: 'keccak256',
		})
		.result()

	// Step 2: Submit the signed report to the LiquidationEngine contract
	const resp = evmClient
		.writeReport(runtime, {
			receiver: evmConfig.liquidationEngineAddress,
			report: reportResponse,
			gasConfig: {
				gasLimit: evmConfig.gasLimit,
			},
		})
		.result()

	if (resp.txStatus !== TxStatus.SUCCESS) {
		throw new Error(`Failed to process liquidation: ${resp.errorMessage || resp.txStatus}`)
	}

	const txHash = bytesToHex(resp.txHash || new Uint8Array(32))
	runtime.log(`Liquidation report submitted successfully! TxHash: ${txHash}`)

	return txHash
}


// ─── Main Workflow Logic ────────────────────────────────────────────────────

/**
 * Core workflow execution:
 * 1. Fetch liquidation targets from the API
 * 2. If targets exist, write liquidation report to LiquidationEngine contract onchain
 */
const executeLiquidationWorkflow = (runtime: Runtime<Config>): string => {
	runtime.log('=== Liquidation Workflow Started ===')

	const evmConfig = runtime.config.evms[0]
	const httpCapability = new HTTPClient()

	// ── Step 1: Fetch liquidation targets from API ────────────────────────
	runtime.log('Fetching liquidation targets from monitoring API...')

	let targetsResponse: LiquidationTargetsResponse

	// Use consensus aggregation for fetching targets (each DON node fetches independently)
	targetsResponse = httpCapability
		.sendRequest(
			runtime,
			(sendRequester, config) => fetchLiquidationTargets(runtime, sendRequester, config as Config),
			ConsensusAggregationByFields<LiquidationTargetsResponse>({
				success: median,
				liquidationTargets: median as any,
				count: median,
			}),
		)(runtime.config)
		.result() as LiquidationTargetsResponse

	const targets = targetsResponse.liquidationTargets || []
	runtime.log(`Fetched ${targets.length} liquidation targets`)

	// ── Step 2: If targets exist, write liquidation report onchain ─────────
	if (targets.length === 0) {
		runtime.log('No liquidation targets found. Skipping transaction.')
		runtime.log('=== Liquidation Workflow Completed ===')
		return ''
	}

	// Transform API response to contract-compatible LiquidationTarget format
	const liquidationTargets: LiquidationTarget[] = targets.map((t) => ({
		accountId: toBytes32(t.accountId),
		collateralToken: toAddress(t.collateralToken),
		startPremiumBps: BigInt(t.startPremiumBps),
	}))

	runtime.log('Writing liquidation report to LiquidationEngine...')
	const txHash = writeLiquidationReport(runtime, evmConfig, liquidationTargets)

	runtime.log('=== Liquidation Workflow Completed ===')
	runtime.log(`Targets processed: ${targets.length} | TxHash: ${txHash}`)

	return txHash
}

// ─── Trigger Handlers ───────────────────────────────────────────────────────

const onCronTrigger = (runtime: Runtime<Config>, payload: CronPayload): string => {
	if (!payload.scheduledExecutionTime) {
		throw new Error('Scheduled execution time is required')
	}

	runtime.log('Liquidation workflow triggered by cron schedule')
	return executeLiquidationWorkflow(runtime)
}

// ─── Workflow Initialization ────────────────────────────────────────────────

const initWorkflow = (config: Config) => {
	const cronTrigger = new CronCapability()

	return [
		handler(
			cronTrigger.trigger({
				schedule: config.schedule,
			}),
			onCronTrigger,
		),
	]
}

// ─── Main Entry Point ───────────────────────────────────────────────────

export async function main() {
	const runner = await Runner.newRunner<Config>({
		configSchema,
	})
	await runner.run(initWorkflow)
}

main()