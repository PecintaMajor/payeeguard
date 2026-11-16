# PayeeGuard — Verified Payables Agent for Aevum

**PayeeGuard is an accounts-payable agent that pays tUSD8 invoices on the Aevum testnet
only to identity-verified payees, under a revocable, spend-capped agent mandate.**

It combines three payment primitives in one flow:

1. **Confirmation of Payee (CoP)** — a payee identity registry (ERC-8004-flavored) binds a
   payee's name + metadata to a payout address with a verification flag. Payments to
   unverified payees are impossible at contract level.
2. **Invoice payments** — an invoice book with a strict `Issued → Paid / Cancelled`
   lifecycle, double-pay protection, and payment by `transferFrom` straight to the
   registry-bound payout address.
3. **Native AI-assistant mandate** — the payer grants an agent a scoped mandate
   (per-payment cap, total budget, expiry, one allowed invoice book, optional payee
   allowlist). The agent pays due invoices autonomously; every limit is enforced
   atomically on-chain, and the owner can **revoke instantly**.

Built for the **Aevum Builder Challenge #1** (QDay / DoraHacks). Testnet only, test
tokens only.

## Architecture

```
                 ┌────────────────┐   register / verify    ┌──────────────┐
   Payer (owner) │ PayeeRegistry  │◄───────────────────────│  Web UI /    │
        │        │  (CoP lookup)  │                        │  agent CLI   │
        │        └───────▲────────┘                        └──────────────┘
        │                │ isVerified(payeeId) / payoutOf
        │        ┌───────┴────────┐  createInvoice          ┌──────────────┐
        ├───────►│  InvoiceBook   │◄────────────────────────│    Payer     │
        │        │ Issued→Paid    │                         └──────────────┘
        │        └───────▲────────┘
        │                │ payInvoiceOnBehalf (only from mandate contract)
        │        ┌───────┴────────┐  grant / revoke          ┌──────────────┐
        └───────►│ AgentMandate   │◄────────────────────────│    Payer     │
                 │ cap·budget·    │   payInvoice(mandate,    │ Agent runner │
                 │ expiry·revoke  │──────── invoice) ──────►│ polls & pays │
                 └────────────────┘   (agent wallet)         └──────────────┘
   Funds flow: tUSD8.transferFrom(payer → payee payout) executed by InvoiceBook.
```

| Component | File | Role |
|---|---|---|
| `PayeeRegistry.sol` | `src/` | Payee identities: name, metadata hash, payout address, verification flag; CoP lookups by address and by name. |
| `InvoiceBook.sol` | `src/` | Invoice lifecycle; pay-only-verified guard; anti-double-pay; direct pay + mandate pay paths. |
| `AgentMandate.sol` | `src/` | Scoped agent authority: cap, budget, expiry, allowlist, instant revoke, `AgentPayment` audit events. |
| Agent runner | `agent/agent.mjs` | Node + viem. Polls for due invoices, pays within mandate, **holds** anything unverified / over-cap / over-budget and logs why. Also runs the scripted `demo` flow. |
| Web UI | `ui/index.html` | Single self-contained page (ethers.js via CDN): CoP lookup, register payee, create invoice, mandate grant/revoke, invoice table, activity log with explorer links. |

### A note on ERC-8004

The challenge starter kit names ERC-8004 as the identity standard for Confirmation of
Payee. On 2026-11-16 the canonical ERC-8004 registry addresses used across EVM chains
(`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`, `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`,
`0x8004Cb1BF31DAf7788926d9Ea82e8b26D1d2e51b`) were probed with `eth_getCode` on Aevum
(chain 44005): **no official ERC-8004 registry is deployed on the Aevum testnet**.
`PayeeRegistry` therefore implements the same identity semantics locally — name +
metadata hash bound to a payout address, a verification flag, and CoP lookups — and can
be swapped for the official registry if/when QDay deploys one.

## Network

| | |
|---|---|
| Chain | Aevum testnet, chain ID **44005** |
| RPC | https://rpc-test.qday.info |
| Explorer | https://explorer-test.qday.info |
| tUSD8 | `0x456569838f1d43009A91ebA4263147Afd7233483` (ERC-20, 6 decimals) |
| Gas token | tQDAY (faucet: https://faucet.qday.info/en) |

## Deployed contracts

**Aevum testnet deployment is pending wallet funding** — see
[DEMO-FLOW.md](DEMO-FLOW.md) section A for the exact blocker (faucet Turnstile +
mainnet-eligibility for fresh wallets) and the one-command deploy that follows funding.
The full stack — deploy script, demo flow, agent poll mode — has been executed
end-to-end on a local chain-44005 rehearsal (DEMO-FLOW.md section B):

| Contract | Local rehearsal address (Anvil, NOT on Aevum explorer) |
|---|---|
| PayeeRegistry | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| InvoiceBook | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` |
| AgentMandate | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` |

Once deployed on testnet, addresses land in `deployments.json` (see
`deployments.example.json`) and the explorer verification will be submitted via the
explorer's contract-verification API (Blockscout-style `/api` endpoint configured in
`foundry.toml`).

## Run it

### Contracts + tests

```bash
forge build
forge test        # 12 tests: happy path, double-pay, unverified payee, over-cap,
                  # budget exhaustion, expiry, revocation, allowlist, CoP lookups…
```

### Deploy (testnet)

```bash
DEPLOYER_PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url aevum --broadcast
# copy addresses from broadcast/Deploy.s.sol/44005/run-latest.json into deployments.json
node scripts/build-ui.mjs deployments.json   # wire addresses into the UI
```

### Agent runner

```bash
cd agent && npm install
node agent.mjs status        # read-only snapshot
node agent.mjs demo          # scripted demo flow (agent executes the payment)
node agent.mjs run           # polling mode: pays due invoices within the mandate,
                             # holds + logs anything out of scope
```

Wallets are read from `.secrets/wallets.json` (`{payer, payee, agent}` — **never commit
this file**; it is git-ignored). Deployment addresses come from `deployments.json`
(env overrides: `RPC_URL`, `WALLETS_FILE`, `DEPLOYMENTS_FILE`, `MANDATE_ID`,
`POLL_SECONDS`).

### Web UI

Serve the repo root (or just the `ui/` folder together with `deployments.json`) with any
static host — e.g. GitHub Pages — and open `ui/index.html`. The page auto-loads
`deployments.json` from its own directory when present; otherwise rebuild with
`node scripts/build-ui.mjs <deployments.json>` to bake the addresses in. Connect a
wallet on chain 44005 to transact; all reads also work without a wallet.

## Demo flow

Register "Acme Studio" → verify → invoice **INV-0142, 120 tUSD8** → mandate
(cap 150, budget 500, 7 days) → **agent pays** → explorer proof → revoke mandate →
agent payment attempt on INV-0143 **reverts**. Full transaction record:
[DEMO-FLOW.md](DEMO-FLOW.md).

## Safety model

- **Least privilege:** the agent can only pay invoices from one book, for one payer,
  under cap/budget/expiry — enforced in the same transaction as the payment.
- **Instant revocation:** one owner transaction disables the mandate permanently.
- **Confirmation of Payee:** unverified (or de-verified) payees cannot be paid, on both
  the direct and agent paths.
- **No double-pay:** invoice state flips to `Paid` before funds move.
- **Audit trail:** every registration, verification, invoice, mandate and agent payment
  is an on-chain event (see the UI activity log).

## License

MIT — see [LICENSE](LICENSE).
