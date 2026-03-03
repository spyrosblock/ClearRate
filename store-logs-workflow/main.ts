import {
	bytesToHex,
	consensusIdenticalAggregation,
	cre,
	EVMLog,
	getNetwork,
	hexToBase64,
	Runner,
	type Runtime,
	type HTTPSendRequester,
	ok,
} from '@chainlink/cre-sdk'
import { decodeEventLog, parseAbi } from 'viem'
import { z } from 'zod'

// ─── Configuration Schema ───────────────────────────────────────────────────

const configSchema = z.object({
	evms: z.array(
		z.object({
			clearingHouseAddress: z.string(),
			marginVaultAddress: z.string(),
			riskEngineAddress: z.string(),
			chainSelectorName: z.string(),
			gasLimit: z.string(),
		}),
	),
	dbApi: z.object({
		url: z.string(),
	}),
	liquidationMonitoringApi: z.object({
		url: z.string(),
	}),
})

type Config = z.infer<typeof configSchema>

// ─── Database API Response Types ───────────────────────────────────────────

type PostResponse = {
	statusCode: number
	message?: string
}

// ─── Database Payload Types ───────────────────────────────────────────────

type NovatedPositionPayload = {
	action: 'TradeNovated'
	tradeId: string
	tokenIdA: string
	tokenIdB: string
	partyA: string
	partyB: string
	notional: string
	fixedRateBps: string
	startDate: string
	maturityDate: string
	active: boolean
	lastNpv: string
	collateralToken: string
}

type PositionMaturedPayload = {
	action: 'PositionMatured'
	tradeId: string
}

type CreateMarginRecordPayload = {
	accountId: string
	totalCollateral: string
	maintenanceMargin: string
	collateralToken: string
}

type UpdateTotalCollateralPayload = {
	accountId: string
	totalCollateral: string
}

type DatabasePayload = NovatedPositionPayload | PositionMaturedPayload | CreateMarginRecordPayload | UpdateTotalCollateralPayload

// ─── Event ABI Parsing ───────────────────────────────────────────────────

// Full event ABI matching the IClearingHouse.sol, MarginVault.sol, and RiskEngine.sol contracts
const eventAbi = parseAbi([
	'event TradeNovated(bytes32 indexed tradeId, uint256 tokenIdA, uint256 tokenIdB, bytes32 indexed partyA, bytes32 indexed partyB, uint256 notional, uint256 fixedRateBps, uint256 startDate, uint256 maturityDate, uint256 paymentInterval, uint8 dayCountConvention, bytes32 floatingRateIndex, address collateralToken)',
	'event PositionMatured(bytes32 indexed tradeId, uint256 timestamp)',
	'event MarginDeposited(bytes32 indexed accountId, address indexed token, uint256 amount)',
	'event MarginWithdrawn(bytes32 indexed accountId, address indexed token, uint256 amount)',
	'event AccountMMUpdated(bytes32 indexed accountId, address collateralToken, uint256 oldMM, uint256 newMM)',
])

// ─── Database API Communication ───────────────────────────────────────────

/**
 * Send position data to the database API.
 * This function is executed by each DON node independently;
 * results are aggregated via consensus.
 */
const postToDatabase = (
	sendRequester: HTTPSendRequester,
	config: Config,
	payload: DatabasePayload,
): PostResponse => {
	// 1. Prepare the payload for POST request
	const dataToSend = { ...payload }

	// 2. Serialize the data to JSON and encode as bytes
	const bodyBytes = new TextEncoder().encode(JSON.stringify(dataToSend))

	// 3. Convert to base64 for the request
	const body = Buffer.from(bodyBytes).toString('base64')

	// 4. Construct the POST request
	const req = {
		url: config.dbApi.url,
		method: 'POST' as const,
		body,
		headers: {
			'Content-Type': 'application/json',
		},
	}

	// 5. Send the request and wait for the response
	const resp = sendRequester.sendRequest(req).result()

	if (!ok(resp)) {
		throw new Error(`HTTP request failed with status: ${resp.statusCode}`)
	}

	return { statusCode: resp.statusCode }
}

/**
 * Send a GET request to fetch data from an API.
 * Returns a response with statusCode, and optional body.
 * For 404, returns statusCode 404 with empty body instead of null
 * (because consensus cannot handle null values).
 */
const getFromApi = (
	sendRequester: HTTPSendRequester,
	url: string,
): { statusCode: number; body: string } => {
	const req = {
		url,
		method: 'GET' as const,
		headers: {
			'Content-Type': 'application/json',
		},
	}

	const resp = sendRequester.sendRequest(req).result()

	if (!ok(resp)) {
		// For 404, return a response with statusCode 404 and empty body
		// This allows consensus to work properly (cannot handle null)
		if (resp.statusCode === 404) {
			return { statusCode: 404, body: '' }
		}
		throw new Error(`HTTP GET request failed with status: ${resp.statusCode}`)
	}

	// Decode body from Uint8Array to string
	const bodyString = typeof resp.body === 'string' 
		? resp.body 
		: new TextDecoder().decode(resp.body)

	return { statusCode: resp.statusCode, body: bodyString }
}

/**
 * Send a POST request to a specific URL.
 */
const postToApi = (
	sendRequester: HTTPSendRequester,
	url: string,
	payload: Record<string, unknown>,
): PostResponse => {
	const bodyBytes = new TextEncoder().encode(JSON.stringify(payload))
	const body = Buffer.from(bodyBytes).toString('base64')

	const req = {
		url,
		method: 'POST' as const,
		body,
		headers: {
			'Content-Type': 'application/json',
		},
	}

	const resp = sendRequester.sendRequest(req).result()

	if (!ok(resp)) {
		throw new Error(`HTTP POST request failed with status: ${resp.statusCode}`)
	}

	return { statusCode: resp.statusCode }
}

// ─── Liquidation Monitoring Response Types ─────────────────────────────────

type LiquidationMonitoringRecord = {
	id: number
	accountId: string
	totalCollateral: string
	maintenanceMargin: string
	collateralToken: string
	createdAt: string
	updatedAt: string
}

type GetRecordResponse = {
	success: boolean
	record?: LiquidationMonitoringRecord
	message?: string
}

// ─── Event Log Trigger Handler ─────────────────────────────────────────────

const onLogTrigger = (runtime: Runtime<Config>, log: EVMLog): string => {
	runtime.log('=== Store Logs Workflow: New Event Detected ===')

	const topics = log.topics.map((topic) => bytesToHex(topic)) as [
		`0x${string}`,
		...`0x${string}`[],
	]
	const data = bytesToHex(log.data)

	runtime.log(`Topics: ${JSON.stringify(topics)}`)
	runtime.log(`Data: ${data}`)

	// Decode the event
	const decodedLog = decodeEventLog({
		abi: eventAbi,
		data,
		topics,
	})

	const eventName = decodedLog.eventName as string
	runtime.log(`Event name: ${eventName}`)

	const httpClient = new cre.capabilities.HTTPClient()

	// Process based on event type
	if (eventName === 'TradeNovated') {
		// Extract all fields from the event (no blockchain reading needed)
		const args = decodedLog.args as {
			tradeId: `0x${string}`
			tokenIdA: bigint
			tokenIdB: bigint
			partyA: `0x${string}`
			partyB: `0x${string}`
			notional: bigint
			fixedRateBps: bigint
			startDate: bigint
			maturityDate: bigint
			paymentInterval: bigint
			dayCountConvention: number
			floatingRateIndex: `0x${string}`
			collateralToken: `0x${string}`
		}
		const { tradeId, tokenIdA, tokenIdB, partyA, partyB, notional, fixedRateBps, startDate, maturityDate, collateralToken } = args

		runtime.log(
			`Event TradeNovated detected: tradeId ${tradeId} | tokenIdA ${tokenIdA} | tokenIdB ${tokenIdB} | partyA ${partyA} | partyB ${partyB} | collateralToken ${collateralToken}`,
		)

		// Prepare the payload with data from the event
		const payload: NovatedPositionPayload = {
			action: 'TradeNovated',
			tradeId,
			tokenIdA: tokenIdA.toString(),
			tokenIdB: tokenIdB.toString(),
			partyA,
			partyB,
			notional: notional.toString(),
			fixedRateBps: fixedRateBps.toString(),
			startDate: startDate.toString(),
			maturityDate: maturityDate.toString(),
			active: true,
			lastNpv: '0', // Will be calculated by subsequent events
			collateralToken,
		}

		runtime.log(`Storing novated position: ${JSON.stringify(payload)}`)

		// Send to database API with consensus
		const result = httpClient
			.sendRequest(
				runtime,
				(sendRequester, config) => postToDatabase(sendRequester, config as Config, payload),
				consensusIdenticalAggregation<PostResponse>(),
			)(runtime.config)
			.result()

		runtime.log(`Successfully stored novated trade. Status: ${result.statusCode}`)
	} else if (eventName === 'PositionMatured') {
		const args = decodedLog.args as { tradeId: `0x${string}`; timestamp: bigint }
		const { tradeId, timestamp } = args

		runtime.log(`Event PositionMatured detected: tradeId ${tradeId} | timestamp ${timestamp}`)

		// Prepare the payload to update the position as inactive
		const payload: PositionMaturedPayload = {
			action: 'PositionMatured',
			tradeId,
		}

		runtime.log(`Updating position to inactive: ${JSON.stringify(payload)}`)

		// Send to database API with consensus
		const result = httpClient
			.sendRequest(
				runtime,
				(sendRequester, config) => postToDatabase(sendRequester, config as Config, payload),
				consensusIdenticalAggregation<PostResponse>(),
			)(runtime.config)
			.result()

		runtime.log(`Successfully updated position to inactive. Status: ${result.statusCode}`)
	} else if (eventName === 'MarginDeposited' || eventName === 'MarginWithdrawn') {
		const args = decodedLog.args as { 
			accountId: `0x${string}`
			token: `0x${string}`
			amount: bigint 
		}
		const { accountId, token, amount } = args

		runtime.log(
			`Event ${eventName} detected: accountId ${accountId} | token ${token} | amount ${amount}`,
		)

		// Check if record exists for this accountId + collateralToken combination
		const getUrl = `${runtime.config.liquidationMonitoringApi.url}?accountId=${accountId}&collateralToken=${token}`
		
		const existingRecordResult = httpClient
			.sendRequest(
				runtime,
				(sendRequester, _config) => getFromApi(sendRequester, getUrl),
				consensusIdenticalAggregation<{ statusCode: number; body: string }>(),
			)(runtime.config)
			.result()

		// If 404, record doesn't exist - create new record
		if (existingRecordResult.statusCode === 404) {
			// Record doesn't exist - create new record
			// Only create for MarginDeposited (MarginWithdrawn shouldn't happen for non-existent accounts)
			if (eventName === 'MarginDeposited') {
				runtime.log(`Creating new liquidation monitoring record for accountId ${accountId}`)

				const createUrl = `${runtime.config.liquidationMonitoringApi.url}/create-record`
				const createResult = httpClient
					.sendRequest(
						runtime,
						(sendRequester, _config) =>
							postToApi(sendRequester, createUrl, {
								accountId,
								totalCollateral: amount.toString(),
								maintenanceMargin: '0',
								collateralToken: token,
							}),
						consensusIdenticalAggregation<PostResponse>(),
					)(runtime.config)
					.result()

				runtime.log(`Successfully created liquidation monitoring record. Status: ${createResult.statusCode}`)
			} else {
				runtime.log(
					`Warning: MarginWithdrawn event for non-existent account ${accountId} - skipping`,
				)
			}
		} else {
			// Record exists - parse response and update
			const recordResponse: GetRecordResponse = JSON.parse(existingRecordResult.body)

			if (recordResponse.success && recordResponse.record) {
				const currentCollateral = BigInt(recordResponse.record.totalCollateral)
				let newCollateral: bigint

				if (eventName === 'MarginDeposited') {
					newCollateral = currentCollateral + amount
				} else {
					// MarginWithdrawn
					if (amount > currentCollateral) {
						newCollateral = BigInt(0)
					} else {
						newCollateral = currentCollateral - amount
					}
				}

				runtime.log(
					`Updating existing record: currentCollateral ${currentCollateral} -> newCollateral ${newCollateral}`,
				)

				// Update total collateral using the update API
				const updateUrl = `${runtime.config.liquidationMonitoringApi.url}/update-total-collateral`
				const updateResult = httpClient
					.sendRequest(
						runtime,
						(sendRequester, _config) =>
							postToApi(sendRequester, updateUrl, {
								accountId,
								totalCollateral: newCollateral.toString(),
								collateralToken: token,
							}),
						consensusIdenticalAggregation<PostResponse>(),
					)(runtime.config)
					.result()

				runtime.log(`Successfully updated total collateral. Status: ${updateResult.statusCode}`)
			} else {
				runtime.log(
					`Warning: Failed to get record for account ${accountId} - response: ${existingRecordResult.body}`,
				)
			}
		}
	} else if (eventName === 'AccountMMUpdated') {
		const args = decodedLog.args as {
			accountId: `0x${string}`
			collateralToken: `0x${string}`
			oldMM: bigint
			newMM: bigint
		}
		const { accountId, collateralToken, oldMM, newMM } = args

		runtime.log(
			`Event AccountMMUpdated detected: accountId ${accountId} | collateralToken ${collateralToken} | oldMM ${oldMM} | newMM ${newMM}`,
		)

		// Update maintenance margin using the liquidation monitoring API
		const updateUrl = `${runtime.config.liquidationMonitoringApi.url}/update-maintenance-margin`
		const updateResult = httpClient
			.sendRequest(
				runtime,
				(sendRequester, _config) =>
					postToApi(sendRequester, updateUrl, {
						accountId,
						maintenanceMargin: newMM.toString(),
						collateralToken,
					}),
				consensusIdenticalAggregation<PostResponse>(),
			)(runtime.config)
			.result()

		runtime.log(`Successfully updated maintenance margin. Status: ${updateResult.statusCode}`)
	} else {
		runtime.log(`Unknown event: ${eventName}`)
		return 'Unknown event'
	}

	return 'Success'
}

// ─── Workflow Initialization ───────────────────────────────────────────────

const initWorkflow = (config: Config) => {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.evms[0].chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(`Network not found for chain selector name: ${config.evms[0].chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// Listen to events from ClearingHouse, MarginVault, and RiskEngine contracts
	return [
		cre.handler(
			evmClient.logTrigger({
				addresses: [
					hexToBase64(config.evms[0].clearingHouseAddress),
					hexToBase64(config.evms[0].marginVaultAddress),
					hexToBase64(config.evms[0].riskEngineAddress),
				],
			}),
			onLogTrigger,
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
