export const YieldCurveOracle = [
	{
		inputs: [
			{ internalType: 'uint256[]', name: 'tenors', type: 'uint256[]' },
			{ internalType: 'uint256[]', name: 'factors', type: 'uint256[]' },
		],
		name: 'updateDiscountFactors',
		outputs: [],
		stateMutability: 'nonpayable',
		type: 'function',
	},
	{
		inputs: [{ internalType: 'uint256', name: 'tenor', type: 'uint256' }],
		name: 'getDiscountFactor',
		outputs: [{ internalType: 'uint256', name: 'factor', type: 'uint256' }],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'getSupportedTenors',
		outputs: [{ internalType: 'uint256[]', name: '', type: 'uint256[]' }],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'isFresh',
		outputs: [{ internalType: 'bool', name: '', type: 'bool' }],
		stateMutability: 'view',
		type: 'function',
	},
	{
		inputs: [],
		name: 'lastUpdateTimestamp',
		outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
		stateMutability: 'view',
		type: 'function',
	},
] as const
