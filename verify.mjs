// Browser-compatible module and byte-for-byte kernel oracle. Run from repo root:
// node verify.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import assert from 'node:assert/strict';

const FRACTION_BITS = 256n;
const UNIT = 1n << FRACTION_BITS;
const deep = {
  cx: '-0.743643887037160450261172221074774',
  cy: '0.131825904205320730134092697485139',
  scale: 1e-30, w: 128, h: 96, iter: 5000,
};

function fixed(decimal) {
  const negative = decimal.startsWith('-');
  const [whole, fraction = ''] = decimal.replace(/^[+-]/, '').split('.');
  const value = BigInt(whole + fraction) * UNIT / (10n ** BigInt(fraction.length));
  return negative ? -value : value;
}

function referenceOrbit(cx, cy, limit) {
  const cr = fixed(cx), ci = fixed(cy);
  const bytes = Buffer.alloc((limit + 1) * 16);
  let zr = 0n, zi = 0n, n = 0;
  for (; n <= limit; n++) {
    bytes.writeDoubleLE(Number(zr) / Number(UNIT), n * 16);
    bytes.writeDoubleLE(Number(zi) / Number(UNIT), n * 16 + 8);
    if (zr * zr + zi * zi > 4n * UNIT * UNIT || n === limit) break;
    const next = (zr * zr - zi * zi) / UNIT + cr;
    zi = 2n * zr * zi / UNIT + ci;
    zr = next;
  }
  return bytes.subarray(0, (n + 1) * 16);
}

function pixels(e, w, h) {
  return Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), w * h * 4));
}

function upload(e, orbit) {
  assert.ok(orbit.length / 16 <= e.orbit_cap());
  new Uint8Array(e.memory.buffer, e.orbit_ptr(), orbit.length).set(orbit);
  assert.equal(e.set_ref(orbit.length / 16), 0);
}

function distinctColours(frame) {
  const colours = new Set();
  for (let i = 0; i < frame.length; i += 4) colours.add(frame.readUInt32LE(i));
  return colours.size;
}

const shallowOrbit = referenceOrbit('-0.5', '0', 256);
const deepOrbit = referenceOrbit(deep.cx, deep.cy, deep.iter);
const fixture = new URL('./fixtures/seahorse-1e30.orbit', import.meta.url);
if (process.argv.includes('--write-orbit')) {
  mkdirSync(new URL('./fixtures/', import.meta.url), { recursive: true });
  writeFileSync(fixture, deepOrbit);
  console.log(`Wrote fixtures/seahorse-1e30.orbit: ${deepOrbit.length / 16} entries, ${deepOrbit.length} bytes, ${FRACTION_BITS} fractional bits`);
} else {
  assert.deepEqual(readFileSync(fixture), deepOrbit, 'deep fixture differs from the BigInt recipe');
}

let reference;
let perturbReference;
for (const artifact of ['kernel', 'kernel_simd']) {
  const module = await WebAssembly.compile(readFileSync(new URL(`./${artifact}.wasm`, import.meta.url)));
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  const { exports: e } = await WebAssembly.instantiate(module);
  assert.equal(e.fb_cap(), 1048576);
  const checks = [];
  for (const args of [[-.5, 0, 3.5 / 512, 512, 512, 256],
                      [-.743643887037151, .13182590420533, 1e-6, 128, 128, 2000],
                      [-.5, 0, .1, 31, 29, 80], [0, 0, .01, 1024, 1024, 1],
                      [0, 0, 0, 1, 1, 7], [2, 0, 0, 1, 1, 7]]) {
    const [cx, cy, scale, w, h, limit] = args;
    assert.equal(e.set_view(cx, cy, scale), 0);
    const total = e.render(w, h, limit);
    const scalar = Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), w * h * 4));
    assert.equal(e.render_simd(w, h, limit), total);
    assert.deepEqual(Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), w * h * 4)), scalar);
    for (let i = 3; i < scalar.length; i += 4) assert.equal(scalar[i], 255);
    if (cx === 0 && cy === 0 && scale === 0) {
      assert.equal(total, 7n);
      assert.deepEqual(scalar, Buffer.from([0, 0, 0, 255]));
    }
    if (cx === 2 && scale === 0) assert.equal(total, 2n);
    checks.push([total, scalar]);
  }
  const before = Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), 16));
  for (const fn of [e.render, e.render_simd]) {
    for (const args of [[0, 0, 1, 0, 1, 1], [0, 0, 1, 1025, 1024, 1], [NaN, 0, 1, 1, 1, 1]]) {
      const [cx, cy, scale, w, h, limit] = args;
      assert.equal(e.set_view(cx, cy, scale), Number.isFinite(cx) ? 0 : -1);
      assert.equal(fn(w, h, limit), -1n);
      assert.deepEqual(Buffer.from(new Uint8Array(e.memory.buffer, e.fb_ptr(), 16)), before);
    }
  }
  if (reference) assert.deepEqual(checks, reference);
  else reference = checks;
  console.log(`PASS ${artifact}: zero imports, scalar/vector parity, alpha, odd tail, invalid input, known points`);

  assert.equal(e.orbit_cap(), 65536);
  assert.equal(e.orbit_ptr() % 8, 0);
  assert.ok(e.orbit_ptr() + e.orbit_cap() * 16 <= e.memory.buffer.byteLength);
  assert.ok(e.orbit_ptr() + e.orbit_cap() * 16 <= e.fb_ptr() ||
            e.fb_ptr() + e.fb_cap() * 4 <= e.orbit_ptr());
  assert.equal(e.render_perturb(1, 1, 1), -1n);
  for (const n of [-1, 0, 65537]) assert.equal(e.set_ref(n), -1);
  assert.equal(e.set_ref(65536), 0);
  assert.equal(e.set_ref(1), 0);
  assert.equal(e.render_perturb(1, 1, 1), -1n);

  upload(e, shallowOrbit);
  assert.equal(e.set_view(-0.5, 0, 0.01), 0);
  e.render(128, 96, 256);
  const directShallow = pixels(e, 128, 96);
  assert.equal(e.set_delta(0, 0, 0.01), 0);
  const shallowTotal = e.render_perturb(128, 96, 256);
  const shallow = pixels(e, 128, 96);
  let equal = 0;
  for (let i = 0; i < shallow.length; i += 4) {
    if (shallow.readUInt32LE(i) === directShallow.readUInt32LE(i)) equal++;
  }
  const percentage = 100 * equal / (128 * 96);
  assert.ok(percentage >= 99, `shallow agreement ${percentage}% < 99%`);
  console.log(`PASS ${artifact}: shallow agreement ${equal}/12288 pixels (${percentage.toFixed(9)}%)`);

  const perturbChecks = [[shallowTotal, shallow]];
  for (const [orbit, dcx, dcy, scale, w, h, iter] of [
    [shallowOrbit, 0.025, -0.0125, 0.02, 31, 29, 256],
    [shallowOrbit.subarray(0, 3 * 16), 0.1, 0, 0.02, 31, 29, 256],
    [referenceOrbit('0', '0', 1), 2, 0, 0, 1, 1, 7],
  ]) {
    upload(e, orbit);
    assert.equal(e.set_delta(dcx, dcy, scale), 0);
    const total = e.render_perturb(w, h, iter);
    const frame = pixels(e, w, h);
    if (dcx === 2) assert.equal(total, 2n);
    for (let i = 3; i < frame.length; i += 4) assert.equal(frame[i], 255);
    perturbChecks.push([total, frame]);
  }

  upload(e, deepOrbit);
  assert.equal(e.set_view(Number(deep.cx), Number(deep.cy), deep.scale), 0);
  const directTotal = e.render(deep.w, deep.h, deep.iter);
  const directDeep = pixels(e, deep.w, deep.h);
  assert.equal(e.set_delta(0, 0, deep.scale), 0);
  const deepTotal = e.render_perturb(deep.w, deep.h, deep.iter);
  const deepFrame = pixels(e, deep.w, deep.h);
  const plainColours = distinctColours(directDeep);
  const perturbColours = distinctColours(deepFrame);
  assert.equal(plainColours, 1, 'plain f64 deep image must collapse');
  assert.ok(perturbColours > 50, `deep image has only ${perturbColours} colours`);
  console.log(`PASS ${artifact}: deep scale ${deep.scale}, plain colours ${plainColours}, perturb colours ${perturbColours}, iterations ${deepTotal} (plain ${directTotal})`);
  perturbChecks.push([deepTotal, deepFrame]);

  const guard = pixels(e, 4, 1);
  for (const args of [[0, 1, 1], [-1, 1, 1], [1025, 1024, 1], [1, 1, 0]]) {
    assert.equal(e.render_perturb(...args), -1n);
    assert.deepEqual(pixels(e, 4, 1), guard);
  }
  for (const args of [[NaN, 0, 1], [0, Infinity, 1], [0, 0, -Infinity]]) {
    assert.equal(e.set_delta(...args), -1);
    assert.equal(e.render_perturb(1, 1, 1), -1n);
    assert.deepEqual(pixels(e, 4, 1), guard);
  }
  if (perturbReference) assert.deepEqual(perturbChecks, perturbReference);
  else perturbReference = perturbChecks;
  console.log(`PASS ${artifact}: perturb ABI, delta offsets, short-orbit rebasing, invalid input, artifact parity`);
}
