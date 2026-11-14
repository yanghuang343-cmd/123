import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { inspect } from './policy.mjs';

function parseArgs(argv) {
  const args = { input: 'data/candidates.json', output: 'data/tiktok-ready.json' };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--input' || token === '--output') {
      const value = argv[++i];
      if (!value) throw new Error(`Missing value after ${token}`);
      args[token === '--input' ? 'input' : 'output'] = value;
    } else {
      throw new Error(`Unknown argument: ${token}`);
    }
  }
  return args;
}

async function readJson(filename) {
  return JSON.parse(await fs.readFile(filename, 'utf8'));
}

const args = parseArgs(process.argv.slice(2));
const inputPath = path.resolve(args.input);
const outputPath = path.resolve(args.output);
const candidates = await readJson(inputPath);
if (!Array.isArray(candidates)) throw new Error('Input must be a JSON array of product candidates');
const configPath = path.resolve('config/tiktok-jp.json');
const config = await fs.stat(configPath).then(() => readJson(configPath)).catch(() => ({}));
const results = await Promise.all(candidates.map((candidate, index) => inspect(candidate, index, inputPath, config.requiredAttributes ?? [])));
const ready = results.filter((result) => result.status === 'READY').map((result) => ({ ...result.candidate, preflightStatus: result.status }));
const reportPath = path.resolve('runs/preflight-report.json');
await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.mkdir(path.dirname(reportPath), { recursive: true });
await fs.writeFile(outputPath, `${JSON.stringify(ready, null, 2)}\n`, 'utf8');
await fs.writeFile(reportPath, `${JSON.stringify(results.map(({ candidate: _candidate, ...report }) => report), null, 2)}\n`, 'utf8');

const counts = Object.fromEntries(['READY', 'REVIEW', 'BLOCKED'].map((status) => [status, results.filter((result) => result.status === status).length]));
console.log(`Preflight: ${counts.READY} READY, ${counts.REVIEW} REVIEW, ${counts.BLOCKED} BLOCKED`);
console.log(`TikTok-ready file: ${outputPath}`);
console.log(`Review report: ${reportPath}`);
