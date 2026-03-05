// ─────────────────────────────────────────────────────────────────────────────
// PositionsAbsorbed Event Handler
// Handles the PositionsAbsorbed event from LiquidationEngine.sol
// Calls the absorb-positions API to update the database
// ─────────────────────────────────────────────────────────────────────────────

import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext, DecodedLogArgs } from '../types'
import { cre, consensusIdenticalAggregation } from '@chainlink/cre-sdk'
import { postToApi } from '../http-utils'

// ─── Type Definitions ───────────────────────────────────────────────────────

export type PositionsAbsorbedArgs = {
	accountId: `0x${string}`        // The liquidated account ID (bytes32)
	collateralToken: `0x${string}`  // The collateral token address
	liquidatorId: `0x${string}`     // The liquidator ID (who absorbed positions)
	premium: bigint                 // The premium paid to the liquidator
}

// ─── Event Handler ───────────────────────────────────────────────────────────

export const handlePositionsAbsorbed: EventHandlerFunction = async (
	context: EventHandlerContext<DecodedLogArgs>,
): Promise<EventHandlerResult> => {
	const { runtime, args, config } = context
	// Cast args to the expected type for this handler
	const typedArgs = args as PositionsAbsorbedArgs

	runtime.log(
		`Event PositionsAbsorbed detected: accountId ${typedArgs.accountId} | collateralToken ${typedArgs.collateralToken} | liquidatorId ${typedArgs.liquidatorId} | premium ${typedArgs.premium}`,
	)

	const httpClient = new cre.capabilities.HTTPClient()

	// Call the absorb-positions API
	// The API expects:
	// - liquidatorId: bytes32 account ID of the liquidator
	// - liquidatedId: bytes32 account ID of the liquidated party (accountId from event)
	// - premium: Premium amount to transfer
	// - collateralToken: Collateral token address

	const absorbPositionsUrl = config.absorbPositionsApi.url

	runtime.log(`Calling absorb-positions API at: ${absorbPositionsUrl}`)

	const result = httpClient
		.sendRequest(
			runtime,
			(sendRequester, _cfg) =>
				postToApi(sendRequester, absorbPositionsUrl, {
					liquidatedId: typedArgs.accountId,
					collateralToken: typedArgs.collateralToken,
					liquidatorId: typedArgs.liquidatorId,
					premium: typedArgs.premium.toString(),
				}),
			consensusIdenticalAggregation<{ statusCode: number }>(),
		)(config)
		.result()

	runtime.log(`Absorb-positions API response status: ${result.statusCode}`)

	if (result.statusCode >= 200 && result.statusCode < 300) {
		return { success: true, message: `Successfully processed PositionsAbsorbed for account ${typedArgs.accountId}` }
	} else {
		return { success: false, message: `Failed to process PositionsAbsorbed - API returned status ${result.statusCode}` }
	}
}