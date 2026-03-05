import { type HTTPSendRequester, ok } from '@chainlink/cre-sdk'
import type { PostResponse, GetResponse } from './types'

// ─── HTTP Utility Functions ─────────────────────────────────────────────────

/**
 * Send a GET request to fetch data from an API.
 * Returns a response with statusCode, and optional body.
 * For 404, returns statusCode 404 with empty body instead of null
 */
export const getFromApi = (
	sendRequester: HTTPSendRequester,
	url: string,
): GetResponse => {
	const req = {
		url,
		method: 'GET' as const,
		headers: {
			'Content-Type': 'application/json',
		},
	}

	const resp = sendRequester.sendRequest(req).result()

	if (!ok(resp)) {
		// For 404, return a response with statusCode 404 and empty body
		// This allows consensus to work properly (cannot handle null)
		if (resp.statusCode === 404) {
			return { statusCode: 404, body: '' }
		}
		throw new Error(`HTTP GET request failed with status: ${resp.statusCode}`)
	}

	// Decode body from Uint8Array to string
	const bodyString = typeof resp.body === 'string'
		? resp.body
		: new TextDecoder().decode(resp.body)

	return { statusCode: resp.statusCode, body: bodyString }
}

/**
 * Send a POST request to a specific URL.
 */
export const postToApi = (
	sendRequester: HTTPSendRequester,
	url: string,
	payload: Record<string, unknown>,
): PostResponse => {
	const bodyBytes = new TextEncoder().encode(JSON.stringify(payload))
	const body = Buffer.from(bodyBytes).toString('base64')

	const req = {
		url,
		method: 'POST' as const,
		body,
		headers: {
			'Content-Type': 'application/json',
		},
	}

	const resp = sendRequester.sendRequest(req).result()

	if (!ok(resp)) {
		throw new Error(`HTTP POST request failed with status: ${resp.statusCode}`)
	}

	return { statusCode: resp.statusCode }
}