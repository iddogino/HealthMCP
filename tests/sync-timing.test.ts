import test from 'node:test';
import assert from 'node:assert/strict';
import {measureBindings} from '../apps/worker/src/timing';
import {upload,resetCache} from '../apps/worker/src/storage';
import {fixture,envelope,request} from './helpers/worker-fixture';

test('opt-in binding timings preserve upload, replacement and cleanup behavior without identifying data',async()=>{
  const f=fixture(),timed=measureBindings(f.env),user=f.user();
  await upload(request(),timed.env,user,envelope());
  await upload(request(),timed.env,user,envelope(2));
  assert.equal(f.objects.size,1);
  assert.equal([...f.objects.values()][0],envelope(2));
  await resetCache(timed.env,user,true);
  assert.equal(f.objects.size,0);
  assert.match(timed.header(),/^d1;dur=[\d.]+, r2;dur=[\d.]+, d1_calls;dur=\d+\.00, r2_calls;dur=\d+\.00$/);
});
