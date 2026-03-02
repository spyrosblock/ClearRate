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
	usersApi: z.object({
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

	// Company data
	company: z.object({
		companyName: z.string().min(1),
		registrationNumber: z.string().min(1),
		registeredCountry: z.string().length(2), // ISO 3166-1 alpha-2
		contactEmail: z.string().email(),
		lei: z.string().regex(/^[A-Z0-9]{20}$/, 'Invalid LEI format - must be 20 alphanumeric characters'), // Legal Entity Identifier
		website: z.string(),
		uploadedLegalDocs: z.object({
			articlesOfAssociation: z.string(),
			certificateOfIncorporation: z.string(),
			vatCertificate: z.string(),
		}),
		bankDetails: z.object({
			iban: z.string(),
			bic: z.string(),
		}),
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

// ─── Users API Response Schema ──────────────────────────────────────────────

/**
 * Schema for the Users API response.
 * API returns success status and userId.
 */
const usersResponseSchema = z.object({
	success: z.boolean(),
	message: z.string().optional(),
})

type ValidatedUsersResponse = z.infer<typeof usersResponseSchema>

// ─── Utility Functions ────────────────────────────────────────────────────────

const safeJsonStringify = (obj: any): string =>
	JSON.stringify(obj, (_, value) => (typeof value === 'bigint' ? value.toString() : value), 2)

/**
 * Generate an accountId (bytes32) from an address, padded with zeros on the left.
 * Returns a string like "0x..." with 64 hex characters (32 bytes).
 */
const generateAccountId = (address: string): string => {
	// Remove '0x' prefix if present and ensure lowercase
	const cleanAddress = address.replace(/^0x/, '').toLowerCase()
	
	// Pad with zeros on the left to make it 64 characters (32 bytes)
	const paddedAddress = cleanAddress.padStart(64, '0')
	
	// Return with '0x' prefix
	return '0x' + paddedAddress
}

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
	accountId: string,
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
		accountId: accountId,
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
	accountId: string,
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
		accountId: accountId,
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

/**
 * Register user in the Users API after successful whitelisting.
 * This function is executed by each DON node independently;
 * results are aggregated via median consensus.
 */
const registerUserInApi = (
	sendRequester: HTTPSendRequester,
	config: Config,
	payload: ValidatedUserDataPayload,
	accountId: string,
	kybResult: ValidatedKybResponse,
	maxNotional: bigint,
): ValidatedUsersResponse => {
	// If no API endpoint configured, skip registration
	if (!config.usersApi?.apiEndpoint) {
		console.log('[DEBUG] No Users API endpoint configured, skipping registration')
		return {
			success: true,
			message: 'Users API not configured, skipping registration',
		}
	}

	// Prepare request body - include all user data plus whitelist results
	const requestBody = JSON.stringify({
		address: payload.address,
		accountId: accountId,
		company: payload.company,
		approved: kybResult.approved,
		validUntil: kybResult.validUntil ? new Date(kybResult.validUntil * 1000).toISOString() : null,
		maxNotional: maxNotional.toString(),
	})

	// Send request to Users API
	const response = sendRequester.sendRequest({
		method: 'POST',
		url: config.usersApi.apiEndpoint,
		body: Buffer.from(requestBody).toString('base64'),
		headers: {
			'Content-Type': 'application/json',
		},
	}).result()

	console.log('[DEBUG] Users API response status:', response.statusCode)
	console.log('[DEBUG] Users API response body:', JSON.stringify(response.body))

	if (response.statusCode !== 200 && response.statusCode !== 201) {
		throw new Error(`Users API request failed with status: ${response.statusCode}`)
	}

	const responseText = Buffer.from(response.body).toString('utf-8')
	console.log('[DEBUG] Users API response text:', responseText)
	const data = JSON.parse(responseText)

	// Validate and return the parsed payload
	return usersResponseSchema.parse(data)
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
	accountId: string,
	kybResult: ValidatedKybResponse,
	maxNotional: bigint,
): string => {
	const evmConfig = runtime.config.evms[0]

	runtime.log(`Adding participant to Whitelist: ${userData.address}`)

	// Log the user details
	runtime.log(`User Details:`)
	runtime.log(`  Address: ${userData.address}`)
	runtime.log(`  Account ID: ${accountId}`)
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
		accountId as `0x${string}`,
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

const createHTTPTriggerHandler = (evmClient: cre.capabilities.EVMClient) => {
	return (runtime: Runtime<Config>, payload: HTTPPayload): string => {
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

			// Generate an accountId from the user's address
			const accountId = generateAccountId(userData.address)
			runtime.log(`Generated Account ID: ${accountId}`)

			// Query KYB API for verification using HTTPClient with consensus aggregation
			const httpCapability = new HTTPClient()
			
			const kybResult = httpCapability
				.sendRequest(
					runtime,
					(sendRequester, config) => fetchKybVerification(sendRequester, config as Config, userData, accountId),
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
					(sendRequester, config) => fetchMaxNotional(sendRequester, config as Config, userData, accountId),
					{
						maxNotional: median,
						reason: median,
					},
				)(runtime.config)
				.result() as ValidatedRiskManagementResponse

			// Parse maxNotional string to bigint (remove underscores if present)
			const maxNotional = BigInt(riskManagementResult.maxNotional.replace(/_/g, ''))
			runtime.log(`Risk Management: maxNotional fetched successfully`)

			// Execute the add participant transaction
			const txHash = addParticipantToWhitelist(runtime, evmClient, userData, accountId, kybResult, maxNotional)

			// Register user in the Users API after successful whitelisting
			runtime.log(`Registering user in Users API...`)
			const usersResult = httpCapability
				.sendRequest(
					runtime,
					(sendRequester, config) => registerUserInApi(sendRequester, config as Config, userData, accountId, kybResult, maxNotional),
					{
						success: median,
						message: median,
					},
				)(runtime.config)
				.result() as ValidatedUsersResponse

			if (usersResult.success) {
				runtime.log(`User registered in Users API successfully`)
			} else {
				runtime.log(`Warning: User registration in Users API may have failed: ${usersResult.message || 'Unknown status'}`)
			}

			return `Participant added successfully! TxHash: ${txHash}`
		} catch (error) {
			runtime.log(`Error processing user data: ${error}`)
			throw new Error(`Failed to process user data: ${error}`)
		}
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
			createHTTPTriggerHandler(evmClient),
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