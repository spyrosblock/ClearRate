import {
	bytesToHex,
	consensusIdenticalAggregation,
	cre,
	EVMLog,
	getNetwork,
	hexToBase64,
	LAST_FINALIZED_BLOCK_NUMBER,
	Runner,
	type Runtime,
	type HTTPSendRequester,
	ok,
} from '@chainlink/cre-sdk'
import { decodeEventLog, decodeFunctionResult, encodeFunctionData, parseAbi, zeroAddress } from 'viem'
import { z } from 'zod'
import './abi'
import { ClearingHouseABI } from './abi/ClearingHouse'

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

// ─── Position Data from Contract ─────────────────────────────────────────

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
}

type PositionMaturedPayload = {
	action: 'PositionMatured'
	tradeId: string
}

type DatabasePayload = NovatedPositionPayload | PositionMaturedPayload

// ─── Event ABI Parsing ───────────────────────────────────────────────────

const eventAbi = parseAbi([
	'event TradeNovated(bytes32 indexed tradeId, uint256 tokenIdA, uint256 tokenIdB)',
	'event PositionMatured(bytes32 indexed tradeId, uint256 timestamp)',
])

// ─── Read Position from Blockchain ─────────────────────────────────────────

/**
 * Read a position from the ClearingHouse contract by tradeId.
 * This is needed to get the full position details after a TradeNovated event.
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

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	// Full ABI with getPosition function
	const fullAbi = [
		{
			inputs: [{ name: 'tradeId', type: 'bytes32' }],
			name: 'getPosition',
			outputs: [
				{
					components: [
						{ name: 'tradeId', type: 'bytes32' },
						{ name: 'tokenIdA', type: 'uint256' },
						{ name: 'tokenIdB', type: 'uint256' },
						{ name: 'partyA', type: 'bytes32' },
						{ name: 'partyB', type: 'bytes32' },
						{ name: 'notional', type: 'uint256' },
						{ name: 'originalNotional', type: 'uint256' },
						{ name: 'fixedRateBps', type: 'uint256' },
						{ name: 'startDate', type: 'uint256' },
						{ name: 'maturityDate', type: 'uint256' },
						{ name: 'active', type: 'bool' },
						{ name: 'lastNpv', type: 'int256' },
					],
					internalType: 'struct IClearingHouse.NovatedPosition',
					name: '',
					type: 'tuple',
				},
			],
			stateMutability: 'view',
			type: 'function',
		},
	] as const

	// Encode the contract call data for getPosition
	const callData = encodeFunctionData({
		abi: fullAbi,
		functionName: 'getPosition',
		args: [tradeId as `0x${string}`],
	})

	const contractCall = evmClient
		.callContract(runtime, {
			call: {
				from: zeroAddress,
				to: evmConfig.clearingHouseAddress as `0x${string}`,
				data: callData,
			},
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()

	// Check if the call returned empty data
	const callDataHex = bytesToHex(contractCall.data)
	if (!callDataHex || callDataHex === '0x') {
		runtime.log(`Warning: Contract call returned empty data for tradeId ${tradeId}`)
		return null
	}

	// Decode the result using decodeFunctionResult instead of decodeEventLog
	const result = decodeFunctionResult({
		abi: fullAbi,
		functionName: 'getPosition',
		data: callDataHex,
	}) as {
		tradeId: `0x${string}`
		tokenIdA: bigint
		tokenIdB: bigint
		partyA: `0x${string}`
		partyB: `0x${string}`
		notional: bigint
		originalNotional: bigint
		fixedRateBps: bigint
		startDate: bigint
		maturityDate: bigint
		active: boolean
		lastNpv: bigint
	}

	// Check if position exists (tradeId will be empty if not found)
	if (!result || result.tradeId === '0x0000000000000000000000000000000000000000000000000000000000000000') {
		return null
	}

	return {
		tradeId: result.tradeId,
		tokenIdA: result.tokenIdA.toString(),
		tokenIdB: result.tokenIdB.toString(),
		partyA: result.partyA,
		partyB: result.partyB,
		notional: result.notional.toString(),
		originalNotional: result.originalNotional.toString(),
		fixedRateBps: result.fixedRateBps.toString(),
		startDate: result.startDate.toString(),
		maturityDate: result.maturityDate.toString(),
		active: result.active,
		lastNpv: result.lastNpv.toString(),
	}
}

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
	const evmConfig = runtime.config.evms[0]

	// Process based on event type
	if (eventName === 'TradeNovated') {
		const args = decodedLog.args as { tradeId: `0x${string}`; tokenIdA: bigint; tokenIdB: bigint }
		const { tradeId, tokenIdA, tokenIdB } = args

		runtime.log(
			`Event TradeNovated detected: tradeId ${tradeId} | tokenIdA ${tokenIdA} | tokenIdB ${tokenIdB}`,
		)

		// Read full position data from the contract
		const position = readPositionById(runtime, evmConfig, tradeId)

		if (!position) {
			runtime.log(`Warning: Could not read position for tradeId ${tradeId}`)
			// Still try to store with basic info
			const payload: NovatedPositionPayload = {
				action: 'TradeNovated',
				tradeId,
				tokenIdA: tokenIdA.toString(),
				tokenIdB: tokenIdB.toString(),
				partyA: '0x0000000000000000000000000000000000000000000000000000000000000000',
				partyB: '0x0000000000000000000000000000000000000000000000000000000000000000',
				notional: '0',
				originalNotional: '0',
				fixedRateBps: '0',
				startDate: '0',
				maturityDate: '0',
				active: true,
				lastNpv: '0',
			}

			const result = httpClient
				.sendRequest(
					runtime,
					(sendRequester, config) => postToDatabase(sendRequester, config as Config, payload),
					consensusIdenticalAggregation<PostResponse>(),
				)(runtime.config)
				.result()

			runtime.log(`Stored novated trade with limited data. Status: ${result.statusCode}`)
			return 'Success'
		}

		// Prepare the full payload with position data
		const payload: NovatedPositionPayload = {
			action: 'TradeNovated',
			tradeId: position.tradeId,
			tokenIdA: position.tokenIdA,
			tokenIdB: position.tokenIdB,
			partyA: position.partyA,
			partyB: position.partyB,
			notional: position.notional,
			originalNotional: position.originalNotional,
			fixedRateBps: position.fixedRateBps,
			startDate: position.startDate,
			maturityDate: position.maturityDate,
			active: position.active,
			lastNpv: position.lastNpv,
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
