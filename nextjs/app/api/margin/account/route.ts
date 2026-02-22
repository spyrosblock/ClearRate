import { NextResponse } from 'next/server';

/**
 * Mock API for margin account management
 * 
 * Handles:
 * - Deposits (collateral posting)
 * - Withdrawals (collateral retrieval)
 * - Margin account status
 * - Free margin calculation
 */

interface MarginAccount {
  accountId: string;
  balances: {
    totalDeposited: number;
    lockedInitialMargin: number;
    lockedVariationMargin: number;
    freeMargin: number;
  };
  positions: string[];
  lastUpdated: string;
}

// In-memory store (would be database in production)
const marginAccounts = new Map<string, MarginAccount>();

// Initialize with some mock data
function initializeAccount(accountId: string): MarginAccount {
  return {
    accountId,
    balances: {
      totalDeposited: 1000000, // 1M mock USD
      lockedInitialMargin: 0,
      lockedVariationMargin: 0,
      freeMargin: 1000000,
    },
    positions: [],
    lastUpdated: new Date().toISOString(),
  };
}

// GET endpoint - retrieve account margin status
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const accountId = searchParams.get('accountId');

  if (!accountId) {
    return NextResponse.json(
      {
        success: false,
        error: "Missing required query parameter: accountId",
      },
      { status: 400 }
    );
  }

  // Get or create account
  let account = marginAccounts.get(accountId);
  if (!account) {
    account = initializeAccount(accountId);
    marginAccounts.set(accountId, account);
  }

  const response = {
    success: true,
    data: {
      accountId: account.accountId,
      // Balance breakdown
      balances: {
        totalDeposited: account.balances.totalDeposited,
        lockedInitialMargin: account.balances.lockedInitialMargin,
        lockedVariationMargin: account.balances.lockedVariationMargin,
        lockedMargin: account.balances.lockedInitialMargin + account.balances.lockedVariationMargin,
        freeMargin: account.balances.freeMargin,
        totalMargin: account.balances.totalDeposited,
      },
      // Position count
      positions: {
        count: account.positions.length,
        positionIds: account.positions,
      },
      // Margin ratios
      marginRatios: {
        utilizationPercent: ((account.balances.lockedInitialMargin + account.balances.lockedVariationMargin) / account.balances.totalDeposited * 100).toFixed(2),
        coverageRatio: (account.balances.freeMargin / Math.max(account.balances.lockedInitialMargin, 1) * 100).toFixed(2),
      },
      // Status
      status: {
        isHealthy: account.balances.freeMargin > 0,
        isLiquidatable: account.balances.freeMargin < account.balances.lockedInitialMargin * 0.5,
        lastUpdated: account.lastUpdated,
      },
      // Supported collateral
      acceptedCollateral: [
        { token: "USDC", address: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", value: 1.0 },
        { token: "USDT", address: "0x7169D38820dfd117C3FA1fF23499B86C8A2d1b10", value: 1.0 },
        { token: "DAI", address: "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063", value: 1.0 },
      ],
    },
    meta: {
      version: "1.0.0",
      provider: "ClearRate Margin Engine",
      calculatedAt: new Date().toISOString(),
      disclaimer: "Mock API - Do not use for production",
    }
  };

  return NextResponse.json(response);
}

// POST endpoint - deposit or withdraw collateral
export async function POST(request: Request) {
  try {
    const body = await request.json();
    
    const {
      accountId,
      action, // "DEPOSIT" or "WITHDRAW"
      token, // "USDC", "USDT", "DAI"
      amount,
    } = body;

    // Validate required fields
    if (!accountId || !action || !token || !amount) {
      return NextResponse.json(
        {
          success: false,
          error: "Missing required fields: accountId, action, token, amount",
        },
        { status: 400 }
      );
    }

    // Validate action
    if (action !== "DEPOSIT" && action !== "WITHDRAW") {
      return NextResponse.json(
        {
          success: false,
          error: "Invalid action. Must be DEPOSIT or WITHDRAW",
        },
        { status: 400 }
      );
    }

    // Validate token
    const acceptedTokens = ["USDC", "USDT", "DAI"];
    if (!acceptedTokens.includes(token)) {
      return NextResponse.json(
        {
          success: false,
          error: `Invalid token. Accepted tokens: ${acceptedTokens.join(", ")}`,
        },
        { status: 400 }
      );
    }

    // Get or create account
    let account = marginAccounts.get(accountId);
    if (!account) {
      account = initializeAccount(accountId);
      marginAccounts.set(accountId, account);
    }

    const amountNum = Number(amount);

    if (action === "DEPOSIT") {
      // Add to total and free margin
      account.balances.totalDeposited += amountNum;
      account.balances.freeMargin += amountNum;
    } else {
      // Check sufficient free margin
      if (account.balances.freeMargin < amountNum) {
        return NextResponse.json(
          {
            success: false,
            error: "Insufficient free margin for withdrawal",
            available: account.balances.freeMargin,
            requested: amountNum,
          },
          { status: 400 }
        );
      }
      // Subtract from total and free margin
      account.balances.totalDeposited -= amountNum;
      account.balances.freeMargin -= amountNum;
    }

    account.lastUpdated = new Date().toISOString();

    const response = {
      success: true,
      data: {
        transaction: {
          action,
          token,
          amount: amountNum,
          status: "COMPLETED",
          transactionHash: "0x" + generateMockTxHash(),
          timestamp: account.lastUpdated,
        },
        accountId: account.accountId,
        balances: {
          totalDeposited: account.balances.totalDeposited,
          lockedInitialMargin: account.balances.lockedInitialMargin,
          lockedVariationMargin: account.balances.lockedVariationMargin,
          lockedMargin: account.balances.lockedInitialMargin + account.balances.lockedVariationMargin,
          freeMargin: account.balances.freeMargin,
        },
        // Transaction event
        event: {
          type: action === "DEPOSIT" ? "MARGIN_DEPOSITED" : "MARGIN_WITHDRAWN",
          accountId: account.accountId,
          amount: amountNum,
          token,
          timestamp: account.lastUpdated,
        },
      },
      meta: {
        version: "1.0.0",
        provider: "ClearRate Margin Engine",
        calculatedAt: new Date().toISOString(),
        disclaimer: "Mock API - Do not use for production",
      }
    };

    return NextResponse.json(response);
  } catch (error) {
    return NextResponse.json(
      {
        success: false,
        error: "Invalid request body",
        details: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 400 }
    );
  }
}

// PATCH endpoint - lock/unlock margin for positions
export async function PATCH(request: Request) {
  try {
    const body = await request.json();
    
    const {
      accountId,
      action, // "LOCK" or "UNLOCK"
      amount,
      reason, // "OPEN_POSITION", "CLOSE_POSITION", "VARIATION_MARGIN"
    } = body;

    // Validate required fields
    if (!accountId || !action || !amount) {
      return NextResponse.json(
        {
          success: false,
          error: "Missing required fields: accountId, action, amount",
        },
        { status: 400 }
      );
    }

    // Validate action
    if (action !== "LOCK" && action !== "UNLOCK") {
      return NextResponse.json(
        {
          success: false,
          error: "Invalid action. Must be LOCK or UNLOCK",
        },
        { status: 400 }
      );
    }

    // Get or create account
    let account = marginAccounts.get(accountId);
    if (!account) {
      account = initializeAccount(accountId);
      marginAccounts.set(accountId, account);
    }

    const amountNum = Number(amount);

    if (action === "LOCK") {
      // Check sufficient free margin
      if (account.balances.freeMargin < amountNum) {
        return NextResponse.json(
          {
            success: false,
            error: "Insufficient free margin to lock",
            available: account.balances.freeMargin,
            requested: amountNum,
          },
          { status: 400 }
        );
      }
      // Move from free to locked
      account.balances.freeMargin -= amountNum;
      if (reason === "VARIATION_MARGIN") {
        account.balances.lockedVariationMargin += amountNum;
      } else {
        account.balances.lockedInitialMargin += amountNum;
      }
    } else {
      // Unlock - move from locked to free
      if (reason === "VARIATION_MARGIN") {
        if (account.balances.lockedVariationMargin < amountNum) {
          return NextResponse.json(
            {
              success: false,
              error: "Insufficient locked variation margin to unlock",
            },
            { status: 400 }
          );
        }
        account.balances.lockedVariationMargin -= amountNum;
      } else {
        if (account.balances.lockedInitialMargin < amountNum) {
          return NextResponse.json(
            {
              success: false,
              error: "Insufficient locked initial margin to unlock",
            },
            { status: 400 }
          );
        }
        account.balances.lockedInitialMargin -= amountNum;
      }
      account.balances.freeMargin += amountNum;
    }

    account.lastUpdated = new Date().toISOString();

    const response = {
      success: true,
      data: {
        transaction: {
          action,
          reason: reason || "GENERAL",
          amount: amountNum,
          status: "COMPLETED",
          timestamp: account.lastUpdated,
        },
        accountId: account.accountId,
        balances: {
          totalDeposited: account.balances.totalDeposited,
          lockedInitialMargin: account.balances.lockedInitialMargin,
          lockedVariationMargin: account.balances.lockedVariationMargin,
          lockedMargin: account.balances.lockedInitialMargin + account.balances.lockedVariationMargin,
          freeMargin: account.balances.freeMargin,
        },
        // Event
        event: {
          type: action === "LOCK" ? "MARGIN_LOCKED" : "MARGIN_UNLOCKED",
          accountId: account.accountId,
          amount: amountNum,
          reason: reason || "GENERAL",
          timestamp: account.lastUpdated,
        },
      },
      meta: {
        version: "1.0.0",
        provider: "ClearRate Margin Engine",
        calculatedAt: new Date().toISOString(),
        disclaimer: "Mock API - Do not use for production",
      }
    };

    return NextResponse.json(response);
  } catch (error) {
    return NextResponse.json(
      {
        success: false,
        error: "Invalid request body",
        details: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 400 }
    );
  }
}

function generateMockTxHash(): string {
  return Array.from({ length: 64 }, () => 
    Math.floor(Math.random() * 16).toString(16)
  ).join('');
}

export const runtime = 'edge';
