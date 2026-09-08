import {test} from 'node:test';
import assert from 'node:assert/strict';
import {checksum,normalizeKey,formatKey,objectPath,validatePeriod,validDay,validateEnvelope} from '../packages/protocol/index';
test('Crockford checksum and normalization preserve all 80 random bits',()=>{
  const payload='0123456789ABCDEF',key=payload+checksum(payload);
  assert.equal(normalizeKey('  '+formatKey(key).toLowerCase()+'\n'),key);
  assert.throws(()=>normalizeKey(key.slice(0,-1)+(key.at(-1)==='0'?'1':'0')));
  assert.throws(()=>normalizeKey('O123456789ABCDEFG'));
});
test('Only valid UTC dates and whitelisted period layouts are accepted',()=>{
  assert.equal(validDay('2024-02-29'),true);assert.equal(validDay('2026-02-29'),false);
  assert.equal(validatePeriod('steps','2026-09-01'),true);assert.equal(validatePeriod('body_mass','2026-09'),true);
  assert.equal(validatePeriod('steps','../profile'),false);assert.equal(validatePeriod('body_mass','2026-13'),false);
  assert.equal(objectPath('u_00000000-0000-4000-8000-000000000001','check','single'),'u_00000000-0000-4000-8000-000000000001/check');
});
test('Envelopes reject plaintext, unknown fields, truncated tags, and malformed base64',()=>{
  const envelope={v:1,alg:'A256GCM',kdf:'sha256',iv:'AAAAAAAAAAAAAAAA',ct:'AAAAAAAAAAAAAAAAAAAAAAAA'};
  assert.equal(validateEnvelope(envelope),true);assert.equal(validateEnvelope({...envelope,v:2}),false);
  assert.equal(validateEnvelope({...envelope,value:812}),false);assert.equal(validateEnvelope({...envelope,ct:'AA=='}),false);
});

test('new 130-bit keys and legacy keys normalize without changing their payload',()=>{
  for(const payload of ['0123456789ABCDEF','0123456789ABCDEFGHJKMNPQRS']) {
    const key=payload+checksum(payload);assert.equal(normalizeKey(formatKey(key).toLowerCase()),key);
    assert.throws(()=>normalizeKey(key.slice(0,-1)+(key.at(-1)==='0'?'1':'0')));
  }
});
