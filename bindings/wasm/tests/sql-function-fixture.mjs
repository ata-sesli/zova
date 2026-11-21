// SQL functions for the browser package test; the database worker imports
// this module and calls its exports synchronously.
const describe = value => value === null ? "null" : value instanceof Uint8Array ? "blob:" + [...value].join(" ")
  : typeof value + ":" + String(value);
export const echo = (...args) => args[0];
export const types = (...args) => args.map(describe).join(",");
export const plus = (a, b) => a + b;
export const flag = () => true;
export const half = a => Number(a) / 2;
export const emptyValue = () => undefined;
export const boom = () => { throw new RangeError("no luck"); };
export const weird = () => ({});
export const huge = () => 1n << 70n;
export const notAFunction = 1;
