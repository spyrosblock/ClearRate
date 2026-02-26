import { type Address } from 'viem'

/**
 * ABI fragment for ClearingHouse contract events: TradeNovated and PositionMatured.
 * Generated from contracts/src/interfaces/IClearingHouse.sol
 */
export const ClearingHouseABI = [
	// TradeNovated event - emitted when a trade is novated
	{
		anonymous: false,
		inputs: [
			{ indexed: true, internalType: 'bytes32', name: 'tradeId', type: 'bytes32' },
			{ indexed: false, internalType: 'uint256', name: 'tokenIdA', type: 'uint256' },
			{ indexed: false, internalType: 'uint256', name: 'tokenIdB', type: 'uint256' },
		],
		name: 'TradeNovated',
		type: 'event',
	},
	// PositionMatured event - emitted when a position reaches maturity
	{
		anonymous: false,
		inputs: [
			{ indexed: true, internalType: 'bytes32', name: 'tradeId', type: 'bytes32' },
			{ indexed: false, internalType: 'uint256', name: 'timestamp', type: 'uint256' },
		],
		name: 'PositionMatured',
		type: 'event',
	},
] as const

/**
 * TypeScript type for TradeNovated event args
 */
export interface TradeNovatedEventArgs {
	tradeId: `0x${string}`
	tokenIdA: bigint
	tokenIdB: bigint
}

/**
 * TypeScript type for PositionMatured event args
 */
export interface PositionMaturedEventArgs {
	tradeId: `0x${string}`
	timestamp: bigint
}

export const ClearingHouseAddress = '' // To be filled from config
