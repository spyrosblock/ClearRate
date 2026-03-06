import {
	bytesToHex,
	cre,
	EVMLog,
	getNetwork,
	hexToBase64,
	Runner,
	type Runtime,
} from '@chainlink/cre-sdk'
import { decodeEventLog, parseAbi } from 'viem'
import { configSchema, type Config, type EventHandlerContext } from './types'
import { isRegisteredEvent, executeHandler, type EventName } from './event-handlers'

// ─── Event ABI Parsing ───────────────────────────────────────────────────

// Full event ABI matching the IClearingHouse.sol, MarginVault.sol, RiskEngine.sol, and LiquidationEngine.sol contracts
const eventAbi = parseAbi([
	'event TradeNovated(bytes32 indexed tradeId, uint256 tokenIdA, uint256 tokenIdB, bytes32 indexed partyA, bytes32 indexed partyB, uint256 notional, uint256 fixedRateBps, uint256 startDate, uint256 maturityDate, uint256 paymentInterval, uint8 dayCountConvention, bytes32 floatingRateIndex, address collateralToken, uint256 newMMA, uint256 newMMB)',
	'event PositionMatured(uint256 indexed tokenId, bytes32 indexed accountId, uint256 newMM)',
	'event MarginDeposited(bytes32 indexed accountId, address indexed token, uint256 amount)',
	'event MarginWithdrawn(bytes32 indexed accountId, address indexed token, uint256 amount)',
	'event PositionsAbsorbed(bytes32 indexed fromAccount, bytes32 indexed toAccount, uint256[] tokenIds, address collateralToken, int256 liquidatedTransfer, uint256 newMMLiquidated, uint256 newMMLiquidator)',
	'event PositionTransferred(uint256 indexed tokenId, bytes32 indexed fromAccount, bytes32 indexed toAccount, uint256 amount, address collateralToken, uint256 newMMFrom, uint256 newMMTo)',
])

// ─── Event Log Trigger Handler ─────────────────────────────────────────────

const onLogTrigger = async (runtime: Runtime<Config>, log: EVMLog): Promise<string> => {
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

	// Check if event is registered in the handler registry
	if (!isRegisteredEvent(eventName)) {
		runtime.log(`Unknown event: ${eventName}`)
		return 'Unknown event'
	}

	// Create handler context
	const context: EventHandlerContext = {
		runtime,
		args: decodedLog.args as Record<string, unknown>,
		config: runtime.config,
	}

	// Execute the registered handler
	const result = await executeHandler(eventName as EventName, context)

	runtime.log(`Handler result: ${result.message}`)

	return result.success ? 'Success' : `Failed: ${result.message}`
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

	// Listen to events from ClearingHouse, MarginVault, RiskEngine, and LiquidationEngine contracts
	return [
		cre.handler(
			evmClient.logTrigger({
				addresses: [
					hexToBase64(config.evms[0].clearingHouseAddress),
					hexToBase64(config.evms[0].marginVaultAddress),
					hexToBase64(config.evms[0].riskEngineAddress),
					hexToBase64(config.evms[0].liquidationEngineAddress),
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