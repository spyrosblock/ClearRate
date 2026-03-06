import type { EventHandlerFunction, EventHandlerResult, EventHandlerContext } from '../types'

// Import all event handlers
import { handleTradeNovated, type TradeNovatedArgs } from './trade-novated.handler'
import { handlePositionMatured, type PositionMaturedArgs } from './position-matured.handler'
import { handleMarginDeposited, type MarginDepositedArgs } from './margin-deposited.handler'
import { handleMarginWithdrawn, type MarginWithdrawnArgs } from './margin-withdrawn.handler'
import { handlePositionsAbsorbed, type PositionsAbsorbedArgs } from './positions-absorbed.handler'
import { handlePositionTransferred, type PositionTransferredArgs } from './position-transferred.handler'

// ─── Event Handler Registry ─────────────────────────────────────────────────

export type EventName =
	| 'TradeNovated'
	| 'PositionMatured'
	| 'MarginDeposited'
	| 'MarginWithdrawn'
	| 'PositionsAbsorbed'
	| 'PositionTransferred'

export interface HandlerRegistryEntry {
	handler: EventHandlerFunction
	description: string
}

const handlerRegistry: Record<EventName, HandlerRegistryEntry> = {
	TradeNovated: {
		handler: handleTradeNovated,
		description: 'Handles trade novation events from ClearingHouse',
	},
	PositionMatured: {
		handler: handlePositionMatured,
		description: 'Handles position maturity events from ClearingHouse',
	},
	MarginDeposited: {
		handler: handleMarginDeposited,
		description: 'Handles margin deposit events from MarginVault',
	},
	MarginWithdrawn: {
		handler: handleMarginWithdrawn,
		description: 'Handles margin withdrawal events from MarginVault',
	},
	PositionsAbsorbed: {
		handler: handlePositionsAbsorbed,
		description: 'Handles position absorption events from LiquidationEngine',
	},
	PositionTransferred: {
		handler: handlePositionTransferred,
		description: 'Handles position transfer events from ClearingHouse',
	},
}

// ─── Registry Functions ─────────────────────────────────────────────────────

/**
 * Get a handler from the registry by event name
 */
export const getHandler = (eventName: EventName): HandlerRegistryEntry | undefined => {
	return handlerRegistry[eventName]
}

/**
 * Check if an event name is registered
 */
export const isRegisteredEvent = (eventName: string): eventName is EventName => {
	return eventName in handlerRegistry
}

/**
 * Get all registered event names
 */
export const getRegisteredEventNames = (): EventName[] => {
	return Object.keys(handlerRegistry) as EventName[]
}

/**
 * Execute a handler for a given event
 */
export const executeHandler = async (
	eventName: EventName,
	context: EventHandlerContext,
): Promise<EventHandlerResult> => {
	const entry = getHandler(eventName)
	if (!entry) {
		return { success: false, message: `No handler registered for event: ${eventName}` }
	}
	return entry.handler(context)
}

// Re-export types and handlers
export type {
	TradeNovatedArgs,
	PositionMaturedArgs,
	MarginDepositedArgs,
	MarginWithdrawnArgs,
	PositionsAbsorbedArgs,
	PositionTransferredArgs,
}

export {
	handleTradeNovated,
	handlePositionMatured,
	handleMarginDeposited,
	handleMarginWithdrawn,
	handlePositionsAbsorbed,
	handlePositionTransferred,
}
