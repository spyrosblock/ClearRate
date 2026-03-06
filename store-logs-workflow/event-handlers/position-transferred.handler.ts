// ─────────────────────────────────────────────────────────────────────────────
// PositionTransferred Event Handler
// Handles the PositionTransferred event from ClearingHouse.sol
// Calls the transfer-position API to update the database
// ─────────────────────────────────────────────────────────────────────────────

import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext, DecodedLogArgs } from '../types'
import { cre, consensusIdenticalAggregation } from '@chainlink/cre-sdk'
import { postToApi } from '../http-utils'

// ─── Type Definitions ───────────────────────────────────────────────────────

export type PositionTransferredArgs = {
	tokenId: bigint                // The token ID of the position
	fromAccount: `0x${string}`     // The sender account ID (bytes32)
	toAccount: `0x${string}`       // The recipient account ID (bytes32)
	amount: bigint                 // The amount (notional) transferred
	collateralToken: `0x${string}` // The collateral token address
	newMMFrom: bigint              // New maintenance margin for sender
	newMMTo: bigint                // New maintenance margin for recipient
}

// ─── Event Handler ───────────────────────────────────────────────────────────

export const handlePositionTransferred: EventHandlerFunction = async (
	context: EventHandlerContext<DecodedLogArgs>,
): Promise<EventHandlerResult> => {
	const { runtime, args, config } = context
	// Cast args to the expected type for this handler
	const typedArgs = args as PositionTransferredArgs

	runtime.log(
		`Event PositionTransferred detected: tokenId ${typedArgs.tokenId} | fromAccount ${typedArgs.fromAccount} | toAccount ${typedArgs.toAccount} | amount ${typedArgs.amount} | collateralToken ${typedArgs.collateralToken} | newMMFrom ${typedArgs.newMMFrom} | newMMTo ${typedArgs.newMMTo}`,
	)

	const httpClient = new cre.capabilities.HTTPClient()

	// Call the transfer-position API
	// The API expects:
	// - tokenId: uint256 token ID of the position
	// - fromAccountId: bytes32 account ID of the sender
	// - toAccountId: bytes32 account ID of the recipient
	// - amount: Amount (notional) transferred
	// - collateralToken: Collateral token address
	// - newMMFrom: New maintenance margin for sender
	// - newMMTo: New maintenance margin for recipient

	const transferPositionUrl = config.transferPositionApi.url

	runtime.log(`Calling transfer-position API at: ${transferPositionUrl}`)

	const result = httpClient
		.sendRequest(
			runtime,
			(sendRequester, _cfg) =>
				postToApi(sendRequester, transferPositionUrl, {
					tokenId: typedArgs.tokenId.toString(),
					fromAccountId: typedArgs.fromAccount,
					toAccountId: typedArgs.toAccount,
					amount: typedArgs.amount.toString(),
					collateralToken: typedArgs.collateralToken,
					newMMFrom: typedArgs.newMMFrom.toString(),
					newMMTo: typedArgs.newMMTo.toString(),
				}),
			consensusIdenticalAggregation<{ statusCode: number }>(),
		)(config)
		.result()

	runtime.log(`Transfer-position API response status: ${result.statusCode}`)

	if (result.statusCode >= 200 && result.statusCode < 300) {
		return { success: true, message: `Successfully processed PositionTransferred for token ${typedArgs.tokenId}` }
	} else {
		return { success: false, message: `Failed to process PositionTransferred - API returned status ${result.statusCode}` }
	}
}