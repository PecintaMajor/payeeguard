#!/usr/bin/env node
/**
 * PayeeGuard agent runner.
 *
 * Modes:
 *   node agent.mjs status   Read-only snapshot: balances, invoices, mandate.
 *   node agent.mjs demo     Scripted end-to-end demo flow (see DEMO-FLOW.md):
 *                           register+verify "Acme Studio" -> invoice INV-0142 (0.4 tUSD8)
 *                           -> grant mandate (cap 0.5 / budget 0.9 / 7 days)
 *                           -> THE AGENT pays INV-0142 -> revoke -> agent payment on
 *                           INV-0143 correctly reverts.
 *   node agent.mjs run      Polling mode: scans for due Issued invoices of the mandate
 *                           owner and pays those inside the mandate; anything unverified,
 *                           over-cap or over-budget is HELD and logged with the reason.
 *   node agent.mjs run --once   Single polling pass, then exit.
 *
 * Config via env:
 *   RPC_URL           default https://rpc-test.qday.info
 *   CHAIN_ID          default 44005
 *   EXPLORER          default https://explorer-test.qday.info
 *   WALLETS_FILE      default ../.secrets/wallets.json   ({payer,payee,agent:{address,privateKey}})
 *   DEPLOYMENTS_FILE  default ../deployments.json        ({payeeRegistry,invoiceBook,agentMandate,tUsd8,mandateId?})
 *   POLL_SECONDS      default 30 (run mode)
 *   DEMO_LOG          default ../demo-log.json
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  createPublicClient, createWalletClient, http, defineChain,
  formatUnits, keccak256, toBytes,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');

const RPC_URL = process.env.RPC_URL || 'https://rpc-test.qday.info';
const CHAIN_ID = Number(process.env.CHAIN_ID || 44005);
const EXPLORER = (process.env.EXPLORER || 'https://explorer-test.qday.info').replace(/\/$/, '');
const WALLETS_FILE = process.env.WALLETS_FILE || path.join(ROOT, '.secrets', 'wallets.json');
const DEPLOYMENTS_FILE = process.env.DEPLOYMENTS_FILE || path.join(ROOT, 'deployments.json');
const DEMO_LOG = process.env.DEMO_LOG || path.join(ROOT, 'demo-log.json');
const POLL_SECONDS = Number(process.env.POLL_SECONDS || 30);

const abis = JSON.parse(fs.readFileSync(path.join(HERE, 'abis.json'), 'utf8'));
const wallets = JSON.parse(fs.readFileSync(WALLETS_FILE, 'utf8'));
const dep = JSON.parse(fs.readFileSync(DEPLOYMENTS_FILE, 'utf8'));

const chain = defineChain({
  id: CHAIN_ID,
  name: CHAIN_ID === 44005 ? 'Aevum Testnet' : `chain-${CHAIN_ID}`,
  nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: { default: { name: 'Aevum Explorer', url: EXPLORER } },
});

const transport = http(RPC_URL, { retryCount: 5, retryDelay: 1500, timeout: 30_000 });
const pub = createPublicClient({ chain, transport });

const accounts = {
  payer: privateKeyToAccount(wallets.payer.privateKey),
  payee: privateKeyToAccount(wallets.payee.privateKey),
  agent: privateKeyToAccount(wallets.agent.privateKey),
};
const wc = (role) => createWalletClient({ account: accounts[role], chain, transport });

const REG = { address: dep.payeeRegistry, abi: abis.payeeRegistry };
const BOOK = { address: dep.invoiceBook, abi: abis.invoiceBook };
const MAND = { address: dep.agentMandate, abi: abis.agentMandate };
const TOK = { address: dep.tUsd8, abi: abis.erc20 };

const TUSD = (n) => BigInt(Math.round(n * 1e6));
const fmt = (atomic) => `${formatUnits(atomic, 6)} tUSD8`;
const txLink = (h) => `${EXPLORER}/tx/${h}`;
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

/** Retry wrapper with exponential backoff for stall-prone RPC egress. */
async function retry(label, fn, attempts = 6) {
  let last;
  for (let i = 1; i <= attempts; i++) {
    try { return await fn(); }
    catch (e) {
      last = e;
      const msg = (e.shortMessage || e.message || '').slice(0, 160);
      console.log(`  [retry ${i}/${attempts}] ${label}: ${msg}`);
      if (i < attempts) await sleep(Math.min(2 ** i, 20));
    }
  }
  throw last;
}

async function send(role, contract, functionName, args) {
  const hash = await retry(`${role}.${functionName}`, () =>
    wc(role).writeContract({ ...contract, functionName, args }));
  const receipt = await retry(`wait ${functionName}`, () =>
    pub.waitForTransactionReceipt({ hash, timeout: 120_000 }));
  return { hash, receipt };
}

const read = (contract, functionName, args = []) =>
  retry(`read ${functionName}`, () => pub.readContract({ ...contract, functionName, args }));

// ---------------------------------------------------------------- status
async function status() {
  console.log(`chain ${CHAIN_ID} via ${RPC_URL}`);
  for (const role of ['payer', 'payee', 'agent']) {
    const bal = await pub.getBalance({ address: accounts[role].address });
    const tok = await read(TOK, 'balanceOf', [accounts[role].address]);
    console.log(`${role.padEnd(6)} ${accounts[role].address}  gas=${formatUnits(bal, 18)} tQDAY  token=${fmt(tok)}`);
  }
  console.log('registry', REG.address, '| book', BOOK.address, '| mandate', MAND.address, '| tUSD8', TOK.address);
  const count = await read(BOOK, 'invoiceCount');
  console.log(`invoices: ${count}`);
  for (let id = 1; id <= Number(count); id++) {
    const inv = await read(BOOK, 'getInvoice', [BigInt(id)]);
    console.log(`  #${id} ${inv.invoiceRef} payee=${inv.payeeId} amount=${fmt(inv.amount)} status=${['Issued', 'Paid', 'Cancelled'][inv.status]} payer=${inv.payer}`);
  }
  if (dep.mandateId) {
    const m = await read(MAND, 'getMandate', [BigInt(dep.mandateId)]);
    console.log(`mandate #${dep.mandateId}: agent=${m.agent} cap=${fmt(m.perPaymentCap)} budget=${fmt(m.totalBudget)} spent=${fmt(m.spent)} expiry=${new Date(Number(m.expiry) * 1000).toISOString()} revoked=${m.revoked}`);
  }
}

// ------------------------------------------------------------------ demo
async function demo() {
  const log = { startedAt: new Date().toISOString(), chainId: CHAIN_ID, rpc: RPC_URL, steps: [] };
  const step = (name, data) => { log.steps.push({ name, ...data }); console.log(`\n== ${name}`); };

  // Optional: mock-token rehearsal funding (local Anvil only; flag lives in deployments file)
  if (dep.mockToken) {
    const bal = await read(TOK, 'balanceOf', [accounts.payer.address]);
    if (bal < TUSD(1000)) {
      const r = await send('payer', TOK, 'mint', [accounts.payer.address, TUSD(10_000)]);
      step('mock mint 10,000 tUSD8 -> payer (local rehearsal only)', { tx: r.hash });
    }
  }

  // 1. Register payee "Acme Studio" (payer registers on behalf; binding is to payee payout address)
  let acmeId = await read(REG, 'payeeIdByName', ['Acme Studio']);
  if (acmeId === 0n) {
    const meta = keccak256(toBytes('acme-studio-metadata'));
    const r = await send('payer', REG, 'registerPayee', ['Acme Studio', meta, accounts.payee.address]);
    acmeId = await read(REG, 'payeeIdByName', ['Acme Studio']);
    step('register payee "Acme Studio"', { payeeId: acmeId.toString(), payout: accounts.payee.address, tx: r.hash, explorer: txLink(r.hash) });
  } else {
    step('payee "Acme Studio" already registered', { payeeId: acmeId.toString() });
  }

  // 2. Verify the payee (registry owner = payer)
  if (!(await read(REG, 'isVerified', [acmeId]))) {
    const r = await send('payer', REG, 'setVerified', [acmeId, true]);
    step('verify payee (Confirmation of Payee)', { payeeId: acmeId.toString(), tx: r.hash, explorer: txLink(r.hash) });
  } else step('payee already verified', { payeeId: acmeId.toString() });
  const cop = await read(REG, 'confirmPayee', [accounts.payee.address]);
  console.log(`   CoP lookup by payout address -> id=${cop[0]} name="${cop[1]}" verified=${cop[2]}`);

  // 3. Payer approves the InvoiceBook to pull up to the mandate budget
  const allowance = await read(TOK, 'allowance', [accounts.payer.address, BOOK.address]);
  if (allowance < TUSD(0.9)) {
    const r = await send('payer', TOK, 'approve', [BOOK.address, TUSD(0.9)]);
    step('payer approves InvoiceBook for 0.9 tUSD8', { tx: r.hash, explorer: txLink(r.hash) });
  } else step('allowance already sufficient', { allowance: fmt(allowance) });

  // 4. Create invoice INV-0142 for 120 tUSD8
  const before1 = await read(BOOK, 'invoiceCount');
  const inv1 = before1 + 1n;
  {
    const r = await send('payer', BOOK, 'createInvoice', [acmeId, TUSD(0.4), 'INV-0142', 0n, keccak256(toBytes('INV-0142 memo'))]);
    step('create invoice INV-0142 (0.4 tUSD8)', { invoiceId: inv1.toString(), tx: r.hash, explorer: txLink(r.hash) });
  }

  // 5. Grant the agent a mandate: cap 150, budget 500, 7 days
  const nextMid = await read(MAND, 'nextMandateId');
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 7 * 24 * 3600);
  {
    const r = await send('payer', MAND, 'grantMandate', [accounts.agent.address, TUSD(0.5), TUSD(0.9), expiry, BOOK.address, false, []]);
    step('grant mandate to agent (cap 0.5, budget 0.9, 7 days)', { mandateId: nextMid.toString(), tx: r.hash, explorer: txLink(r.hash) });
  }
  dep.mandateId = Number(nextMid);
  fs.writeFileSync(DEPLOYMENTS_FILE, JSON.stringify(dep, null, 2));

  // 6. THE AGENT pays INV-0142 under the mandate (executed by this runner, agent wallet)
  const payeeBalBefore = await read(TOK, 'balanceOf', [accounts.payee.address]);
  {
    const r = await send('agent', MAND, 'payInvoice', [nextMid, inv1]);
    const inv = await read(BOOK, 'getInvoice', [inv1]);
    const payeeBalAfter = await read(TOK, 'balanceOf', [accounts.payee.address]);
    step('AGENT pays INV-0142 under mandate', {
      tx: r.hash, explorer: txLink(r.hash), receiptStatus: r.receipt.status,
      invoiceStatus: ['Issued', 'Paid', 'Cancelled'][inv.status],
      payeeBalanceDelta: fmt(payeeBalAfter - payeeBalBefore),
    });
    if (inv.status !== 1) throw new Error('invoice not Paid after agent payment');
  }

  // 7. Second invoice INV-0143 (80 tUSD8), then the owner revokes the mandate
  const before2 = await read(BOOK, 'invoiceCount');
  const inv2 = before2 + 1n;
  {
    const r = await send('payer', BOOK, 'createInvoice', [acmeId, TUSD(0.3), 'INV-0143', 0n, keccak256(toBytes('INV-0143 memo'))]);
    step('create invoice INV-0143 (0.3 tUSD8)', { invoiceId: inv2.toString(), tx: r.hash, explorer: txLink(r.hash) });
  }
  {
    const r = await send('payer', MAND, 'revokeMandate', [nextMid]);
    step('owner revokes mandate (instant)', { mandateId: nextMid.toString(), tx: r.hash, explorer: txLink(r.hash) });
  }

  // 8. Agent attempts to pay INV-0143 -> must revert (MandateRevokedError)
  {
    let simError = null;
    try {
      await pub.simulateContract({ ...MAND, functionName: 'payInvoice', args: [nextMid, inv2], account: accounts.agent });
    } catch (e) { simError = (e.shortMessage || e.message || '').slice(0, 300); }
    let chainResult = 'simulation-reverted';
    let failHash = null, failStatus = null;
    try {
      failHash = await wc('agent').writeContract({ ...MAND, functionName: 'payInvoice', args: [nextMid, inv2], gas: 300_000n });
      const rc = await pub.waitForTransactionReceipt({ hash: failHash, timeout: 120_000 });
      failStatus = rc.status; chainResult = 'tx-mined';
    } catch (e) { /* estimation refused the send; simulation proof stands */ }
    const inv = await read(BOOK, 'getInvoice', [inv2]);
    step('agent payment attempt on INV-0143 after revocation', {
      simulationError: simError, onChain: chainResult, tx: failHash, receiptStatus: failStatus,
      invoiceStatus: ['Issued', 'Paid', 'Cancelled'][inv.status], expected: 'reverted, invoice stays Issued',
    });
    if (inv.status !== 0) throw new Error('INV-0143 should still be Issued');
  }

  log.finishedAt = new Date().toISOString();
  log.result = 'DEMO FLOW COMPLETE';
  fs.writeFileSync(DEMO_LOG, JSON.stringify(log, null, 2));
  console.log('\nDEMO FLOW COMPLETE — log written to', DEMO_LOG);
}

// ------------------------------------------------------------- poll (run)
async function pollOnce(mandateId) {
  const m = await read(MAND, 'getMandate', [mandateId]);
  const now = Math.floor(Date.now() / 1000);
  if (m.revoked) { console.log(`[${new Date().toISOString()}] mandate #${mandateId} REVOKED — nothing to do`); return; }
  if (now >= Number(m.expiry)) { console.log(`[${new Date().toISOString()}] mandate #${mandateId} EXPIRED — nothing to do`); return; }
  const remaining = m.totalBudget - m.spent;
  const count = await read(BOOK, 'invoiceCount');
  for (let id = 1n; id <= count; id++) {
    const inv = await read(BOOK, 'getInvoice', [id]);
    if (inv.payer !== m.owner || inv.status !== 0) continue;
    if (inv.dueDate !== 0n && Number(inv.dueDate) > now) continue; // not due yet
    const tag = `invoice #${id} (${inv.invoiceRef}, ${fmt(inv.amount)})`;
    if (!(await read(REG, 'isVerified', [inv.payeeId]))) { console.log(`HOLD ${tag}: payee #${inv.payeeId} not verified (CoP)`); continue; }
    if (inv.amount > m.perPaymentCap) { console.log(`HOLD ${tag}: over per-payment cap ${fmt(m.perPaymentCap)}`); continue; }
    if (inv.amount > remaining) { console.log(`HOLD ${tag}: exceeds remaining mandate budget ${fmt(remaining)}`); continue; }
    try {
      await retry('simulate payInvoice', () => pub.simulateContract({ ...MAND, functionName: 'payInvoice', args: [mandateId, id], account: accounts.agent }));
    } catch (e) { console.log(`HOLD ${tag}: simulation reverts — ${(e.shortMessage || '').slice(0, 140)}`); continue; }
    const r = await send('agent', MAND, 'payInvoice', [mandateId, id]);
    console.log(`PAID ${tag} tx=${r.hash} ${txLink(r.hash)} status=${r.receipt.status}`);
  }
}

async function run(once) {
  const mandateId = BigInt(process.env.MANDATE_ID || dep.mandateId || 0);
  if (!mandateId) throw new Error('no mandateId (set dep.mandateId in deployments file or MANDATE_ID env)');
  console.log(`agent runner polling every ${POLL_SECONDS}s for mandate #${mandateId} (agent ${accounts.agent.address})`);
  for (;;) {
    try { await pollOnce(mandateId); } catch (e) { console.log('poll error:', (e.shortMessage || e.message || '').slice(0, 200)); }
    if (once) break;
    await sleep(POLL_SECONDS);
  }
}

// ------------------------------------------------------------------ main
const mode = process.argv[2] || 'status';
try {
  if (mode === 'status') await status();
  else if (mode === 'demo') await demo();
  else if (mode === 'run') await run(process.argv.includes('--once'));
  else { console.error(`unknown mode "${mode}" — use status | demo | run`); process.exit(2); }
} catch (e) {
  console.error('FATAL:', (e.shortMessage || e.message || String(e)).slice(0, 500));
  process.exit(1);
}
