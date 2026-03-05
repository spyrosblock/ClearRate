import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext, Config, DecodedLogArgs } from '../types'
import { cre, consensusIdenticalAggregation } from '@chainlink/cre-sdk'
import { postToApi } from '../http-utils'

// ─── Type Definitions ───────────────────────────────────────────────────────

export type AccountMMUpdatedArgs = {
	accountId: `0x${string}`
	collateralToken: `0x${string}`
	oldMM: bigint
	newMM: bigint
}

// ─── Event Handler ───────────────────────────────────────────────────────────

export const handleAccountMMUpdated: EventHandlerFunction = (
	context: EventHandlerContext<DecodedLogArgs>,
): EventHandlerResult => {
	const { runtime, args, config } = context
	// Cast args to the expected type for this handler
	const typedArgs = args as AccountMMUpdatedArgs

	runtime.log(
		`Event AccountMMUpdated detected: accountId ${typedArgs.accountId} | collateralToken ${typedArgs.collateralToken} | oldMM ${typedArgs.oldMM} | newMM ${typedArgs.newMM}`,
	)

	// Update maintenance margin using the liquidation monitoring API
	const updateUrl = `${config.liquidationMonitoringApi.url}/update-maintenance-margin`
	const httpClient = new cre.capabilities.HTTPClient()

	const updateResult = httpClient
		.sendRequest(
			runtime,
			(sendRequester, _cfg) =>
				postToApi(sendRequester, updateUrl, {
					accountId: typedArgs.accountId,
					maintenanceMargin: typedArgs.newMM.toString(),
					collateralToken: typedArgs.collateralToken,
				}),
			consensusIdenticalAggregation<{ statusCode: number }>(),
		)(config)
		.result()

	runtime.log(`Successfully updated maintenance margin. Status: ${updateResult.statusCode}`)

	return { success: true, message: `Updated maintenance margin for account ${typedArgs.accountId}` }
}