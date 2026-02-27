import { type Address } from 'viem'

/**
 * ABI fragment for ClearingHouse contract events: TradeNovated and PositionMatured.
 * Generated from contracts/src/interfaces/IClearingHouse.sol
 */
export const ClearingHouseABI = [
	// TradeNovated event - emitted when a trade is novated
	// Full event with 13 parameters (4 indexed)
	{
		anonymous: false,
		inputs: [
			{ indexed: true, internalType: 'bytes32', name: 'tradeId', type: 'bytes32' },
			{ indexed: false, internalType: 'uint256', name: 'tokenIdA', type: 'uint256' },
			{ indexed: false, internalType: 'uint256', name: 'tokenIdB', type: 'uint256' },
			{ indexed: true, internalType: 'bytes32', name: 'partyA', type: 'bytes32' },
			{ indexed: true, internalType: 'bytes32', name: 'partyB', type: 'bytes32' },
			{ indexed: false, internalType: 'uint256', name: 'notional', type: 'uint256' },
			{ indexed: false, internalType: 'uint256', name: 'fixedRateBps', type: 'uint256' },
			{ indexed: false, internalType: 'uint256', name: 'startDate', type: 'uint256' },
			{ indexed: false, internalType: 'uint256', name: 'maturityDate', type: 'uint256' },
			{ indexed: false, internalType: 'uint256', name: 'paymentInterval', type: 'uint256' },
			{ indexed: false, internalType: 'uint8', name: 'dayCountConvention', type: 'uint8' },
			{ indexed: false, internalType: 'bytes32', name: 'floatingRateIndex', type: 'bytes32' },
			{ indexed: false, internalType: 'address', name: 'collateralToken', type: 'address' },
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
 * Full event with all 13 parameters from the contract
 */
export interface TradeNovatedEventArgs {
	tradeId: `0x${string}`
	tokenIdA: bigint
	tokenIdB: bigint
	partyA: `0x${string}`
	partyB: `0x${string}`
	notional: bigint
	fixedRateBps: bigint
	startDate: bigint
	maturityDate: bigint
	paymentInterval: bigint
	dayCountConvention: number
	floatingRateIndex: `0x${string}`
	collateralToken: `0x${string}`
}

/**
 * TypeScript type for PositionMatured event args
 */
export interface PositionMaturedEventArgs {
	tradeId: `0x${string}`
	timestamp: bigint
}

export const ClearingHouseAddress = '' // To be filled from config
