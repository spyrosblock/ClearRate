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

// ─── Position Reading from Blockchain ─────────────────────────────────────

/**
 * Position data structure matching the NovatedPosition struct from ClearingHouse.
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
 * Read a single position from the ClearingHouse contract by tradeId.
 */
const readPositionById = (
	runtime: Runtime<Config>,
	evmConfig: Config['evms'][0],
	tradeId: string,
): PositionData | null => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: evmConfig.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain: ${evmConfig.chainSelectorName}`)
	}

	const evmClient = new EVMClient(network.chainSelector.selector)

	// Encode the contract call data for getPosition
	const callData = encodeFunctionData({
		abi: ClearingHouseFullABI,
		functionName: 'getPosition',
		args: [tradeId as Address],
	})

	const contractCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: evmConfig.clearingHouseAddress as Address,
				data: callData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	// Decode the result
	const position = decodeFunctionResult({
		abi: ClearingHouseFullABI,
		functionName: 'getPosition',
		data: bytesToHex(contractCall.data),
	})

	// Check if position exists (tradeId will be empty if not found)
	if (!position || position.tradeId === '0x0000000000000000000000000000000000000000000000000000000000000000') {
		return null
	}

	return {
		tradeId: position.tradeId,
		tokenIdA: position.tokenIdA.toString(),
		tokenIdB: position.tokenIdB.toString(),
		partyA: position.partyA,
		partyB: position.partyB,
		notional: position.notional.toString(),
		originalNotional: position.originalNotional.toString(),
		fixedRateBps: position.fixedRateBps.toString(),
		startDate: position.startDate.toString(),
		maturityDate: position.maturityDate.toString(),
		active: position.active,
		lastNpv: position.lastNpv.toString(),
	}
}

/**
 * Read the total count of active positions from the ClearingHouse contract.
 */
const readActivePositionCount = (
	runtime: Runtime<Config>,
	evmConfig: Config['evms'][0],
): bigint => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: evmConfig.chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain: ${evmConfig.chainSelectorName}`)
	}

	const evmClient = new EVMClient(network.chainSelector.selector)

	// Encode the contract call data for activePositionCount
	const callData = encodeFunctionData({
		abi: ClearingHouseFullABI,
		functionName: 'activePositionCount',
	})

	const contractCall = evmClient
		.callContract(runtime, {
			call: encodeCallMsg({
				from: zeroAddress,
				to: evmConfig.clearingHouseAddress as Address,
				data: callData,
			}),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	// Decode the result
	const count = decodeFunctionResult({
		abi: ClearingHouseFullABI,
		functionName: 'activePositionCount',
		data: bytesToHex(contractCall.data),
	})

	return count
}

/**
 * Read all active positions from the ClearingHouse contract.
 * This function queries the blockchain to get all position data needed for VM calculation.
 * 
 * Note: In production, you'd want to use an indexer (e.g., The Graph) for efficient 
 * position enumeration. This implementation provides a basic approach.
 */
const readAllPositionsFromBlockchain = (
	runtime: Runtime<Config>,
	evmConfig: Config['evms'][0],
): PositionData[] => {
	runtime.log('=== Reading Positions from Blockchain ===')

	// Get the active position count
	const activePositionCount = readActivePositionCount(runtime, evmConfig)
	runtime.log(`Active positions count: ${activePositionCount}`)

	if (activePositionCount === 0n) {
		runtime.log('No active positions to settle')
		return []
	}

	// For now, we'll return an empty array if there are no known trade IDs
	// In production, you'd use events or an indexer to get all position IDs
	// This is where you'd integrate with The Graph or similar
	
	// TODO: In production, use event-based position enumeration or maintain an index
	runtime.log('Note: Full position enumeration requires event indexing in production')
	runtime.log('Position reading complete')

	return []
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
	const response = sendRequester.sendRequest({
		method: 'POST',
		url: config.vmSettlement.apiEndpoint,
		body: JSON.stringify({
			positions,
			settlementDate: new Date().toISOString().split('T')[0],
		}),
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
 * 1. Read all positions from the blockchain
 * 2. Send positions to API for NPV calculation (with DON consensus)
 * 3. Write VM settlement to ClearingHouse contract onchain
 */
const executeVMSettlementWorkflow = (runtime: Runtime<Config>): string => {
	runtime.log('=== VM Settlement Workflow Started ===')

	const evmConfig = runtime.config.evms[0]
	const httpCapability = new HTTPClient()

	// ── Step 1: Read positions from blockchain ────────────────────────────
	runtime.log('Reading positions from blockchain...')
	const positions = readAllPositionsFromBlockchain(runtime, evmConfig)
	runtime.log(`Read ${positions.length} positions from blockchain`)

	// ── Step 2: Send positions to API for NPV calculation ────────────────
	// Check if we have positions - if not, fall back to legacy GET method
	let vmSettlementData: ValidatedVMSettlementPayload

	if (positions.length > 0) {
		runtime.log(`Sending positions to API: ${runtime.config.vmSettlement?.apiEndpoint}`)
		
		// Use median for aggregation - works in simulation
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
	} else {
		// Fallback to legacy GET method if no positions found
		runtime.log('No positions found, falling back to legacy API method')
		vmSettlementData = httpCapability
			.sendRequest(
				runtime,
				fetchVMSettlementData,
				ConsensusAggregationByFields({
					settlements: median as any,
					metadata: median as any,
				}),
			)(runtime.config)
			.result() as ValidatedVMSettlementPayload
	}

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
