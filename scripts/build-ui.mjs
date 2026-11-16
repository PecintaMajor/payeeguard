#!/usr/bin/env node
/**
 * Builds ui/index.html from ui/index.template.html:
 *  - injects the compiled ABIs (agent/abis.json, produced from the Foundry artifacts)
 *  - patches the CONFIG addresses block from deployments.json when present
 *    (falls back to deployments.local.json, then to blank/testnet defaults)
 * Usage: node scripts/build-ui.mjs [path-to-deployments.json]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const tpl = fs.readFileSync(path.join(ROOT, 'ui', 'index.template.html'), 'utf8');
const abis = fs.readFileSync(path.join(ROOT, 'agent', 'abis.json'), 'utf8');

let depFile = process.argv[2];
if (!depFile) {
  for (const cand of ['deployments.json', 'deployments.local.json']) {
    if (fs.existsSync(path.join(ROOT, cand))) { depFile = path.join(ROOT, cand); break; }
  }
}

let html = tpl.replace('/*__ABIS__*/{}', `/*__ABIS__*/${abis.trim()}`);

if (depFile) {
  const d = JSON.parse(fs.readFileSync(depFile, 'utf8'));
  const block = `addresses: { payeeRegistry: "${d.payeeRegistry}", invoiceBook: "${d.invoiceBook}", agentMandate: "${d.agentMandate}", tUsd8: "${d.tUsd8}" },`;
  html = html.replace(/addresses: \{[^}]*\},/, block);
  if (d.deployBlock) html = html.replace('deployBlock: 0,', `deployBlock: ${d.deployBlock},`);
  console.log(`addresses wired from ${depFile}`);
} else {
  console.log('no deployments file found — CONFIG addresses left blank (UI auto-loads deployments.json at runtime)');
}

fs.writeFileSync(path.join(ROOT, 'ui', 'index.html'), html);
console.log('ui/index.html written,', html.length, 'bytes');
