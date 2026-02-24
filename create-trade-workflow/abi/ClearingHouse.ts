import { type Address } from 'viem'

/**
 * ABI fragment for ClearingHouse contract's submitMatchedTrade function.
 * Generated from contracts/src/core/ClearingHouse.sol
 */
export const ClearingHouseABI = [
	{
		inputs: [
			{
				components: [
					{ internalType: 'bytes32', name: 'tradeId', type: 'bytes32' },
					{ internalType: 'bytes32', name: 'partyA', type: 'bytes32' },
					{ internalType: 'bytes32', name: 'partyB', type: 'bytes32' },
					{ internalType: 'uint256', name: 'notional', type: 'uint256' },
					{ internalType: 'uint256', name: 'fixedRateBps', type: 'uint256' },
					{ internalType: 'uint256', name: 'startDate', type: 'uint256' },
					{ internalType: 'uint256', name: 'maturityDate', type: 'uint256' },
					{ internalType: 'uint256', name: 'paymentInterval', type: 'uint256' },
					{ internalType: 'uint8', name: 'dayCountConvention', type: 'uint8' },
					{ internalType: 'bytes32', name: 'floatingRateIndex', type: 'bytes32' },
					{ internalType: 'uint256', name: 'nonce', type: 'uint256' },
					{ internalType: 'uint256', name: 'deadline', type: 'uint256' },
				],
				internalType: 'struct ClearingHouse.MatchedTrade',
				name: 'trade',
				type: 'tuple',
			},
			{ internalType: 'bytes', name: 'sigA', type: 'bytes' },
			{ internalType: 'bytes', name: 'sigB', type: 'bytes' },
		],
		name: 'submitMatchedTrade',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
] as const

/**
 * TypeScript type for MatchedTrade struct
 */
export interface MatchedTrade {
	tradeId: `0x${string}`
	partyA: `0x${string}`
	partyB: `0x${string}`
	notional: bigint
	fixedRateBps: bigint
	startDate: bigint
	maturityDate: bigint
	paymentInterval: bigint
	dayCountConvention: number
	floatingRateIndex: `0x${string}`
	nonce: bigint
	deadline: bigint
}

/**
 * Input payload structure matching trade.json
 */
export interface TradePayload {
	trade: {
		tradeId: string
		partyA: string
		partyB: string
		notional: string
		fixedRateBps: number
		startDate: number
		maturityDate: number
		paymentInterval: number
		dayCountConvention: number
		floatingRateIndex: string
		nonce: number
		deadline: number
	}
	sigA: string
	sigB: string
	metadata?: {
		notionalFormatted: string
		fixedRateFormatted: string
		tenorDays: number
		paymentIntervalDays: number
		partyAFormatted: string
		partyBFormatted: string
	}
}

export const ClearingHouseAddress = '' // To be filled from config
