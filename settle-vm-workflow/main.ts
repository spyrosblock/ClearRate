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
			clearingHouseAddress: z.string(),
			chainSelectorName: z.string(),
			gasLimit: z.string(),
		}),
	),
	vmSettlement: z.object({
		apiEndpoint: z.string(),
		fallbackEnabled: z.boolean(),
	}).optional(),
	updateTotalCollateral: z.object({
		apiEndpoint: z.string(),
	}).optional(),
	isFinal: z.boolean().optional(),
})

type Config = z.infer<typeof configSchema>

// ─── VM Settlement Payload Schema ─────────────────────────────────────────

/**
 * Expected API response structure from the settlement endpoint.
 * 
 * Example API response:
 * ```json
 * {
 *   "npvChanges": [
 *     {
 *       "tokenId": "1234567890abcdef...",
 *       "npvChange": "1000000000000000000",
 *       "isFinal": false
 *     }
 *   ],
 *   "vmSettlements": [
 *     {
 *       "accountId": "0x...",
 *       "collateralToken": "0x...",
 *       "vmChange": "1000000000000000000"
 *     }
 *   ],
 *   "maturedPositions": [
 *     {
 *       "accountId": "0x...",
 *       "tokenId": "1234567890abcdef..."
 *     }
 *   ],
 *   "metadata": {
 *     "settlementDate": "2026-02-25",
 *     "npvSource": "internal"
 *   }
 * }
 * ```
 * 
 * - tokenId: uint256 as string (ERC-1155 token ID)
 * - npvChange: string representation of int256 (positive = NPV increased from fixed payer's perspective)
 * - isFinal: boolean indicating if this is a final matured position settlement (true) or regular VM settlement (false)
 * - maturedPositions: array of positions to close (only used for final settlements)
 */
const vmSettlementPayloadSchema = z.object({
	npvChanges: z.array(
		z.object({
			tokenId: z.string(),
			npvChange: z.string(), // Can be positive or negative
			isFinal: z.boolean(), // true = matured position settlement, false = regular VM
		}),
	),
	vmSettlements: z.array(
		z.object({
			accountId: z.string(),
			collateralToken: z.string(),
			vmChange: z.string(),
		}),
	),
	maturedPositions: z.array(
		z.object({
			accountId: z.string(),
			tokenId: z.string(),
		}),
	).optional(),
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

/**
 * Safely convert a string (including scientific notation) to BigInt.
 * Handles values like "1e+22" -> 10000000000000000000000n
 */
const toBigIntSafe = (value: string): bigint => {
	const trimmed = value.trim()

	// If it doesn't contain 'e' or 'E', directly convert to BigInt
	if (!trimmed.toLowerCase().includes('e')) {
		return BigInt(trimmed)
	}

	// Handle scientific notation
	// e.g., "1e+22" -> 10000000000000000000000n
	// e.g., "-1e+22" -> -10000000000000000000000n
	// e.g., "1.5e+3" -> 1500n

	const isNegative = trimmed.startsWith('-')
	const absStr = isNegative ? trimmed.slice(1) : trimmed

	const [base, expStr] = absStr.toLowerCase().split('e')
	const exponent = parseInt(expStr, 10)

	// Handle decimal point in base
	const [intPart, decPart = ''] = base.split('.')
	const decimalPlaces = decPart.length

	// Combine all digits
	const digits = intPart + decPart

	// Calculate the shift needed
	const shift = exponent - decimalPlaces

	if (shift < 0) {
		throw new Error(`Cannot convert ${value} to BigInt: result would be fractional`)
	}

	// Build the result string
	const resultStr = digits + '0'.repeat(shift)
	const result = BigInt(resultStr)

	return isNegative ? -result : result
}

// ─── VM Settlement Data Fetching ────────────────────────────────────────────

/**
 * Fetch VM settlement data from the API.
 * This function is executed by each DON node independently;
 * results are aggregated via median consensus.
 * 
 * The API now queries positions internally, so no need to pass them.
 */
const fetchVMSettlement = (
	sendRequester: HTTPSendRequester,
	config: Config,
): ValidatedVMSettlementPayload => {
	if (!config.vmSettlement?.apiEndpoint) {
		throw new Error('VM Settlement API endpoint is not configured')
	}

	// Call the API via POST (no positions needed - API queries them internally)
	const response = sendRequester.sendRequest({
		method: 'POST',
		url: config.vmSettlement.apiEndpoint,
		body: Buffer.from(JSON.stringify({})).toString('base64'),
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

// ─── Update Total Collateral after Settlement ─────────────────────────────

/**
 * Update total collateral for accounts after VM settlement.
 * 
 * Uses the vmSettlements array from the API response, which already contains
 * aggregated VM changes by account and collateral token.
 */
const updateTotalCollateral = (
	runtime: Runtime<Config>,
	sendRequester: HTTPSendRequester,
	config: Config,
	vmSettlements: ValidatedVMSettlementPayload['vmSettlements'],
): void => {
	if (!config.updateTotalCollateral?.apiEndpoint) {
		runtime.log('Update Total Collateral API endpoint not configured, skipping collateral update')
		return
	}

	if (vmSettlements.length === 0) {
		runtime.log('No VM settlements to process for collateral update')
		return
	}

	runtime.log(`Updating collateral for ${vmSettlements.length} account/token combinations`)

	// Call update-total-collateral API for each vmSettlement entry
	for (const settlement of vmSettlements) {
		runtime.log(`  Account: ${settlement.accountId}`)
		runtime.log(`  Token: ${settlement.collateralToken}`)
		runtime.log(`  VM Change: ${settlement.vmChange}`)

		const requestBody = JSON.stringify({
			accountId: settlement.accountId,
			collateralToken: settlement.collateralToken,
			npvChange: settlement.vmChange,
		})

		const response = sendRequester.sendRequest({
			method: 'POST',
			url: config.updateTotalCollateral.apiEndpoint,
			body: Buffer.from(requestBody).toString('base64'),
			headers: {
				'Content-Type': 'application/json',
			},
		}).result()

		if (response.statusCode !== 200) {
			const responseText = Buffer.from(response.body).toString('utf-8')
			runtime.log(`Warning: Failed to update collateral for ${settlement.accountId}: ${responseText}`)
		} else {
			runtime.log(`  Successfully updated collateral for ${settlement.accountId}`)
		}
	}
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
	// the api is mocked and returns positions with isFinal set to false
	// so if you can use the final-config.staging.json file to test final settlements
	if (runtime.config.isFinal) payload.npvChanges.forEach(s => s.isFinal = true);
	runtime.log(`Config: isFinal=${runtime.config.isFinal}`)

	// Separate settlements into VM (regular) and matured (final) based on isFinal flag
	const vmSettlements = payload.npvChanges.filter((s) => !s.isFinal)
	const maturedSettlements = payload.npvChanges.filter((s) => s.isFinal)

	runtime.log(
		`Settling ${payload.npvChanges.length} trades on ClearingHouse at ${evmConfig.clearingHouseAddress}`,
	)
	runtime.log(`  - VM settlements (non-final): ${vmSettlements.length}`)
	runtime.log(`  - Matured position settlements (final): ${maturedSettlements.length}`)

	let txHash = ''

	// Process VM settlements (report type 1)
	if (vmSettlements.length > 0) {
		// Log each VM settlement
		for (let i = 0; i < vmSettlements.length; i++) {
			const s = vmSettlements[i]
			runtime.log(`  VM Settlement ${i + 1}: Token ${s.tokenId} -> ${s.npvChange}`)
		}

		// ABI-encode the VM settlement data as (uint8, NPVChange[], VMSettlement[])
		// ReportType = 1 indicates VM settlement
		// The contract expects BOTH npvChanges AND vmSettlements arrays
		const vmSettlementParams = parseAbiParameters(
			'uint8, (uint256 tokenId, int256 npvChange)[], (bytes32 accountId, address collateralToken, int256 vmChange)[]',
		)

		// Create NPVChange struct array
		const npvChangeArray = vmSettlements.map((s) => ({
			tokenId: toBigIntSafe(s.tokenId),
			npvChange: toBigIntSafe(s.npvChange),
		}))

		// Create VMSettlement struct array from the API response
		const vmSettlementArray = payload.vmSettlements.map((s) => ({
			accountId: toBytes32(s.accountId),
			collateralToken: s.collateralToken as Address,
			vmChange: toBigIntSafe(s.vmChange),
		}))

		const reportData = encodeAbiParameters(vmSettlementParams, [
			1, // Report type: 1 = VM settlement
			npvChangeArray,
			vmSettlementArray,
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
			runtime.log(`  Matured Settlement ${i + 1}: Token ${s.tokenId} -> ${s.npvChange}`)
		}

		// ABI-encode the matured position settlement data as (uint8, NPVChange[], VMSettlement[], MaturedPosition[])
		// ReportType = 2 indicates matured position settlement
		// The contract expects npvChanges, vmSettlements, AND maturedPositions arrays
		const maturedSettlementParams = parseAbiParameters(
			'uint8, (uint256 tokenId, int256 npvChange)[], (bytes32 accountId, address collateralToken, int256 vmChange)[], (bytes32 accountId, uint256 tokenId)[]',
		)

		// Create NPVChange struct array
		const npvChangeArray = maturedSettlements.map((s) => ({
			tokenId: toBigIntSafe(s.tokenId),
			npvChange: toBigIntSafe(s.npvChange),
		}))

		// Create VMSettlement struct array from the API response
		const vmSettlementArray = payload.vmSettlements.map((s) => ({
			accountId: toBytes32(s.accountId),
			collateralToken: s.collateralToken as Address,
			vmChange: toBigIntSafe(s.vmChange),
		}))

		// Create MaturedPosition struct array from the API response
		// These are the positions that will be closed after settlement
		// IMPORTANT: Only include matured positions whose tokenId matches a matured settlement
		const maturedSettlementTokenIds = new Set(maturedSettlements.map((s) => s.tokenId))
		const maturedPositionsArray = (payload.maturedPositions || [])
			.filter((p) => maturedSettlementTokenIds.has(p.tokenId))
			.map((p) => ({
				accountId: toBytes32(p.accountId),
				tokenId: toBigIntSafe(p.tokenId),
			}))

		runtime.log(`  Including ${maturedPositionsArray.length} matured positions to close`)

		const reportData = encodeAbiParameters(maturedSettlementParams, [
			2, // Report type: 2 = Matured position settlement
			npvChangeArray,
			vmSettlementArray,
			maturedPositionsArray,
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

	if (payload.npvChanges.length === 0) {
		runtime.log('No settlements to process')
	}

	return txHash
}


// ─── Main Workflow Logic ────────────────────────────────────────────────────

/**
 * Core workflow execution:
 * 1. Fetch VM settlement data from the API (API queries positions internally)
 * 2. Write VM settlement to ClearingHouse contract onchain
 * 3. Update total collateral for affected accounts
 */
const executeVMSettlementWorkflow = (runtime: Runtime<Config>): string => {
	runtime.log('=== VM Settlement Workflow Started ===')

	const evmConfig = runtime.config.evms[0]
	const httpCapability = new HTTPClient()

	// ── Step 1: Fetch VM Settlement Data from API ─────────────────────────
	runtime.log(`Fetching VM settlement data from API: ${runtime.config.vmSettlement?.apiEndpoint}`)
	
	const vmSettlementData = httpCapability
		.sendRequest(
			runtime,
			(sendRequester, config) => fetchVMSettlement(sendRequester, config as Config),
			ConsensusAggregationByFields({
				npvChanges: median as any,
				vmSettlements: median as any,
				maturedPositions: median as any,
				metadata: median as any,
			}),
		)(runtime.config)
		.result() as ValidatedVMSettlementPayload

	runtime.log(`VM Settlement Data: ${JSON.stringify(vmSettlementData)}`)
	
	if (!vmSettlementData || !vmSettlementData.npvChanges) {
		throw new Error('Failed to fetch VM settlement data or empty npvChanges returned')
	}

	// ── Step 2: Write VM settlement onchain ─────────────────────────────
	runtime.log('Writing VM settlement to ClearingHouse...')
	const txHash = writeVMSettlement(runtime, evmConfig, vmSettlementData)

	// ── Step 3: Update total collateral in liquidation monitoring ───────
	runtime.log('Updating total collateral for settled accounts...')
	httpCapability
		.sendRequest(
			runtime,
			(sendRequester, config) => {
				updateTotalCollateral(runtime, sendRequester, config as Config, vmSettlementData.vmSettlements)
				return { success: true }
			},
			ConsensusAggregationByFields({
				success: median,
			}),
		)(runtime.config)
		.result()

	runtime.log('=== VM Settlement Workflow Completed ===')
	runtime.log(`Trades settled: ${vmSettlementData.npvChanges.length} | TxHash: ${txHash}`)

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