import {
	bytesToHex,
	cre,
	getNetwork,
	type HTTPPayload,
	hexToBase64,
	HTTPClient,
	type HTTPSendRequester,
	median,
	Runner,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import { Buffer } from 'buffer'
import { encodeAbiParameters, parseAbiParameters } from 'viem'
import { z } from 'zod'

// ─── Configuration Schema ───────────────────────────────────────────────────

const configSchema = z.object({
	evms: z.array(
		z.object({
			whitelistAddress: z.string(),
			chainSelectorName: z.string(),
			gasLimit: z.string(),
		}),
	),
	kybApi: z.object({
		apiEndpoint: z.string(),
	}).optional(),
	riskManagementApi: z.object({
		apiEndpoint: z.string(),
	}).optional(),
})

type Config = z.infer<typeof configSchema>

// ─── User Data Payload Schema ───────────────────────────────────────────────

/**
 * Schema for validating the incoming user data payload.
 * User provides company data for KYB verification.
 */
const userDataPayloadSchema = z.object({
	// User identification
	address: z.string().regex(/^0x[a-fA-F0-9]{40}$/, 'Invalid Ethereum address'),
	accountId: z.string().regex(/^0x[a-fA-F0-9]{64}$/, 'Invalid account ID'),

	// Company data
	company: z.object({
		companyName: z.string().min(1),
		registrationNumber: z.string().min(1),
		registeredCountry: z.string().length(2), // ISO 3166-1 alpha-2
		contactEmail: z.string().email(),
		lei: z.string().regex(/^[A-Z0-9]{20}$/, 'Invalid LEI format - must be 20 alphanumeric characters'), // Legal Entity Identifier
	}),
})

type ValidatedUserDataPayload = z.infer<typeof userDataPayloadSchema>

// ─── KYB API Response Schema ────────────────────────────────────────────────

/**
 * Schema for the KYB API response.
 * API returns approval status and validUntil timestamp.
 */
const kybResponseSchema = z.object({
	approved: z.boolean(),
	validUntil: z.number().optional(), // Unix timestamp for whitelist expiry
	reason: z.string().optional(), // If not approved
})

type ValidatedKybResponse = z.infer<typeof kybResponseSchema>

// ─── Risk Management API Response Schema ────────────────────────────────────

/**
 * Schema for the Risk Management API response.
 * API returns maxNotional based on risk assessment.
 */
const riskManagementResponseSchema = z.object({
	maxNotional: z.string(), // String to handle large numbers
	reason: z.string().optional(),
})

type ValidatedRiskManagementResponse = z.infer<typeof riskManagementResponseSchema>

// ─── Utility Functions ────────────────────────────────────────────────────────

const safeJsonStringify = (obj: any): string =>
	JSON.stringify(obj, (_, value) => (typeof value === 'bigint' ? value.toString() : value), 2)

/**
 * Parse and validate the incoming user data payload
 */
const parseUserDataPayload = (input: Buffer): ValidatedUserDataPayload => {
	const payloadJson = JSON.parse(input.toString())
	return userDataPayloadSchema.parse(payloadJson)
}

/**
 * Validate user data via external KYB API.
 * This function is executed by each DON node independently;
 * results are aggregated via median consensus.
 */
const fetchKybVerification = (
	sendRequester: HTTPSendRequester,
	config: Config,
	payload: ValidatedUserDataPayload,
): ValidatedKybResponse => {
	// If no API endpoint configured, use default approval
	if (!config.kybApi?.apiEndpoint) {
		return {
			approved: true,
		}
	}

	// Prepare request body
	const requestBody = JSON.stringify({
		address: payload.address,
		accountId: payload.accountId,
		company: payload.company,
	})

	// Send request to KYB API
	const response = sendRequester.sendRequest({
		method: 'POST',
		url: config.kybApi.apiEndpoint,
		body: Buffer.from(requestBody).toString('base64'),
		headers: {
			'Content-Type': 'application/json',
		},
	}).result()

	console.log('[DEBUG] KYB API response status:', response.statusCode)
	console.log('[DEBUG] KYB API response body:', JSON.stringify(response.body))

	if (response.statusCode !== 200) {
		throw new Error(`KYB API request failed with status: ${response.statusCode}`)
	}

	const responseText = Buffer.from(response.body).toString('utf-8')
	console.log('[DEBUG] KYB API response text:', responseText)
	const data = JSON.parse(responseText)

	// Validate and return the parsed payload
	return kybResponseSchema.parse(data)
}

/**
 * Fetch maxNotional from the Risk Management API.
 * This function is executed by each DON node independently;
 * results are aggregated via median consensus.
 */
const fetchMaxNotional = (
	sendRequester: HTTPSendRequester,
	config: Config,
	payload: ValidatedUserDataPayload,
): ValidatedRiskManagementResponse => {
	// If no API endpoint configured, use default maxNotional
	if (!config.riskManagementApi?.apiEndpoint) {
		return {
			maxNotional: '10000000000000000000000000', // 10M * 1e18 default
		}
	}

	// Prepare request body
	const requestBody = JSON.stringify({
		address: payload.address,
		accountId: payload.accountId,
		company: payload.company,
	})

	// Send request to Risk Management API
	const response = sendRequester.sendRequest({
		method: 'POST',
		url: config.riskManagementApi.apiEndpoint,
		body: Buffer.from(requestBody).toString('base64'),
		headers: {
			'Content-Type': 'application/json',
		},
	}).result()

	console.log('[DEBUG] Risk Management API response status:', response.statusCode)
	console.log('[DEBUG] Risk Management API response body:', JSON.stringify(response.body))

	if (response.statusCode !== 200) {
		throw new Error(`Risk Management API request failed with status: ${response.statusCode}`)
	}

	const responseText = Buffer.from(response.body).toString('utf-8')
	console.log('[DEBUG] Risk Management API response text:', responseText)
	const data = JSON.parse(responseText)

	// Validate and return the parsed payload
	return riskManagementResponseSchema.parse(data)
}

// ─── Core Workflow Logic ───────────────────────────────────────────────────

/**
 * Add participant to the Whitelist contract.
 * This function:
 * 1. Validates the user data payload
 * 2. Queries the KYB API for verification
 * 3. Encodes the function call data for adding participant
 * 4. Generates a DON-signed report
 * 5. Submits the transaction to the Whitelist contract
 */
const addParticipantToWhitelist = (
	runtime: Runtime<Config>,
	evmClient: cre.capabilities.EVMClient,
	userData: ValidatedUserDataPayload,
	kybResult: ValidatedKybResponse,
	maxNotional: bigint,
): string => {
	const evmConfig = runtime.config.evms[0]

	runtime.log(`Adding participant to Whitelist: ${userData.address}`)

	// Log the user details
	runtime.log(`User Details:`)
	runtime.log(`  Address: ${userData.address}`)
	runtime.log(`  Account ID: ${userData.accountId}`)
	runtime.log(`  Type: Company`)
	runtime.log(`  Company: ${userData.company.companyName}`)
	runtime.log(`  Registration: ${userData.company.registrationNumber}`)
	runtime.log(`  Country: ${userData.company.registeredCountry}`)
	runtime.log(`  LEI: ${userData.company.lei}`)

	runtime.log(`KYB Result:`)
	runtime.log(`  Approved: ${kybResult.approved}`)
	if (kybResult.validUntil) {
		runtime.log(`  Valid Until: ${new Date(kybResult.validUntil * 1000).toISOString()}`)
	}

	runtime.log(`Risk Management Result:`)
	runtime.log(`  Max Notional: ${maxNotional.toString()}`)

	// Prepare the call data for addParticipant
	// ReportType = 0 indicates add participant
	// Format: abi.encode(uint8(0), participant, accountId, maxNotional, validUntil)
	// Note: The contract expects (uint8, address, bytes32, uint256, uint64)
	const validUntil = kybResult.validUntil 
		? BigInt(kybResult.validUntil) 
		: BigInt(Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60) // Default 1 year from now

	const fullAbiParams = parseAbiParameters(
		'uint8,address,bytes32,uint256,uint64',
	)
	const callData = encodeAbiParameters(fullAbiParams, [
		0, // Report type: 0 = add participant
		userData.address as `0x${string}`,
		userData.accountId as `0x${string}`,
		maxNotional,
		validUntil,
	])

	runtime.log(`Encoded call data: ${callData}`)

	// Generate a DON-signed report using consensus capability
	const reportResponse = runtime
		.report({
			encodedPayload: hexToBase64(callData),
			encoderName: 'evm',
			signingAlgo: 'ecdsa',
			hashingAlgo: 'keccak256',
		})
		.result()

	// Submit the report to the Whitelist contract
	const resp = evmClient
		.writeReport(runtime, {
			receiver: evmConfig.whitelistAddress,
			report: reportResponse,
			gasConfig: {
				gasLimit: evmConfig.gasLimit,
			},
		})
		.result()

	const txStatus = resp.txStatus

	if (txStatus !== TxStatus.SUCCESS) {
		throw new Error(`Failed to add participant: ${resp.errorMessage || txStatus}`)
	}

	const txHash = bytesToHex(resp.txHash || new Uint8Array(32))
	runtime.log(`Participant added successfully! TxHash: ${txHash}`)
	runtime.log(`   Verify execution: https://sepolia.etherscan.io/tx/${txHash}`)

	return txHash
}

// ─── HTTP Trigger Handler ───────────────────────────────────────────────────

const onHTTPTrigger = (
	runtime: Runtime<Config>,
	evmClient: cre.capabilities.EVMClient,
	payload: HTTPPayload,
): string => {
	runtime.log('HTTP trigger received for whitelist-user-workflow')

	// Require payload
	if (!payload.input || payload.input.length === 0) {
		throw new Error('HTTP trigger payload is required')
	}

	runtime.log(`Payload bytes: ${payload.input.toString()}`)

	try {
		// Parse and validate the user data payload
		const userData = parseUserDataPayload(payload.input)

		runtime.log(`Parsed user data payload: ${safeJsonStringify(userData)}`)

		// Query KYB API for verification using HTTPClient with consensus aggregation
		const httpCapability = new HTTPClient()
		
		const kybResult = httpCapability
			.sendRequest(
				runtime,
				(sendRequester, config) => fetchKybVerification(sendRequester, config as Config, userData),
				{
					approved: median,
					validUntil: median,
					reason: median,
				},
			)(runtime.config)
			.result() as ValidatedKybResponse

		// Check if approved
		if (!kybResult.approved) {
			throw new Error(`KYB verification failed: ${kybResult.reason || 'Not approved'}`)
		}

		runtime.log(`KYB verified successfully`)

		// Query Risk Management API for maxNotional using HTTPClient with consensus aggregation
		const riskManagementResult = httpCapability
			.sendRequest(
				runtime,
				(sendRequester, config) => fetchMaxNotional(sendRequester, config as Config, userData),
				{
					maxNotional: median,
					reason: median,
				},
			)(runtime.config)
			.result() as ValidatedRiskManagementResponse

		// Parse maxNotional string to bigint
		const maxNotional = BigInt(riskManagementResult.maxNotional)
		runtime.log(`Risk Management: maxNotional fetched successfully`)

		// Execute the add participant transaction
		const txHash = addParticipantToWhitelist(runtime, evmClient, userData, kybResult, maxNotional)

		return `Participant added successfully! TxHash: ${txHash}`
	} catch (error) {
		runtime.log(`Error processing user data: ${error}`)
		throw new Error(`Failed to process user data: ${error}`)
	}
}

// ─── Workflow Initialization ───────────────────────────────────────────────

const initWorkflow = (config: Config) => {
	const httpTrigger = new cre.capabilities.HTTPCapability()

	// Initialize EVM client for the configured chain
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.evms[0].chainSelectorName,
		isTestnet: true,
	})

	if (!network) {
		throw new Error(
			`Network not found for chain selector name: ${config.evms[0].chainSelectorName}`,
		)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)

	return [
		cre.handler(
			httpTrigger.trigger({}),
			(runtime, payload) => onHTTPTrigger(runtime, evmClient, payload),
		),
	]
}

// ─── Main Entry Point ───────────────────────────────────────────────────────

export async function main() {
	const runner = await Runner.newRunner<Config>({
		configSchema,
	})
	await runner.run(initWorkflow)
}

main()