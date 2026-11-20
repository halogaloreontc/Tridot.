// Модель понимания в onnxruntime-web (WASM, как в веб-помощнике склада):
// открывается, считает векторы для тех же входов, что и onnxruntime на CPU.
// node check.mjs <model.int8.onnx> <feeds.json> <out.json>
// feeds.json: {"inputs": {"input_ids": [[…]], …}, "dims": [batch, seq]}
import { readFileSync, writeFileSync } from 'node:fs';
import * as ort from 'onnxruntime-web';

const [modelPath, feedsPath, outPath] = process.argv.slice(2);
ort.env.wasm.numThreads = 1;
const session = await ort.InferenceSession.create(readFileSync(modelPath), {
  executionProviders: ['wasm'],
});
const { inputs, dims } = JSON.parse(readFileSync(feedsPath, 'utf8'));
const feeds = {};
for (const [name, rows] of Object.entries(inputs)) {
  feeds[name] = new ort.Tensor('int64', BigInt64Array.from(rows.flat().map(BigInt)), dims);
}
const out = await session.run(feeds);
const emb = out[session.outputNames[0]];
writeFileSync(outPath, JSON.stringify({ dims: emb.dims, data: Array.from(emb.data) }));
console.log(`onnxruntime-web ${ort.env.versions?.web ?? ''}: ${emb.dims.join('×')}`);
