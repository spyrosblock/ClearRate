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
