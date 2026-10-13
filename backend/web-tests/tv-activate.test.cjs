const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const page = fs.readFileSync(path.join(__dirname, '../handlers/assets/tv-activate.html'), 'utf8');
const script = page.split('<script>')[1].split('</script>')[0];
const token = 'a'.repeat(48);
const flush = async () => { for (let i = 0; i < 5; i++) await new Promise(setImmediate); };
function screen({ hash = '', search = '', pathname = '/tv/activate', fetch } = {}) {
 const elements = {};
 for (const [tag, id] of page.matchAll(/<[^>]+\bid="([^"]+)"[^>]*>/g)) {
  elements[id] = { value: '', hidden: /\bhidden(?:\s|>)/.test(tag), disabled: false, textContent: '', listeners: {}, addEventListener(name, handler) { this.listeners[name] = handler; } };
 }
 const navigation = [];
 vm.runInNewContext(script, { document: { getElementById: id => elements[id] }, window: { location: { hash, search, pathname }, history: { replaceState(...args) { navigation.push(args[2]); } } }, URLSearchParams, fetch, Date, Error });
 return { elements, navigation, async submit() { await elements['login-form'].listeners.submit({ preventDefault() {} }); }, async click(id) { await elements[id].listeners.click(); } };
}
function service({ expired = false, rejectedCode = false } = {}) {
 let approved = false, declined = false;
 const requests = [];
 return { requests, get approved() { return approved; }, get declined() { return declined; }, async fetch(url, options) {
  requests.push({ url, options });
  let status = 200, body = {};
  if (url.includes('/auth/tv/session')) {
   if (expired) { status = 410; body = { error: 'expired' }; }
   else body = { user_code: '123456', expires_at: '2030-01-01T12:10:00Z', device_name: 'StreamPilot TV', status: approved ? 'approved' : declined ? 'declined' : 'pending' };
  } else if (url.endsWith('/auth/tv/lookup')) { status = rejectedCode ? 404 : 200; body = rejectedCode ? { error: 'code not found' } : { pairing_token: token }; }
  else if (url.endsWith('/auth/login')) body = { token: 'independent-phone-token', email: 'viewer@example.test' };
  else if (url.endsWith('/auth/tv/approve-session')) { approved = true; body = { status: 'approved' }; }
  else if (url.endsWith('/auth/tv/decline-session')) { declined = true; body = { status: 'declined' }; }
  else if (url.endsWith('/auth/tv/approve')) { approved = true; body = { message: 'approved' }; }
  else throw new Error('Unexpected API endpoint');
  return { ok: status >= 200 && status < 300, status, async json() { return body; } };
 } };
}
function signIn(view) { view.elements.email.value = 'viewer@example.test'; view.elements.password.value = 'synthetic-password'; }

test('scan shows matching code and requires a distinct explicit approval after sign-in', async () => {
 const api = service(), view = screen({ hash: '#pairing_token=' + token, fetch: api.fetch });
 await flush();
 assert.equal(view.elements['matching-code'].textContent, '123456');
 assert.equal(view.elements['open-app'].href, 'streampilot://tv/activate?pairing_token=' + token);
 signIn(view); await view.submit();
 assert.equal(view.elements.confirmation.hidden, false);
 assert.match(view.elements.account.textContent, /viewer@example.test/);
 assert.equal(view.elements.password.value, '');
 assert.equal(api.approved, false);
 await view.click('approve');
 assert.equal(api.approved, true);
 assert.match(view.elements.message.textContent, /TV approved/);
 assert.equal(view.elements.confirmation.hidden, true);
});

test('manual code finds the pending session before sign-in and supports decline', async () => {
 const api = service(), view = screen({ fetch: api.fetch });
 view.elements['user-code'].value = '123456'; signIn(view); await view.submit();
 assert.equal(view.elements['matching-code'].textContent, '123456');
 assert.equal(api.declined, false);
 await view.click('decline');
 assert.equal(api.declined, true);
 assert.equal(api.approved, false);
 assert.match(view.elements.message.textContent, /declined/);
});

test('expired scanned request hides account actions and directs user to rescan', async () => {
 const api = service({ expired: true }), view = screen({ hash: '#pairing_token=' + token, fetch: api.fetch });
 await flush();
 assert.equal(view.elements['login-form'].hidden, true);
 assert.equal(view.elements.confirmation.hidden, true);
 assert.match(view.elements.message.textContent, /Generate a new QR code/);
});

test('malformed links and api_base query cannot choose an API origin', async () => {
 const api = service(), bad = screen({ hash: '#pairing_token=https%3A%2F%2Fevil.example', fetch: api.fetch });
 await flush();
 assert.match(bad.elements.message.textContent, /Invalid QR link/);
 assert.equal(api.requests.length, 0);
 const view = screen({ hash: '#pairing_token=' + token, search: '?api_base=https://evil.example', fetch: api.fetch });
 await flush(); signIn(view); await view.submit();
 assert.ok(api.requests.every(request => request.url.startsWith('/api/v1/')));
 assert.deepEqual(view.navigation, ['/tv/activate']);
});

test('older TV QR links keep password and matching-code approval compatibility', async () => {
 const api = service(), view = screen({ pathname: '/tv-login.html', search: '?device_code=legacy-poll-secret&api_base=https://evil.example', fetch: api.fetch });
 view.elements['user-code'].value = '123456'; signIn(view); await view.submit();
 assert.equal(api.approved, false);
 assert.equal(view.elements.decline.hidden, true);
 await view.click('approve');
 assert.equal(api.approved, true);
 assert.ok(api.requests.every(request => request.url.startsWith('https://iptv.florian-zug.de/api/v1/')));
});

test('mistyped manual code allows another attempt', async () => {
 const api = service({ rejectedCode: true }), view = screen({ fetch: api.fetch });
 view.elements['user-code'].value = '123456'; signIn(view); await view.submit();
 assert.equal(view.elements['login-form'].hidden, false);
 assert.equal(view.elements['sign-in'].disabled, false);
 assert.match(view.elements.message.textContent, /code not found/i);
});

if (process.env.STREAMPILOT_TEST_ORIGIN) test('browser page signs in and approves against real local SQLite service', async () => {
 const origin = process.env.STREAMPILOT_TEST_ORIGIN;
 const start = await fetch(origin + '/api/v1/auth/tv/start', { method: 'POST' }).then(r => r.json());
 const view = screen({ hash: '#pairing_token=' + start.pairing_token, fetch: (url, options) => fetch(origin + url, options) });
 for (let attempt = 0; view.elements['sign-in'].disabled && attempt < 500; attempt++) await new Promise(resolve => setTimeout(resolve, 10));
 assert.equal(view.elements['sign-in'].disabled, false, 'session load completes');
 signIn(view); await view.submit();
 assert.equal(view.elements['matching-code'].textContent, start.user_code);
 assert.equal(view.elements.confirmation.hidden, false);
 const pending = await fetch(origin + '/api/v1/auth/tv/poll?device_code=' + start.device_code).then(r => r.json());
 assert.equal(pending.status, 'pending');
 await view.click('approve');
 assert.match(view.elements.message.textContent, /TV approved/);
 const approved = await fetch(origin + '/api/v1/auth/tv/poll?device_code=' + start.device_code).then(r => r.json());
 assert.equal(approved.status, 'approved');
 assert.equal(typeof approved.auth.token, 'string');
 const repeat = await fetch(origin + '/api/v1/auth/tv/poll?device_code=' + start.device_code);
 assert.equal(repeat.status, 410);
});
