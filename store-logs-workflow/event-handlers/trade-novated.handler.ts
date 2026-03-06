import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext, Config, NovatedPositionPayload, DecodedLogArgs } from '../types'
import { cre, consensusIdenticalAggregation } from '@chainlink/cre-sdk'
import { postToApi } from '../http-utils'

// ─── Type Definitions ───────────────────────────────────────────────────────

export type TradeNovatedArgs = {
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
	newMMA: bigint
	newMMB: bigint
}

// ─── Event Handler ───────────────────────────────────────────────────────────

export const handleTradeNovated: EventHandlerFunction = async (
	context: EventHandlerContext<DecodedLogArgs>,
): Promise<EventHandlerResult> => {
	const { runtime, args, config } = context
	// Cast args to the expected type for this handler
	const typedArgs = args as TradeNovatedArgs

	runtime.log(
		`Event TradeNovated detected: tradeId ${typedArgs.tradeId} | tokenIdA ${typedArgs.tokenIdA} | tokenIdB ${typedArgs.tokenIdB} | partyA ${typedArgs.partyA} | partyB ${typedArgs.partyB} | collateralToken ${typedArgs.collateralToken}`,
	)

	// Prepare the payload with data from the event
	const payload: NovatedPositionPayload = {
		tradeId: typedArgs.tradeId,
		tokenIdA: typedArgs.tokenIdA.toString(),
		tokenIdB: typedArgs.tokenIdB.toString(),
		partyA: typedArgs.partyA,
		partyB: typedArgs.partyB,
		notional: typedArgs.notional.toString(),
		fixedRateBps: typedArgs.fixedRateBps.toString(),
		startDate: typedArgs.startDate.toString(),
		maturityDate: typedArgs.maturityDate.toString(),
		paymentInterval: typedArgs.paymentInterval.toString(),
		dayCountConvention: typedArgs.dayCountConvention,
		floatingRateIndex: typedArgs.floatingRateIndex,
		active: true,
		lastNpv: '0', // Will be calculated by subsequent events
		collateralToken: typedArgs.collateralToken,
		newMMA: typedArgs.newMMA.toString(),
		newMMB: typedArgs.newMMB.toString(),
	}

	runtime.log(`Storing novated position: ${JSON.stringify(payload)}`)

	// Send to database API with consensus
	const httpClient = new cre.capabilities.HTTPClient()
	const result = httpClient
		.sendRequest(
			runtime,
			(sendRequester, cfg) => postToApi(sendRequester, (cfg as Config).novateTradeApi.url, payload),
			consensusIdenticalAggregation<{ statusCode: number }>(),
		)(config)
		.result()

	runtime.log(`Successfully stored novated trade. Status: ${result.statusCode}`)

	return { success: true, message: `Stored novated trade ${typedArgs.tradeId}` }
}