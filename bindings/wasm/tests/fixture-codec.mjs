// JSON form of the values native zova-js and zova-wasm exchange, shared by
// tools/generate-graph-fixture.mjs and the browser tests. Fields ending in
// "Ms" are timings and are left out, so recorded results compare exactly.
const typed = [
  ["$i64", BigInt64Array, BigInt], ["$u64", BigUint64Array, BigInt],
  ["$bytes", Uint8Array, Number], ["$i8", Int8Array, Number], ["$f32", Float32Array, Number],
];

export function encode(value) {
  if (typeof value === "bigint") return { $bigint: String(value) };
  for (const [tag, type] of typed) {
    if (value instanceof type) return { [tag]: Array.from(value, item => typeof item === "bigint" ? String(item) : item) };
  }
  if (Array.isArray(value)) return value.map(encode);
  if (value && typeof value === "object") {
    const out = {};
    for (const [key, item] of Object.entries(value)) if (!key.endsWith("Ms") && item !== undefined) out[key] = encode(item);
    return out;
  }
  return value;
}

export function decode(value) {
  if (Array.isArray(value)) return value.map(decode);
  if (!value || typeof value !== "object") return value;
  if ("$bigint" in value) return BigInt(value.$bigint);
  for (const [tag, type, item] of typed) if (tag in value) return type.from(value[tag], item);
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, decode(item)]));
}
