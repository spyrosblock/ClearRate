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
			chainSelectorName: z.string(),
			gasLimit: z.string(),
		}),
	),
	dbApi: z.object({
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
	originalNotional: string
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

type DatabasePayload = NovatedPositionPayload | PositionMaturedPayload

// ─── Event ABI Parsing ───────────────────────────────────────────────────

// Full event ABI matching the IClearingHouse.sol contract
const eventAbi = parseAbi([
	'event TradeNovated(bytes32 indexed tradeId, uint256 tokenIdA, uint256 tokenIdB, bytes32 indexed partyA, bytes32 indexed partyB, uint256 notional, uint256 fixedRateBps, uint256 startDate, uint256 maturityDate, uint256 paymentInterval, uint8 dayCountConvention, bytes32 floatingRateIndex, address collateralToken)',
	'event PositionMatured(bytes32 indexed tradeId, uint256 timestamp)',
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
		// Note: originalNotional equals notional at novation time, lastNpv is 0 as it's calculated later
		const payload: NovatedPositionPayload = {
			action: 'TradeNovated',
			tradeId,
			tokenIdA: tokenIdA.toString(),
			tokenIdB: tokenIdB.toString(),
			partyA,
			partyB,
			notional: notional.toString(),
			originalNotional: notional.toString(), // At novation, originalNotional = notional
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

	return [
		cre.handler(
			evmClient.logTrigger({
				addresses: [hexToBase64(config.evms[0].clearingHouseAddress)],
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
