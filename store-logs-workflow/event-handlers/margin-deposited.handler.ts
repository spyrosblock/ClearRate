import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext, Config, GetRecordResponse, DecodedLogArgs } from '../types'
import { cre, consensusIdenticalAggregation } from '@chainlink/cre-sdk'
import { getFromApi, postToApi } from '../http-utils'

// ─── Type Definitions ───────────────────────────────────────────────────────

export type MarginDepositedArgs = {
	accountId: `0x${string}`
	token: `0x${string}`
	amount: bigint
}

// ─── Event Handler ───────────────────────────────────────────────────────────

export const handleMarginDeposited: EventHandlerFunction = (
	context: EventHandlerContext<DecodedLogArgs>,
): EventHandlerResult => {
	const { runtime, args, config } = context
	// Cast args to the expected type for this handler
	const typedArgs = args as MarginDepositedArgs

	runtime.log(
		`Event MarginDeposited detected: accountId ${typedArgs.accountId} | token ${typedArgs.token} | amount ${typedArgs.amount}`,
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

	// If 404, record doesn't exist - create new record
	if (existingRecordResult.statusCode === 404) {
		runtime.log(`Creating new liquidation monitoring record for accountId ${typedArgs.accountId}`)

		const createUrl = `${config.liquidationMonitoringApi.url}/create-record`
		const createResult = httpClient
			.sendRequest(
				runtime,
				(sendRequester, _cfg) =>
					postToApi(sendRequester, createUrl, {
						accountId: typedArgs.accountId,
						totalCollateral: typedArgs.amount.toString(),
						maintenanceMargin: '0',
						collateralToken: typedArgs.token,
					}),
				consensusIdenticalAggregation<{ statusCode: number }>(),
			)(config)
			.result()

		runtime.log(`Successfully created liquidation monitoring record. Status: ${createResult.statusCode}`)
		return { success: true, message: `Created new record for account ${typedArgs.accountId}` }
	}

	// Record exists - parse response and update
	const recordResponse: GetRecordResponse = JSON.parse(existingRecordResult.body)

	if (recordResponse.success && recordResponse.record) {
		const currentCollateral = BigInt(recordResponse.record.totalCollateral)
		const newCollateral = currentCollateral + typedArgs.amount

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