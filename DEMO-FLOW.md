# PayeeGuard — Demo Flow Record

Demo script (from the challenge concept): register payee **"Acme Studio"** → verify it →
create invoice **INV-0142** for **120 tUSD8** → grant the agent a mandate
(**cap 150, budget 500, 7 days**) → **agent auto-pays** the invoice → revoke the mandate →
agent payment attempt on a second invoice **correctly reverts**.

The flow is executed by the agent runner itself (`agent/agent.mjs demo`) — the agent
payment is made by the agent wallet through `AgentMandate.payInvoice`, not by hand.

---

## A. Aevum testnet run — ⛔ BLOCKED at wallet funding (2026-11-16)

Everything is built and rehearsed (section B), but the testnet run cannot start because
the three role wallets cannot be funded from this environment:

1. **The official faucet requires a human bot-check.** The claim flow at
   https://faucet.qday.info/en loads Cloudflare Turnstile
   (`challenges.cloudflare.com/turnstile`) and resolves a Turnstile token before any
   claim is submitted.
2. **The faucet requires mainnet eligibility the fresh wallets don't have.** Per the
   faucet FAQ, a recipient must hold ~0.0001 ETH **or** 1 USDT **or** 1 USDC on Ethereum
   mainnet. Verified live against the faucet backend on 2026-11-16:
   `GET https://faucet.qday.info/gasapi/eligibility?address=0x49FAdBEeAE33B33ECbceC6f6E43F1005086D2233`
   → `{"eligible":false,"via":null}`. The tUSD8 claim route
   (`POST /api/tusd8/<address>`) rejects non-browser requests (`"Request origin rejected"`).
3. **No zero-gas shortcut exists.** Gas price is 1 gwei; a signed 0-gas-price transaction
   from the payer wallet was rejected by the RPC with
   `insufficient funds for gas * price + value` (a probe tx was accepted into the mempool
   at 0 gas price but can never be mined). The gas-relay drip is gated by the same
   eligibility check.

### Wallets that need funding (Aevum testnet, chain 44005)

| Role | Address | Needs |
|---|---|---|
| payer / owner | `0x49FAdBEeAE33B33ECbceC6f6E43F1005086D2233` | tQDAY for gas (deploys + setup) **and ≥ 620 tUSD8** (500 budget + 120 invoice buffer) |
| agent | `0xd458b839dbAfB401dB40F4F2097bc5F0EC5Ecb43` | tQDAY for gas only |
| payee | `0x232C0b7811357C8f8A3e9520325cEf5f4E80C4fc` | nothing (receives only) — a little tQDAY is nice-to-have |

Keys live only in `.secrets/wallets.json` (chmod 600, git-ignored) — never in this repo.

**Unblock paths (human steps):** claim from the web faucet with a browser (Turnstile) —
note the recipient mainnet-eligibility rule above — or use the QDay Discord
`#testnet-faucet` manual fallback, or send tQDAY/tUSD8 from any already-funded Aevum
testnet wallet.

### Exact commands for the testnet run, once funded

```bash
cd payeeguard
export DEPLOYER_PRIVATE_KEY=<payer key from .secrets/wallets.json>
forge script script/Deploy.s.sol --rpc-url aevum --broadcast   # deploys all 3 contracts
# copy the addresses from broadcast/Deploy.s.sol/44005/run-latest.json into deployments.json
node scripts/build-ui.mjs deployments.json                     # re-wire the UI
cd agent && node agent.mjs demo                                # full demo flow, writes ../demo-log.json
```

---

## B. Local rehearsal run — ✅ COMPLETE (2026-11-16, Anvil @ chain 44005)

The identical code, deploy script and agent runner were executed end-to-end on a local
Anvil instance with chain ID 44005 and a mock tUSD8 (same 6-decimals interface), to prove
the full flow before the testnet run. These are **local** transactions — they do not
appear on the Aevum explorer.

Deployed (local): PayeeRegistry `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`,
InvoiceBook `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9`,
AgentMandate `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`,
MockUSD8 `0xe7f1725E7734CE288F8367E1bb143E90bb3F0512`.

| # | Step | Tx (local) | Result |
|---|---|---|---|
| 1 | Register payee "Acme Studio" (id 1) | `0x0383ef5fd404c488740d53a6ab2ab7fb53d325036f4b96f0b10ba2ea1e42d33f` | ✅ |
| 2 | Verify payee (CoP) | `0x809b2947e1a6469573169bd8fadc8ca8541b77f7ce8bd38dddaff43d21c832df` | ✅ CoP lookup by address → id 1, "Acme Studio", verified |
| 3 | Payer approves InvoiceBook (500 tUSD8) | `0x9001f98a4cd59a2be026b444273793643ce36bbfbd53d222a2f7331a7cd082df` | ✅ |
| 4 | Create invoice INV-0142 (120 tUSD8) | `0xdf0c54896b33a660225fd28d9f76d2b5d00c8c282a49c61287b3706b19dd949f` | ✅ invoice #1 Issued |
| 5 | Grant mandate (cap 150 / budget 500 / 7 days) | `0xa9aa1e18a60d43026b6ced04b03b473e7734cb1ec47ac6fbe318c40216d4347a` | ✅ mandate #1 |
| 6 | **Agent pays INV-0142** | `0xad7cb13aed0a6592962f09dce510274bc9320f8a962be75213497f12579aca8d` | ✅ receipt success; invoice **Paid**; payee balance **+120 tUSD8** |
| 7 | Create invoice INV-0143 (80 tUSD8) | `0x6435fbdb27d9d41e919df5d7425e1ad94964cf17485798f9906336eb17890f63` | ✅ invoice #2 Issued |
| 8 | Owner revokes mandate #1 | `0x20f62f4224fce00b655025612d3c4fda0af98acb95f78bdf57d308919eae445f` | ✅ |
| 9 | Agent attempts to pay INV-0143 | `0xd92afbfc64828ba9c78f256edc1973cc1615c0f48fb0c934d4d3389ecf0118b5` | ✅ receipt **reverted** (`MandateRevokedError`); invoice stays **Issued** |
| 10 | Poll-mode check: fresh mandate #2 granted, `agent.mjs run --once` | `0xd699c02275bb22bad8f3dabe270925d1a9cf3008554e226e00b140959a927249` | ✅ runner autonomously paid INV-0143 (80 tUSD8), receipt success |

Raw machine log: `demo-log.local.json` (local rehearsal). The testnet run will produce
`demo-log.json` in the same format.
