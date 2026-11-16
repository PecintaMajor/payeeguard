# PayeeGuard — Demo Flow Record (Aevum Testnet)

## Aevum testnet run — ✅ COMPLETE (2026-11-16, chain 44005)

The full demo flow was executed live on the Aevum testnet by the agent runner
(`agent/agent.mjs demo` + one poll-mode pass), using the **rescaled Plan B amounts**
(the payer wallet holds exactly 1.0 tUSD8 from the faucet): invoice INV-0142 = **0.4 tUSD8**,
mandate cap **0.5** / budget **0.9**, invoice INV-0143 = **0.3 tUSD8**. Total paid out:
0.7 tUSD8. Raw machine log: `demo-log.testnet.json`.

### Deployed contracts (live deployment)

| Contract | Address | Deploy tx |
|---|---|---|
| PayeeRegistry | `0x8df477a83e397249B2CfE83292A51cFBFD098471` | [0x232075a7…f9a188](https://explorer-test.qday.info/tx/0x232075a75e4547ec0c04a9e756f4414058f0ecc8e7483dbc4ee1382626f9a188) |
| InvoiceBook | `0x815F4274F27c197050384D6dAaF35f606cF1F8D5` | [0x8b6a3486…7d03](https://explorer-test.qday.info/tx/0x8b6a348601893448217a0deb3c07674aedf8dc944758f2c324be5fe6bd947d03) |
| AgentMandate | `0xE49C4b3CDe3D7858f5E13C43fA8A62fFCf89473C` | [0x8610f91c…6899](https://explorer-test.qday.info/tx/0x8610f91cbd6c5c4a02ab1d24ff199f9c031285c5cf14a6357783d11b8c656899) |
| InvoiceBook.setMandateContract wiring | — | [0x8dd3c569…f3](https://explorer-test.qday.info/tx/0x8dd3c569e80c015112963afba329c730075a68a08d91c57d178f03deec71a0f3) |

Deploy block: 3287259. Token: tUSD8 `0x456569838f1d43009A91ebA4263147Afd7233483` (real testnet token, 6 decimals).
All three addresses were verified to hold code on chain 44005 before the demo ran.

> **⚠️ EVM-version incident (why there are two deployments):** the first deployment used
> Foundry's default **Cancun** target for solc 0.8.26. The Aevum testnet EVM does not
> support the Cancun `MCOPY` opcode: simple calls worked (register/verify succeeded), but
> every string-returning call failed with `invalid opcode: MCOPY` (RPC error -32000),
> starting with `confirmPayee`. That first set — PayeeRegistry `0x043e67e3D9E621221bf6ad919b2db0d5299169cb`,
> InvoiceBook `0x8f589b96195aE6B5E17632f729DDB3Ac4b6B2D94`, AgentMandate `0xb94909D783452aB334c05f7d0F70579E857d35Aa`,
> block 3287061, register tx `0xcca34a4f343955b76c84fcb46af52dd8843a73197dc5b54bf977b398f5e974bc`,
> verify tx `0x512f5d716c836af8172e80a73cf2a617ad4314802ccc63e2b5bfd48f2c0ad1e3` — was abandoned.
> The contracts were recompiled with `evm_version = "shanghai"` in `foundry.toml`
> (bytecode disassembly confirmed 0 MCOPY opcodes; contract sources untouched) and
> redeployed as the live set above.

### Demo steps

| # | Step | Tx | Result |
|---|---|---|---|
| 1 | Register payee "Acme Studio" (id 1, payout = payee wallet) | [0x47547578…63d31](https://explorer-test.qday.info/tx/0x4754757801fa378eaa50e2790a0c5f2965a95a1f4fec3be8b6ec510b05c63d31) | ✅ |
| 2 | Verify payee (CoP) | [0x5a434763…91c7a](https://explorer-test.qday.info/tx/0x5a434763f2a7b7347cb9a1136b014a147f89cd2ca688f5122838a10698391c7a) | ✅ CoP lookup by payout address → id 1, "Acme Studio", **verified=true** |
| 3 | Payer approves InvoiceBook (0.9 tUSD8) | [0x7e989d45…6528](https://explorer-test.qday.info/tx/0x7e989d45960e9b8487139cc5b47f86d92ee3e764aa459b161e9fe4b6f45e6528) | ✅ |
| 4 | Create invoice INV-0142 (0.4 tUSD8) | [0x741f6d6a…20fbd](https://explorer-test.qday.info/tx/0x741f6d6a7ef26b5e9b3bdea048949b3a737b5b2159134265e14ded328a420fbd) | ✅ invoice #1 Issued |
| 5 | Grant mandate #1 (cap 0.5 / budget 0.9 / 7 days) | [0x64724e07…50fd3](https://explorer-test.qday.info/tx/0x64724e07e07045c0fd4ef4103a13baac533ff16e76c7a826dc0c28e003d50fd3) | ✅ mandate #1 |
| 6 | **Agent pays INV-0142** | [0x0ba0997b…d8234](https://explorer-test.qday.info/tx/0x0ba0997b2ffeb7182b1d957f0b57f9c6e95ebe6e492acdb69cee56aaacdd8234) | ✅ receipt success; invoice **Paid**; payee balance **+0.4 tUSD8** |
| 7 | Create invoice INV-0143 (0.3 tUSD8) | [0x99771209…f62e](https://explorer-test.qday.info/tx/0x99771209909742801f9a380c37203e795a537768562573689debe7ecb337f62e) | ✅ invoice #2 Issued |
| 8 | Owner revokes mandate #1 | [0xee702f34…f9ed](https://explorer-test.qday.info/tx/0xee702f34e1f1a2e44309242855074e28d7480c66f2ff4217e0f721120f99f9ed) | ✅ |
| 9 | Agent attempts to pay INV-0143 | [0x9e7c4f92…bea1b](https://explorer-test.qday.info/tx/0x9e7c4f92d1b621b71dcc0b70f52ff9f6ee83af1d40b0acd4285e93f330abea1b) | ✅ tx mined and **reverted** (revoked mandate); invoice stays **Issued**; payee balance unchanged (0.4) |
| 10 | Bonus: mandate #2 granted ([0xcaf99595…0cc0c](https://explorer-test.qday.info/tx/0xcaf99595c6f13eb4763fcdcb0e5522f03acae4e638dcc6ec149671104530cc0c)), then `agent.mjs run --once` in poll mode | [0x948ccba7…4a49e](https://explorer-test.qday.info/tx/0x948ccba7746472c2d272155f40d0cbfba493c3801a5369266aaa09fa0f14a49e) | ✅ runner autonomously paid INV-0143 (0.3 tUSD8), receipt success; invoice **Paid** |

### Final state (verified on-chain after the run)

| Wallet | tQDAY (gas) | tUSD8 |
|---|---|---|
| payer `0x49FAdBEeAE33B33ECbceC6f6E43F1005086D2233` | 3.498870582957234832 | **0.3** |
| agent `0xd458b839dbAfB401dB40F4F2097bc5F0EC5Ecb43` | 0.499564401999832 | 0 |
| payee `0x232C0b7811357C8f8A3e9520325cEf5f4E80C4fc` | 0 | **0.7** |

Invoices: #1 INV-0142 **Paid**, #2 INV-0143 **Paid**. Mandate #1: revoked, spent 0.4.
Mandate #2: active, spent 0.3 of 0.9 budget. Total spent 0.7 ≤ 1.0 tUSD8 funded. ✅

### Explorer source verification

Attempted via the route configured in `foundry.toml` (`forge verify-contract`,
Blockscout verifier at `https://explorer-test.qday.info/api`). All three submissions
were accepted (GUIDs `8df477a8…6afa7513`, `815f4274…6afa7523`, `e49c4b3c…6afa7520`),
but the explorer's `verify-check` returned **"Fail – Unable to verify"** for all three —
source verification is not finalized on the explorer side. The deployed bytecode is
on-chain and matches the repo sources compiled with solc 0.8.26 / `evm_version = "shanghai"`.

### deployments.json placement

- `payeeguard/deployments.json` (repo root) — canonical record (addresses, chain 44005,
  token, role wallets, deployBlock 3287259, mandateId 2, superseded first deployment noted).
- `payeeguard/ui/deployments.json` and `payeeguard/docs/deployments.json` — copies placed
  next to the UI pages (the UI fetches `deployments.json` at runtime).
- `ui/index.html` rebuilt via `node scripts/build-ui.mjs deployments.json` with the live
  addresses baked into CONFIG, and copied to `docs/index.html` (GitHub Pages copy), the
  same sync mechanism used for the original build.
