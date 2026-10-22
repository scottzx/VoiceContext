import assert from 'node:assert/strict';
import { apply } from './dsh_tailnet_trust.mjs';

const authority = 'example.tail123.ts.net:8451';
const trustedHosts = ['127.0.0.1:3080'];
const ctx = { connection: { trustedHosts }, effect: fn => fn() };
const dispose = apply(ctx, { authority });
assert.deepEqual(trustedHosts, ['127.0.0.1:3080', authority]);
assert.deepEqual(ctx.connection, { trustedHosts }, 'Do not replace authentication or other carrier state');
dispose();
assert.deepEqual(trustedHosts, ['127.0.0.1:3080']);
trustedHosts.push(authority);
apply(ctx, { authority })();
assert.ok(trustedHosts.includes(authority), 'Do not remove a pre-existing trust grant');
for (const value of ['example.com:8451', '*.ts.net', 'x.ts.net/path', 'x.ts.net?q=1', 'user@x.ts.net', 'x.ts.net:abc']) {
  assert.throws(() => apply(ctx, { authority: value }));
}
console.log('PASS: exact Tailnet authority, lifecycle cleanup, pre-existing trust preservation');
