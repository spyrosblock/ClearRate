import { type Address } from 'viem'

/**
 * ABI fragment for ClearingHouse contract's variation margin settlement.
 * The VM settlement is handled through _processReport with reportType = 1
 * Report format: abi.encode(uint8(1), VMSettlement[])
 * 
 * VMSettlement struct (matches contracts/src/interfaces/IClearingHouse.sol):
 * - tradeId: bytes32 (unique trade identifier)
 * - npvChange: int256 (NPV change from the fixed payer's perspective)
 */
export const ClearingHouseABI = [
	{
		inputs: [
			{
				components: [
					{ internalType: 'bytes32', name: 'tradeId', type: 'bytes32' },
					{ internalType: 'int256', name: 'npvChange', type: 'int256' },
				],
				internalType: 'struct ClearingHouse.VMSettlement[]',
				name: 'settlements',
				type: 'tuple[]',
			},
		],
		name: 'settleVariationMarginBatch',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
] as const

/**
 * TypeScript type for VMSettlement struct
 * Matches: contracts/src/interfaces/IClearingHouse.sol::VMSettlement
 */
export interface VMSettlement {
	tradeId: `0x${string}`
	npvChange: bigint
}

/**
 * Input payload structure for VM settlement workflow
 */
export interface VMSettlementPayload {
	settlements: {
		tradeId: string
		npvChange: string // Can be positive or negative
	}[]
	metadata?: {
		settlementDate: string
		npvSource: string
	}
}

export const ClearingHouseAddress = '' // To be filled from config

/**
 * Full ABI for reading positions from the ClearingHouse contract.
 * Includes view functions for querying positions and accounts.
 */
export const ClearingHouseFullABI = [
	// View functions
	{
		inputs: [{ name: 'accountId', type: 'bytes32' }],
		name: 'getAccountPositions',
		outputs: [{ name: '', type: 'bytes32[]' }],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [{ name: 'tradeId', type: 'bytes32' }],
		name: 'getPosition',
		outputs: [
			{
				components: [
					{ name: 'tradeId', type: 'bytes32' },
					{ name: 'tokenIdA', type: 'uint256' },
					{ name: 'tokenIdB', type: 'uint256' },
					{ name: 'partyA', type: 'bytes32' },
					{ name: 'partyB', type: 'bytes32' },
					{ name: 'notional', type: 'uint256' },
					{ name: 'originalNotional', type: 'uint256' },
					{ name: 'fixedRateBps', type: 'uint256' },
					{ name: 'startDate', type: 'uint256' },
					{ name: 'maturityDate', type: 'uint256' },
					{ name: 'active', type: 'bool' },
					{ name: 'lastNpv', type: 'int256' },
				],
				internalType: 'struct IClearingHouse.NovatedPosition',
				name: '',
				type: 'tuple',
			},
		],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'activePositionCount',
		outputs: [{ name: '', type: 'uint256' }],
		stateMutability: 'view',
		type: 'function',
	},
	// Write functions (for reference)
	{
		inputs: [
			{
				components: [
					{ internalType: 'bytes32', name: 'tradeId', type: 'bytes32' },
					{ internalType: 'int256', name: 'npvChange', type: 'int256' },
				],
				internalType: 'struct ClearingHouse.VMSettlement[]',
				name: 'settlements',
				type: 'tuple[]',
			},
		],
		name: 'settleVariationMarginBatch',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
] as const
