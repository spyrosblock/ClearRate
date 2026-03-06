// ─────────────────────────────────────────────────────────────────────────────
// PositionsAbsorbed Event Handler
// Handles the PositionsAbsorbed event from ClearingHouse.sol
// Calls the absorb-positions API to update the database
// ─────────────────────────────────────────────────────────────────────────────

import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext, DecodedLogArgs } from '../types'
import { cre, consensusIdenticalAggregation } from '@chainlink/cre-sdk'
import { postToApi } from '../http-utils'

// ─── Type Definitions ───────────────────────────────────────────────────────

export type PositionsAbsorbedArgs = {
	fromAccount: `0x${string}`      // The liquidated account ID (bytes32)
	toAccount: `0x${string}`        // The liquidator account ID (bytes32)
	tokenIds: readonly bigint[]     // Array of token IDs transferred
	collateralToken: `0x${string}`  // The collateral token address
	liquidatedTransfer: bigint      // Net collateral transfer amount (int256)
}

// ─── Event Handler ───────────────────────────────────────────────────────────

export const handlePositionsAbsorbed: EventHandlerFunction = async (
	context: EventHandlerContext<DecodedLogArgs>,
): Promise<EventHandlerResult> => {
	const { runtime, args, config } = context
	// Cast args to the expected type for this handler
	const typedArgs = args as PositionsAbsorbedArgs

	runtime.log(
		`Event PositionsAbsorbed detected: fromAccount ${typedArgs.fromAccount} | toAccount ${typedArgs.toAccount} | collateralToken ${typedArgs.collateralToken} | tokenIds count ${typedArgs.tokenIds.length} | liquidatedTransfer ${typedArgs.liquidatedTransfer}`,
	)

	const httpClient = new cre.capabilities.HTTPClient()

	// Call the absorb-positions API
	// The API expects:
	// - liquidatorId: bytes32 account ID of the liquidator (toAccount)
	// - liquidatedId: bytes32 account ID of the liquidated party (fromAccount)
	// - collateralToken: Collateral token address
	// - liquidatedTransfer: Net collateral transfer amount

	const absorbPositionsUrl = config.absorbPositionsApi.url

	runtime.log(`Calling absorb-positions API at: ${absorbPositionsUrl}`)

	const result = httpClient
		.sendRequest(
			runtime,
			(sendRequester, _cfg) =>
				postToApi(sendRequester, absorbPositionsUrl, {
					liquidatedId: typedArgs.fromAccount,
					collateralToken: typedArgs.collateralToken,
					liquidatorId: typedArgs.toAccount,
					liquidatedTransfer: typedArgs.liquidatedTransfer.toString(),
				}),
			consensusIdenticalAggregation<{ statusCode: number }>(),
		)(config)
		.result()

	runtime.log(`Absorb-positions API response status: ${result.statusCode}`)

	if (result.statusCode >= 200 && result.statusCode < 300) {
		return { success: true, message: `Successfully processed PositionsAbsorbed for account ${typedArgs.fromAccount}` }
	} else {
		return { success: false, message: `Failed to process PositionsAbsorbed - API returned status ${result.statusCode}` }
	}
}
