// Модель понимания в onnxruntime-web (WASM, как в веб-помощнике склада):
// открывается, считает векторы для тех же входов, что и onnxruntime на CPU.
// node check.mjs <model.int8.onnx> <feeds.json> <out.json>
// feeds.json: {"inputs": {"input_ids": [[…]], …}, "dims": [batch, seq]}
// Заодно — сколько открывается модель, мс на фразу (по одной, без
// дополнения, 1 поток, как в помощнике) и память процесса (RSS).
import { readFileSync, writeFileSync } from 'node:fs';
import * as ort from 'onnxruntime-web';

const [modelPath, feedsPath, outPath] = process.argv.slice(2);
ort.env.wasm.numThreads = 1;
const mb = (x) => Math.round(x / 1e5) / 10;
const rss0 = process.memoryUsage().rss;
const bytes = readFileSync(modelPath);
const t0 = performance.now();
const session = await ort.InferenceSession.create(bytes, {
  executionProviders: ['wasm'],
});
const loadMs = performance.now() - t0;
const { inputs, dims } = JSON.parse(readFileSync(feedsPath, 'utf8'));
const feeds = {};
for (const [name, rows] of Object.entries(inputs)) {
  feeds[name] = new ort.Tensor('int64', BigInt64Array.from(rows.flat().map(BigInt)), dims);
}
const out = await session.run(feeds);
const emb = out[session.outputNames[0]];

// По одной фразе: длина — по маске, как кодировщик помощника.
const times = [];
for (let round = 0; round < 3; round++) {
  for (let r = 0; r < dims[0]; r++) {
    const len = inputs.attention_mask[r].reduce((a, b) => a + b, 0);
    const one = {};
    for (const [name, rows] of Object.entries(inputs)) {
      one[name] = new ort.Tensor('int64', BigInt64Array.from(rows[r].slice(0, len).map(BigInt)), [1, len]);
    }
    const t = performance.now();
    await session.run(one);
    if (round > 0) times.push(performance.now() - t);
  }
}
times.sort((a, b) => a - b);
const q = (p) => Math.round(times[Math.min(times.length - 1, Math.floor(p * times.length))] * 10) / 10;
const perf = {
  load_ms: Math.round(loadMs),
  ms_per_phrase: { median: q(0.5), p90: q(0.9) },
  rss_mb: { before: mb(rss0), after: mb(process.memoryUsage().rss) },
};
writeFileSync(outPath, JSON.stringify({ dims: emb.dims, data: Array.from(emb.data), perf }));
console.log(`onnxruntime-web ${ort.env.versions?.web ?? ''}: ${emb.dims.join('×')}`);
