import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext, Config, GetRecordResponse, DecodedLogArgs } from '../types'
import { cre, consensusIdenticalAggregation } from '@chainlink/cre-sdk'
import { getFromApi, postToApi } from '../http-utils'

// ─── Type Definitions ───────────────────────────────────────────────────────

export type MarginWithdrawnArgs = {
	accountId: `0x${string}`
	token: `0x${string}`
	amount: bigint
}

// ─── Event Handler ───────────────────────────────────────────────────────────

export const handleMarginWithdrawn: EventHandlerFunction = (
	context: EventHandlerContext<DecodedLogArgs>,
): EventHandlerResult => {
	const { runtime, args, config } = context
	// Cast args to the expected type for this handler
	const typedArgs = args as MarginWithdrawnArgs

	runtime.log(
		`Event MarginWithdrawn detected: accountId ${typedArgs.accountId} | token ${typedArgs.token} | amount ${typedArgs.amount}`,
	)

	const httpClient = new cre.capabilities.HTTPClient()

	// Check if record exists for this accountId + collateralToken combination
	const getUrl = `${config.liquidationMonitoringApi.url}?accountId=${typedArgs.accountId}&collateralToken=${typedArgs.token}`

	const existingRecordResult = httpClient
		.sendRequest(
			runtime,
			(sendRequester, _cfg) => getFromApi(sendRequester, getUrl),
			consensusIdenticalAggregation<{ statusCode: number; body: string }>(),
		)(config)
		.result()

	// If 404, record doesn't exist - shouldn't happen for withdrawals
	if (existingRecordResult.statusCode === 404) {
		runtime.log(
			`Warning: MarginWithdrawn event for non-existent account ${typedArgs.accountId} - skipping`,
		)
		return { success: false, message: `Account ${typedArgs.accountId} does not exist` }
	}

	// Record exists - parse response and update
	const recordResponse: GetRecordResponse = JSON.parse(existingRecordResult.body)

	if (recordResponse.success && recordResponse.record) {
		const currentCollateral = BigInt(recordResponse.record.totalCollateral)
		let newCollateral: bigint

		if (typedArgs.amount > currentCollateral) {
			newCollateral = BigInt(0)
		} else {
			newCollateral = currentCollateral - typedArgs.amount
		}

		runtime.log(
			`Updating existing record: currentCollateral ${currentCollateral} -> newCollateral ${newCollateral}`,
		)

		// Update total collateral using the update API
		const updateUrl = `${config.liquidationMonitoringApi.url}/update-total-collateral`
		const updateResult = httpClient
			.sendRequest(
				runtime,
				(sendRequester, _cfg) =>
					postToApi(sendRequester, updateUrl, {
						accountId: typedArgs.accountId,
						totalCollateral: newCollateral.toString(),
						collateralToken: typedArgs.token,
					}),
				consensusIdenticalAggregation<{ statusCode: number }>(),
			)(config)
			.result()

		runtime.log(`Successfully updated total collateral. Status: ${updateResult.statusCode}`)
		return { success: true, message: `Updated collateral for account ${typedArgs.accountId}` }
	}

	runtime.log(
		`Warning: Failed to get record for account ${typedArgs.accountId} - response: ${existingRecordResult.body}`,
	)
	return { success: false, message: `Failed to get record for account ${typedArgs.accountId}` }
}