import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext, Config, PositionMaturedPayload, DecodedLogArgs } from '../types'
import { cre, consensusIdenticalAggregation } from '@chainlink/cre-sdk'
import { postToApi } from '../http-utils'

// ─── Type Definitions ───────────────────────────────────────────────────────

export type PositionMaturedArgs = {
	tokenId: bigint
	accountId: `0x${string}`
	timestamp: bigint
}

// ─── Event Handler ───────────────────────────────────────────────────────────

export const handlePositionMatured: EventHandlerFunction = (
	context: EventHandlerContext<DecodedLogArgs>,
): EventHandlerResult => {
	const { runtime, args, config } = context
	// Cast args to the expected type for this handler
	const typedArgs = args as PositionMaturedArgs

	runtime.log(
		`Event PositionMatured detected: tokenId ${typedArgs.tokenId} | accountId ${typedArgs.accountId} | timestamp ${typedArgs.timestamp}`,
	)

	// Prepare the payload to update the position as inactive
	const payload: PositionMaturedPayload = {
		tokenId: typedArgs.tokenId.toString(),
		accountId: typedArgs.accountId,
	}

	runtime.log(`Updating position to inactive: ${JSON.stringify(payload)}`)

	// Send to database API with consensus
	const httpClient = new cre.capabilities.HTTPClient()
	const result = httpClient
		.sendRequest(
			runtime,
			(sendRequester, cfg) => postToApi(sendRequester, (cfg as Config).positionMaturedApi.url, payload),
			consensusIdenticalAggregation<{ statusCode: number }>(),
		)(config)
		.result()

	runtime.log(`Successfully updated position to inactive. Status: ${result.statusCode}`)

	return { success: true, message: `Updated position ${typedArgs.tokenId} to inactive` }
}