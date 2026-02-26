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
import { encodeAbiParameters, parseAbiParameters } from 'viem'
import { z } from 'zod'
import './abi'

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

// ─── VM Settlement Data Fetching ─────────────────────────────────────────

/**
 * Fetch VM settlement data from the configured API endpoint.
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
		const vmSettlementsArray = vmSettlements.map((s) => ({
			tradeId: toBytes32(s.tradeId),
			npvChange: BigInt(s.npvChange),
		}))

		// Log each VM settlement
		for (let i = 0; i < vmSettlementsArray.length; i++) {
			const s = vmSettlementsArray[i]
			runtime.log(`  VM Settlement ${i + 1}: ${s.tradeId} -> ${s.npvChange}`)
		}

		// ABI-encode the VM settlement data as (uint8, VMSettlement[])
		// ReportType = 1 indicates VM settlement
		const vmSettlementParams = parseAbiParameters(
			'uint8, (bytes32 tradeId, int256 npvChange)[]',
		)
		const reportData = encodeAbiParameters(vmSettlementParams, [
			1, // Report type: 1 = VM settlement
			vmSettlementsArray,
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
		const maturedSettlementsArray = maturedSettlements.map((s) => ({
			tradeId: toBytes32(s.tradeId),
			finalNpvChange: BigInt(s.npvChange),
		}))

		// Log each matured settlement
		for (let i = 0; i < maturedSettlementsArray.length; i++) {
			const s = maturedSettlementsArray[i]
			runtime.log(`  Matured Settlement ${i + 1}: ${s.tradeId} -> ${s.finalNpvChange}`)
		}

		// ABI-encode the matured position settlement data as (uint8, MaturedPositionSettlement[])
		// ReportType = 2 indicates matured position settlement
		const maturedSettlementParams = parseAbiParameters(
			'uint8, (bytes32 tradeId, int256 finalNpvChange)[]',
		)
		const reportData = encodeAbiParameters(maturedSettlementParams, [
			2, // Report type: 2 = Matured position settlement
			maturedSettlementsArray,
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
 * 1. Fetch VM settlement data from API (with DON consensus)
 * 2. Write VM settlement to ClearingHouse contract onchain
 */
const executeVMSettlementWorkflow = (runtime: Runtime<Config>): string => {
	runtime.log('=== VM Settlement Workflow Started ===')

	// ── Step 1: Fetch VM settlement data with consensus ─────────────────
	runtime.log(`Fetching VM settlement data from: ${runtime.config.vmSettlement?.apiEndpoint}`)

	const httpCapability = new HTTPClient()
	
	// Use median for numeric fields - works in simulation
	const vmSettlementData = httpCapability
		.sendRequest(
			runtime,
			fetchVMSettlementData,
			ConsensusAggregationByFields({
				settlements: median,
				metadata: median,
			}),
		)(runtime.config)
		.result()

	runtime.log(`VM Settlement Data: ${JSON.stringify(vmSettlementData)}`)
	
	if (!vmSettlementData || !vmSettlementData.settlements) {
		throw new Error('Failed to fetch VM settlement data or empty settlements returned')
	}

	// ── Step 2: Write VM settlement onchain ─────────────────────────────
	const evmConfig = runtime.config.evms[0]

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
