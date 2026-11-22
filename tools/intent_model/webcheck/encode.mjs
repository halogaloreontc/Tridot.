// Векторы фраз в onnxruntime-web (WASM, 1 поток — как в веб-помощнике):
// для уровней, у которых WASM считает не совсем как CPU (web-accurate),
// индекс и пробы считаются здесь же, чтобы порог был порогом браузера.
// node encode.mjs <model.int8.onnx> <batches.json> <out.json>
// batches.json: [{"inputs": {"input_ids": [[…]], …}, "dims": [batch, seq]}, …]
import { readFileSync, writeFileSync } from 'node:fs';
import * as ort from 'onnxruntime-web';

const [modelPath, batchesPath, outPath] = process.argv.slice(2);
ort.env.wasm.numThreads = 1;
const session = await ort.InferenceSession.create(readFileSync(modelPath), {
  executionProviders: ['wasm'],
});
const rows = [];
let dims = 0;
for (const { inputs, dims: shape } of JSON.parse(readFileSync(batchesPath, 'utf8'))) {
  const feeds = {};
  for (const [name, r] of Object.entries(inputs)) {
    feeds[name] = new ort.Tensor('int64', BigInt64Array.from(r.flat().map(BigInt)), shape);
  }
  const emb = (await session.run(feeds))[session.outputNames[0]];
  dims = emb.dims[1];
  for (let i = 0; i < emb.dims[0]; i++) rows.push(Array.from(emb.data.subarray(i * dims, (i + 1) * dims)));
}
writeFileSync(outPath, JSON.stringify({ dims: [rows.length, dims], data: rows.flat() }));
