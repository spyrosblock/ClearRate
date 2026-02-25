Building a Central Counterparty (CCP) like LCH SwapClear involves a highly regulated, automated workflow. Below is a structured Markdown file that describes the Interest Rate Swap (IRS) lifecycle from the perspective of a clearing house.

To fulfill your request for data and calculations, this guide replaces traditional math with a programmatic approach using **market-leading financial APIs**.

---

# Interest Rate Swap (IRS) Lifecycle: CCP Operations

This document outlines the end-to-end lifecycle of a cleared Interest Rate Swap, simulating the operations of a Central Counterparty (CCP).

## 1. Trade Capture & Novation (T+0)

The lifecycle begins when two counterparties (e.g., a Bank and a Hedge Fund) execute a trade on an SEF (Swap Execution Facility) or via an Inter-dealer Broker.

* **Submission:** The trade is submitted to the CCP via an "Approved Trade Source" (e.g., MarkitWire).
* **Novation:** The CCP "interposes" itself. The original contract between Party A and Party B is extinguished and replaced by two new contracts:
1. **Party A vs. CCP**
2. **CCP vs. Party B**


* **CCP Role:** You are now the buyer to every seller and the seller to every buyer, eliminating bilateral credit risk.

---

## 2. Risk Management & Initial Margin

Before a trade is "registered," the CCP must ensure the participants have sufficient collateral.

### Calculating Initial Margin (IM)

Instead of using manual Value-at-Risk (VaR) formulas, a modern CCP uses APIs to calculate potential future exposure.

* **Logic:** The CCP uses the **PAIRS (Portfolio Approach to Interest Rate Scenarios)** methodology. It looks at 10 years of historical volatility to predict a 99% confidence interval loss over a 5-day holding period.
* **API Implementation:**
> **BlueGamma API** or **LSEG Analytics API**
> * **Endpoint:** `/analytics/initial-margin`
> * **Input:** Trade Notional, Tenor (e.g., 10Y), Currency (USD/EUR), and Index (SOFR/EURIBOR).
> * **Result:** The "Requirement Amount" to be posted by the member.
> 
> 



---

## 3. Daily Valuation & Variation Margin (Daily)

Every business day, the CCP "marks-to-market" (MTM) the position. This is the most critical operational phase.

### Step A: Fetching the Yield Curve

To value a swap, you need the current OIS (Overnight Index Swap) curve for discounting.

* **API Solution:** **API Ninjas** or **BlueGamma**.
* **Command:** `GET /v2/interestrate?name=SOFR`
* **Action:** Retrieve the current benchmark rate to build the discount curve.

### Step B: Calculating Net Present Value (NPV)

The NPV is the difference between the Fixed Leg and the Floating Leg.

* **API Implementation:**
> **LSEG Workspace API**
> * **Function:** `get_swap_npv(trade_data, market_data)`
> * **Calculation:** The API fetches the forward curve, projects future SOFR fixes, and discounts them back to the present.
> 
> 



### Step C: Variation Margin (VM) Call

If the NPV of the trade moves in favor of the CCP, the Member must pay VM. If it moves in favor of the Member, the CCP pays them. This ensures no debt accumulates.

---

## 4. Floating Rate Resets (Periodic)

For the floating leg of the swap (e.g., 3-month EURIBOR or daily SOFR), the CCP must "fix" the rate on the reset date.

* **Data Sourcing:**
* **ECB Data Portal API:** For EURIBOR rates.
* **Riksbank API / New York Fed API:** For daily overnight benchmarks.


* **Operational Task:** The CCP's "Gold Record" database updates the coupon payment for that period based on the API response.

---

## 5. Coupon Payment & Settlement

On payment dates (quarterly, semi-annual, etc.), the CCP calculates the net cash flow.

| Side | Formula (API Logic) |
| --- | --- |
| **Fixed Leg** | `Notional * FixedRate * DayCountFraction` |
| **Float Leg** | `Notional * (API_Reference_Rate) * DayCountFraction` |
| **Settlement** | `Net(Fixed - Float)` |


Example for how it's supposed to work

1. Deploy contracts:`cd contracts && make deploy-contracts-sepolia && cd ..`
2. (Update `contracts/.env`, `create-trade-workflow/config.staging.json` and `settle-vm-workflow/config.staging.json` with new addresses)
3. Deployer whitelists the user addresses: `cd contracts && make whitelist-users-sepolia && cd ..`
4. Users deposit collateral: `cd contracts && make deposit-margin-sepolia && cd ..`
5. Create a trade and user signatures: `cd contracts && make create-trade-sepolia && cd ..`
6. Call the cre api to create the swap: `cd create-trade-workflow && bun install && cd .. && cre workflow simulate create-trade-workflow --target staging-settings --broadcast --http-payload "$(cat ./contracts/scripts-js/trade.json)" --non-interactive --trigger-index 0`
7. Settle the variation margin for all positions daily: `cd settle-vm-workflow && bun install && cd .. && cre workflow simulate settle-vm-workflow --target staging-settings --broadcast`
8. The user can withdraw their collateral after the trade is settled: `cd contracts && make withdraw-margin-sepolia && cd ..`


Read commands:
1. Free margin: `cd contracts && make get-margin-data-sepolia && cd ..`