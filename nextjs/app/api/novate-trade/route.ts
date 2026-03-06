import { NextResponse } from 'next/server';
import { sql } from '@/lib/db';

// ─── Types for store-logs-workflow ────────────────────────────────────────

/**
 * Payload received from store-logs-workflow when a new trade is novated.
 */
interface NovatedPositionPayload {
	tradeId: string
	tokenIdA: string
	tokenIdB: string
	partyA: string
	partyB: string
	notional: string
	fixedRateBps: string
	startDate: string
	maturityDate: string
	paymentInterval: string
	dayCountConvention: number
	floatingRateIndex: string
	active: boolean
	lastNpv: string
	collateralToken: string
	newMMA: string
	newMMB: string
}

// ─── Helper to convert Unix timestamp to ISO date string ─────────────────

const unixTimestampToISO = (timestamp: string): string => {
	const date = new Date(Number(timestamp) * 1000)
	return date.toISOString()
}

// ─── POST Handler: Insert or Update Position Data ────────────────────────

export async function POST(request: Request) {
	try {
		const payload: NovatedPositionPayload = await request.json()

		// Convert Unix timestamps to ISO date strings
		const startDate = unixTimestampToISO(payload.startDate)
		const maturityDate = unixTimestampToISO(payload.maturityDate)

		// Insert two position records: one for each party
		// Party A: PAY_FIXED (direction = 0)
		// Party B: RECEIVE_FIXED (direction = 1)

		// Insert Party A's position (PAY_FIXED)
		await sql`
			INSERT INTO swap_positions (
				token_id,
				owner_id,
				balance,
				notional,
				fixed_rate_bps,
				start_date,
				maturity_date,
				payment_interval,
				direction,
				floating_rate_index,
				day_count_convention,
				collateral_token,
				active,
				last_npv
			) VALUES (
				${payload.tokenIdA},
				${payload.partyA},
				${payload.notional},
				${payload.notional},
				${parseInt(payload.fixedRateBps)},
				${startDate},
				${maturityDate},
				${payload.paymentInterval},
				0,
				${payload.floatingRateIndex},
				${payload.dayCountConvention},
				${payload.collateralToken},
				${payload.active},
				${payload.lastNpv}
			)
			ON CONFLICT (token_id, owner_id) DO UPDATE SET
				balance = EXCLUDED.balance,
				notional = EXCLUDED.notional,
				fixed_rate_bps = EXCLUDED.fixed_rate_bps,
				start_date = EXCLUDED.start_date,
				maturity_date = EXCLUDED.maturity_date,
				payment_interval = EXCLUDED.payment_interval,
				direction = EXCLUDED.direction,
				floating_rate_index = EXCLUDED.floating_rate_index,
				day_count_convention = EXCLUDED.day_count_convention,
				collateral_token = EXCLUDED.collateral_token,
				active = EXCLUDED.active,
				last_npv = EXCLUDED.last_npv,
				updated_at = NOW()
		`

		// Insert Party B's position (RECEIVE_FIXED)
		await sql`
			INSERT INTO swap_positions (
				token_id,
				owner_id,
				balance,
				notional,
				fixed_rate_bps,
				start_date,
				maturity_date,
				payment_interval,
				direction,
				floating_rate_index,
				day_count_convention,
				collateral_token,
				active,
				last_npv
			) VALUES (
				${payload.tokenIdB},
				${payload.partyB},
				${payload.notional},
				${payload.notional},
				${parseInt(payload.fixedRateBps)},
				${startDate},
				${maturityDate},
				${payload.paymentInterval},
				1,
				${payload.floatingRateIndex},
				${payload.dayCountConvention},
				${payload.collateralToken},
				${payload.active},
				${payload.lastNpv}
			)
			ON CONFLICT (token_id, owner_id) DO UPDATE SET
				balance = EXCLUDED.balance,
				notional = EXCLUDED.notional,
				fixed_rate_bps = EXCLUDED.fixed_rate_bps,
				start_date = EXCLUDED.start_date,
				maturity_date = EXCLUDED.maturity_date,
				payment_interval = EXCLUDED.payment_interval,
				direction = EXCLUDED.direction,
				floating_rate_index = EXCLUDED.floating_rate_index,
				day_count_convention = EXCLUDED.day_count_convention,
				collateral_token = EXCLUDED.collateral_token,
				active = EXCLUDED.active,
				last_npv = EXCLUDED.last_npv,
				updated_at = NOW()
		`

		// Update maintenance margin for Party A in liquidation_monitoring
		await sql`
			INSERT INTO liquidation_monitoring (account_id, total_collateral, maintenance_margin, collateral_token)
			VALUES (${payload.partyA}, 0, ${payload.newMMA}::numeric, ${payload.collateralToken})
			ON CONFLICT (account_id, collateral_token) 
			DO UPDATE SET 
				maintenance_margin = ${payload.newMMA}::numeric,
				updated_at = NOW()
		`

		// Update maintenance margin for Party B in liquidation_monitoring
		await sql`
			INSERT INTO liquidation_monitoring (account_id, total_collateral, maintenance_margin, collateral_token)
			VALUES (${payload.partyB}, 0, ${payload.newMMB}::numeric, ${payload.collateralToken})
			ON CONFLICT (account_id, collateral_token) 
			DO UPDATE SET 
				maintenance_margin = ${payload.newMMB}::numeric,
				updated_at = NOW()
		`

		return NextResponse.json({
			status: 'success',
			message: 'Novated positions stored successfully',
			tradeId: payload.tradeId,
			tokenIdA: payload.tokenIdA,
			tokenIdB: payload.tokenIdB,
		})
	} catch (error) {
		console.error('Error processing novated position request:', error)
		return NextResponse.json(
			{ error: 'Failed to process novated position' },
			{ status: 500 }
		)
	}
}
