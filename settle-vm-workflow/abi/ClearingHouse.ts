import { type Address } from 'viem'

/**
 * ABI fragment for ClearingHouse contract's variation margin settlement.
 * The VM settlement is handled through _processReport with reportType = 1
 * Report format: abi.encode(uint8(1), VMSettlement[])
 * 
 * VMSettlement struct:
 * - accountId: bytes32
 * - vmAmount: int256 (signed, positive = credit)
 */
export const ClearingHouseABI = [
	{
		inputs: [
			{
				components: [
					{ internalType: 'bytes32', name: 'accountId', type: 'bytes32' },
					{ internalType: 'int256', name: 'vmAmount', type: 'int256' },
				],
				internalType: 'struct ClearingHouse.VMSettlement[]',
				name: 'settlements',
				type: 'tuple[]',
			},
		],
		name: 'settleVM',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
] as const

/**
 * TypeScript type for VMSettlement struct
 */
export interface VMSettlement {
	accountId: `0x${string}`
	vmAmount: bigint
}

/**
 * Input payload structure for VM settlement workflow
 */
export interface VMSettlementPayload {
	settlements: {
		accountId: string
		vmAmount: string  // Can be positive or negative
	}[]
	metadata?: {
		settlementDate: string
		npvSource: string
	}
}

export const ClearingHouseAddress = '' // To be filled from config
