import {
	bytesToHex,
	ConsensusAggregationByFields,
	type CronPayload,
	handler,
	CronCapability,
	EVMClient,
	encodeCallMsg,
	getNetwork,
	HTTPClient,
	type HTTPSendRequester,
	hexToBase64,
	LAST_FINALIZED_BLOCK_NUMBER,
	median,
	Runner,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import { type Address, decodeFunctionResult, encodeAbiParameters, encodeFunctionData, parseAbiParameters, toHex, zeroAddress } from 'viem'
import { z } from 'zod'
import './abi'
import { ClearingHouseFullABI } from './abi/ClearingHouse'

// ─── Configuration Schema ───────────────────────────────────────────────────

const configSchema = z.object({
	schedule: z.string(),
	evms: z.array(
		z.object({
			clearingHouseAddress: z.string(),
			chainSelectorName: z.string(),
			gasLimit: z.string(),
		}),
	),
	vmSettlement: z.object({
		apiEndpoint: z.string(),
		fallbackEnabled: z.boolean(),
	}).optional(),
	novatedPositions: z.object({
		apiEndpoint: z.string(),
	}).optional(),
})

type Config = z.infer<typeof configSchema>

// ─── VM Settlement Payload Schema ─────────────────────────────────────────

/**
 * Expected API response structure from the settlement endpoint.
 * 
 * Example API response:
 * ```json
 * {
 *   "settlements": [
 *     {
 *       "tradeId": "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
 *       "npvChange": "1000000000000000000",
 *       "isFinal": false
 *     }
 *   ],
 *   "metadata": {
 *     "settlementDate": "2026-02-25",
 *     "npvSource": "internal"
 *   }
 * }
 * ```
 * 
 * - tradeId: bytes32 hex string (64 characters, may include 0x prefix)
 * - npvChange: string representation of int256 (positive = NPV increased from fixed payer's perspective)
 * - isFinal: boolean indicating if this is a final matured position settlement (true) or regular VM settlement (false)
 */
const vmSettlementPayloadSchema = z.object({
	settlements: z.array(
		z.object({
			tradeId: z.string(),
			npvChange: z.string(), // Can be positive or negative
			isFinal: z.boolean(), // true = matured position settlement, false = regular VM
		}),
	),
	metadata: z
		.object({
			settlementDate: z.string(),
			npvSource: z.string(),
		})
		.optional(),
})


type ValidatedVMSettlementPayload = z.infer<typeof vmSettlementPayloadSchema>


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

// ─── Position Data from novated_positions API ───────────────────────────────

/**
 * Position data structure from the novated_positions API/database.
 */
interface PositionData {
	tradeId: string
	tokenIdA: string
	tokenIdB: string
	partyA: string
	partyB: string
	notional: string
	originalNotional: string
	fixedRateBps: string
	startDate: string
	maturityDate: string
	active: boolean
	lastNpv: string
}

/**
 * Schema for validating the novated_positions API response.
 */
const novatedPositionsResponseSchema = z.array(
	z.object({
		id: z.number(),
		trade_id: z.string(),
		token_id_a: z.string(),
		token_id_b: z.string(),
		party_a: z.string(),
		party_b: z.string(),
		notional: z.string(),
		original_notional: z.string(),
		fixed_rate_bps: z.number(),
		start_date: z.string(),
		maturity_date: z.string(),
		active: z.boolean(),
		last_npv: z.string(),
		created_at: z.string().optional(),
		updated_at: z.string().optional(),
	}),
)

type NovatedPositionsResponse = z.infer<typeof novatedPositionsResponseSchema>

/**
 * Response wrapper for positions to enable proper consensus aggregation.
 */
interface PositionsResponse {
	positions: PositionData[]
	count: number
}

/**
 * Fetch all positions from the novated_positions API.
 * This function retrieves positions from the database via the Next.js API route.
 * Only active positions are included in the VM settlement calculation.
 */
const fetchPositionsFromAPI = (
	runtime: Runtime<Config>,
	sendRequester: HTTPSendRequester,
	config: Config,
): PositionsResponse => {
	if (!config.novatedPositions?.apiEndpoint) {
		throw new Error('Novated Positions API endpoint is not configured')
	}

	runtime.log(`Fetching positions from: ${config.novatedPositions.apiEndpoint}`)

	const response = sendRequester.sendRequest({
		method: 'GET',
		url: config.novatedPositions.apiEndpoint,
	}).result()

	console.log('[DEBUG] Novated Positions API response status:', response.statusCode)
	console.log('[DEBUG] Novated Positions API response body:', JSON.stringify(response.body))

	if (response.statusCode !== 200) {
		throw new Error(`Novated Positions API request failed with status: ${response.statusCode}`)
	}

	const responseText = Buffer.from(response.body).toString('utf-8')
	console.log('[DEBUG] Novated Positions API response text:', responseText)
	
	const data = JSON.parse(responseText)

	// Validate the response
	const parsedData = novatedPositionsResponseSchema.parse(data)

	// Transform API response to PositionData format and filter for active positions only
	const positions: PositionData[] = parsedData
		.filter((pos) => pos.active)
		.map((pos) => ({
			tradeId: pos.trade_id,
			tokenIdA: pos.token_id_a,
			tokenIdB: pos.token_id_b,
			partyA: pos.party_a,
			partyB: pos.party_b,
			notional: pos.notional,
			originalNotional: pos.original_notional,
			fixedRateBps: pos.fixed_rate_bps.toString(),
			startDate: pos.start_date,
			maturityDate: pos.maturity_date,
			active: pos.active,
			lastNpv: pos.last_npv,
		}))

	runtime.log(`Found ${positions.length} active positions from novated_positions API`)

	// Return wrapped response for proper consensus aggregation
	return {
		positions,
		count: positions.length,
	}
}

// ─── VM Settlement Data Fetching with Positions ────────────────────────────

/**
 * Send positions to the API and receive VM settlement data.
 * This function is executed by each DON node independently;
 * results are aggregated via median consensus.
 */
const fetchVMSettlementDataWithPositions = (
	sendRequester: HTTPSendRequester,
	config: Config,
	positions: PositionData[],
): ValidatedVMSettlementPayload => {
	if (!config.vmSettlement?.apiEndpoint) {
		throw new Error('VM Settlement API endpoint is not configured')
	}

	// Send positions to the API via POST
	// Body must be base64 encoded for CRE SDK
	const requestBody = JSON.stringify({
		positions,
		settlementDate: new Date().toISOString().split('T')[0],
	})
	const response = sendRequester.sendRequest({
		method: 'POST',
		url: config.vmSettlement.apiEndpoint,
		body: Buffer.from(requestBody).toString('base64'),
		headers: {
			'Content-Type': 'application/json',
		},
	}).result()

	console.log('[DEBUG] Response status:', response.statusCode)
	console.log('[DEBUG] Response body:', JSON.stringify(response.body))

	if (response.statusCode !== 200) {
		throw new Error(`VM Settlement API request failed with status: ${response.statusCode}`)
	}

	const responseText = Buffer.from(response.body).toString('utf-8')
	console.log('[DEBUG] Response text:', responseText)
	const data = JSON.parse(responseText)

	// Validate and return the parsed payload
	return vmSettlementPayloadSchema.parse(data)
}

/**
 * Fetch VM settlement data from the configured API endpoint (legacy GET method).
 * This function is executed by each DON node independently;
 * results are aggregated via median consensus.
 */
const fetchVMSettlementData = (
	sendRequester: HTTPSendRequester,
	config: Config,
): ValidatedVMSettlementPayload => {
	if (!config.vmSettlement?.apiEndpoint) {
		throw new Error('VM Settlement API endpoint is not configured')
	}

	const response = sendRequester.sendRequest({
		method: 'GET',
		url: config.vmSettlement.apiEndpoint,
	}).result()

	console.log('[DEBUG] Response status:', response.statusCode)
	console.log('[DEBUG] Response body:', JSON.stringify(response.body))

	if (response.statusCode !== 200) {
		throw new Error(`VM Settlement API request failed with status: ${response.statusCode}`)
	}

	const responseText = Buffer.from(response.body).toString('utf-8')
	console.log('[DEBUG] Response text:', responseText)
	const data = JSON.parse(responseText)

	// Validate and return the parsed payload
	return vmSettlementPayloadSchema.parse(data)
}

// ─── Onchain Write: Settle VM on ClearingHouse ─────────────────────────────

/**
 * Write VM and/or matured position settlement to the ClearingHouse contract.
 * Uses CRE's consensus-signed report mechanism to deliver the data
 * through the KeystoneForwarder → consumer contract flow.
 *
 * The encoded payload matches the `_processReport(uint8, bytes)` signature.
 * - ReportType = 1: VM settlement (isFinal = false)
 * - ReportType = 2: Matured position settlement (isFinal = true)
 */
const writeVMSettlement = (
	runtime: Runtime<Config>,
	evmConfig: Config['evms'][0],
	payload: ValidatedVMSettlementPayload,
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
	
	// TODO remove this testing line in prod
	// the api returns positions with isFinal set to false so for testing purposes:
	payload.settlements.forEach(s => s.isFinal = true);

	// Separate settlements into VM (regular) and matured (final) based on isFinal flag
	const vmSettlements = payload.settlements.filter((s) => !s.isFinal)
	const maturedSettlements = payload.settlements.filter((s) => s.isFinal)

	runtime.log(
		`Settling ${payload.settlements.length} trades on ClearingHouse at ${evmConfig.clearingHouseAddress}`,
	)
	runtime.log(`  - VM settlements (non-final): ${vmSettlements.length}`)
	runtime.log(`  - Matured position settlements (final): ${maturedSettlements.length}`)

	let txHash = ''

	// Process VM settlements (report type 1)
	if (vmSettlements.length > 0) {
		// Log each VM settlement
		for (let i = 0; i < vmSettlements.length; i++) {
			const s = vmSettlements[i]
			runtime.log(`  VM Settlement ${i + 1}: ${toBytes32(s.tradeId)} -> ${s.npvChange}`)
		}

		// ABI-encode the VM settlement data as (uint8, VMSettlement[])
		// ReportType = 1 indicates VM settlement
		// Use struct array encoding to match Solidity contract decoding
		const vmSettlementParams = parseAbiParameters(
			'uint8,(bytes32 tradeId, int256 npvChange)[]',
		)

		// Create struct array as array of objects
		const settlements = vmSettlements.map((s) => ({
			tradeId: toBytes32(s.tradeId),
			npvChange: BigInt(s.npvChange),
		}))

		const reportData = encodeAbiParameters(vmSettlementParams, [
			1, // Report type: 1 = VM settlement
			settlements,
		])

		runtime.log(`Encoded VM report data: ${reportData}`)

		// Step 1: Generate a consensus-signed report
		const reportResponse = runtime
			.report({
				encodedPayload: hexToBase64(reportData),
				encoderName: 'evm',
				signingAlgo: 'ecdsa',
				hashingAlgo: 'keccak256',
			})
			.result()

		// Step 2: Submit the signed report to the ClearingHouse contract
		const resp = evmClient
			.writeReport(runtime, {
				receiver: evmConfig.clearingHouseAddress,
				report: reportResponse,
				gasConfig: {
					gasLimit: evmConfig.gasLimit,
				},
			})
			.result()

		if (resp.txStatus !== TxStatus.SUCCESS) {
			throw new Error(`Failed to settle VM: ${resp.errorMessage || resp.txStatus}`)
		}

		txHash = bytesToHex(resp.txHash || new Uint8Array(32))
		runtime.log(`VM settlement submitted successfully! TxHash: ${txHash}`)
	}

	// Process matured position settlements (report type 2)
	if (maturedSettlements.length > 0) {
		// Log each matured settlement
		for (let i = 0; i < maturedSettlements.length; i++) {
			const s = maturedSettlements[i]
			runtime.log(`  Matured Settlement ${i + 1}: ${toBytes32(s.tradeId)} -> ${s.npvChange}`)
		}

		// ABI-encode the matured position settlement data as (uint8, MaturedPositionSettlement[])
		// ReportType = 2 indicates matured position settlement
		// Use struct array encoding to match Solidity contract decoding
		const maturedSettlementParams = parseAbiParameters(
			'uint8, (bytes32 tradeId, int256 npvChange)[]',
		)

		// Create struct array as array of objects
		const settlements = maturedSettlements.map((s) => ({
			tradeId: toBytes32(s.tradeId),
			npvChange: BigInt(s.npvChange),
		}))

		const reportData = encodeAbiParameters(maturedSettlementParams, [
			2, // Report type: 2 = Matured position settlement
			settlements,
		])

		runtime.log(`Encoded matured position report data: ${reportData}`)

		// Step 1: Generate a consensus-signed report
		const reportResponse = runtime
			.report({
				encodedPayload: hexToBase64(reportData),
				encoderName: 'evm',
				signingAlgo: 'ecdsa',
				hashingAlgo: 'keccak256',
			})
			.result()

		// Step 2: Submit the signed report to the ClearingHouse contract
		const resp = evmClient
			.writeReport(runtime, {
				receiver: evmConfig.clearingHouseAddress,
				report: reportResponse,
				gasConfig: {
					gasLimit: evmConfig.gasLimit,
				},
			})
			.result()

		if (resp.txStatus !== TxStatus.SUCCESS) {
			throw new Error(`Failed to settle matured positions: ${resp.errorMessage || resp.txStatus}`)
		}

		txHash = bytesToHex(resp.txHash || new Uint8Array(32))
		runtime.log(`Matured position settlement submitted successfully! TxHash: ${txHash}`)
	}

	if (payload.settlements.length === 0) {
		runtime.log('No settlements to process')
	}

	return txHash
}


// ─── Main Workflow Logic ────────────────────────────────────────────────────

/**
 * Core workflow execution:
 * 1. Fetch all active positions from novated_positions API
 * 2. Send positions to VM settlement API for NPV calculation (with DON consensus)
 * 3. Write VM settlement to ClearingHouse contract onchain
 */
const executeVMSettlementWorkflow = (runtime: Runtime<Config>): string => {
	runtime.log('=== VM Settlement Workflow Started ===')

	const evmConfig = runtime.config.evms[0]
	const httpCapability = new HTTPClient()

	// ── Step 1: Fetch positions from novated_positions API ────────────────
	runtime.log('Fetching positions from novated_positions API...')
	
	let positions: PositionData[]
	
	// Check if novatedPositions API endpoint is configured
	if (runtime.config.novatedPositions?.apiEndpoint) {
		// Use consensus aggregation for fetching positions (each DON node fetches independently)
		const positionsResponse = httpCapability
			.sendRequest(
				runtime,
				(sendRequester, config) => fetchPositionsFromAPI(runtime, sendRequester, config as Config),
				ConsensusAggregationByFields<PositionsResponse>({
					// Use median for consensus on count
					count: median,
					// Use median for positions array aggregation
					positions: median as any,
				}),
			)(runtime.config)
			.result() as PositionsResponse

		positions = positionsResponse.positions
	} else {
		// Fallback: No novatedPositions API configured, throw error
		throw new Error('Novated Positions API endpoint is not configured')
	}

	runtime.log(`Fetched ${positions.length} active positions from novated_positions API`)

	// ── Step 2: Send positions to VM Settlement API for NPV calculation ───
	let vmSettlementData: ValidatedVMSettlementPayload

		runtime.log(`Sending positions to VM Settlement API: ${runtime.config.vmSettlement?.apiEndpoint}`)
		
		// Use median for aggregation
		vmSettlementData = httpCapability
			.sendRequest(
				runtime,
				(sendRequester, config) => fetchVMSettlementDataWithPositions(sendRequester, config as Config, positions),
				ConsensusAggregationByFields({
					settlements: median as any,
					metadata: median as any,
				}),
			)(runtime.config)
			.result() as ValidatedVMSettlementPayload


	runtime.log(`VM Settlement Data: ${JSON.stringify(vmSettlementData)}`)
	
	if (!vmSettlementData || !vmSettlementData.settlements) {
		throw new Error('Failed to fetch VM settlement data or empty settlements returned')
	}

	// ── Step 3: Write VM settlement onchain ─────────────────────────────
	runtime.log('Writing VM settlement to ClearingHouse...')
	const txHash = writeVMSettlement(runtime, evmConfig, vmSettlementData)

	runtime.log('=== VM Settlement Workflow Completed ===')
	runtime.log(`Trades settled: ${vmSettlementData.settlements.length} | TxHash: ${txHash}`)

	return txHash
}

// ─── Trigger Handlers ───────────────────────────────────────────────────────

const onCronTrigger = (runtime: Runtime<Config>, payload: CronPayload): string => {
	if (!payload.scheduledExecutionTime) {
		throw new Error('Scheduled execution time is required')
	}

	runtime.log('VM Settlement workflow triggered by cron schedule')
	return executeVMSettlementWorkflow(runtime)
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
