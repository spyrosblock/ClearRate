import { z } from 'zod'

// ─── Configuration Schema ───────────────────────────────────────────────────

export const configSchema = z.object({
	evms: z.array(
		z.object({
			clearingHouseAddress: z.string(),
			marginVaultAddress: z.string(),
			riskEngineAddress: z.string(),
			liquidationEngineAddress: z.string(),
			chainSelectorName: z.string(),
			gasLimit: z.string(),
		}),
	),
	novateTradeApi: z.object({
		url: z.string(),
	}),
	liquidationMonitoringApi: z.object({
		url: z.string(),
	}),
	absorbPositionsApi: z.object({
		url: z.string(),
	}),
	positionMaturedApi: z.object({
		url: z.string(),
	}),
	transferPositionApi: z.object({
		url: z.string(),
	}),
})

export type Config = z.infer<typeof configSchema>

// ─── Database API Response Types ───────────────────────────────────────────

export type PostResponse = {
	statusCode: number
	message?: string
}

export type GetResponse = {
	statusCode: number
	body: string
}

// ─── Database Payload Types ───────────────────────────────────────────────

export type NovatedPositionPayload = {
	tradeId: string
	tokenIdA: string
	tokenIdB: string
	partyA: string
	partyB: string
	notional: string
	fixedRateBps: string
	startDate: string
	maturityDate: string
	paymentInterval: string
	dayCountConvention: number
	floatingRateIndex: string
	active: boolean
	lastNpv: string
	collateralToken: string
	newMMA: string
	newMMB: string
}

export type PositionMaturedPayload = {
	tokenId: string
	accountId: string
	newMM: string
}

export type CreateMarginRecordPayload = {
	accountId: string
	totalCollateral: string
	maintenanceMargin: string
	collateralToken: string
}

export type UpdateTotalCollateralPayload = {
	accountId: string
	totalCollateral: string
	collateralToken: string
}

export type UpdateMaintenanceMarginPayload = {
	accountId: string
	maintenanceMargin: string
	collateralToken: string
}

export type DatabasePayload =
	| NovatedPositionPayload
	| PositionMaturedPayload
	| CreateMarginRecordPayload
	| UpdateTotalCollateralPayload
	| UpdateMaintenanceMarginPayload

// ─── Liquidation Monitoring Response Types ─────────────────────────────────

export type LiquidationMonitoringRecord = {
	id: number
	accountId: string
	totalCollateral: string
	maintenanceMargin: string
	collateralToken: string
	createdAt: string
	updatedAt: string
}

export type GetRecordResponse = {
	success: boolean
	record?: LiquidationMonitoringRecord
	message?: string
}

// ─── Event Handler Types ───────────────────────────────────────────────────

export type DecodedLogArgs = Record<string, unknown>

export type EventHandlerContext<TArgs = DecodedLogArgs> = {
	runtime: import('@chainlink/cre-sdk').Runtime<Config>
	args: TArgs
	config: Config
}

export type EventHandlerResult = {
	success: boolean
	message: string
}

// Generic handler type that accepts any args
export type EventHandlerFunction = (
	context: EventHandlerContext<DecodedLogArgs>,
) => EventHandlerResult | Promise<EventHandlerResult>

// Typed handler type for specific events
export type EventHandler<TArgs = DecodedLogArgs> = (
	context: EventHandlerContext<TArgs>,
) => EventHandlerResult | Promise<EventHandlerResult>
