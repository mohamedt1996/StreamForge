// Run with: node Tests/TrailerBridgeTests.cjs
// Exercises the iOS trailer bridge (TrailerBackdrop.swift) that runs inside YouTube's embed page.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const swift = fs.readFileSync(path.join(__dirname, '../Sources/Shared/Features/Detail/TrailerBackdrop.swift'), 'utf8');

// YouTube's documented app identity: the embed page is loaded directly with the app id as Referer.
assert.ok(swift.includes('forHTTPHeaderField: "Referer"'), 'embed request must carry the app Referer');
assert.ok(swift.includes('https://www.youtube-nocookie.com/embed/'), 'trailers load the YouTube embed page');

const template = swift.split('static func bridgeScript(')[1].split('return """')[1].split('"""')[0];
function fixture({ active, muted = true, errorVisible = false }) {
  const messages = [], observers = [];
  const listeners = {};
  const video = {
    muted: false, plays: 0, pauses: 0, currentTime: 0, duration: 120, playsInline: false,
    play() { this.plays++; return Promise.resolve(); }, pause() { this.pauses++; },
    setAttribute() {}, addEventListener(name, cb) { listeners[name] = cb; },
  };
  let videos = [];
  const error = errorVisible ? { offsetWidth: 300, offsetHeight: 100 } : { offsetWidth: 0, offsetHeight: 0 };
  const window = { webkit: { messageHandlers: { trailer: { postMessage: m => messages.push(m) } } } };
  const document = {
    documentElement: {},
    querySelectorAll: () => videos,
    querySelector: sel => (sel === '.ytp-error' ? error : null),
  };
  const code = template
    .replaceAll('\\(active ? "true" : "false")', String(active))
    .replaceAll('\\(muted ? "true" : "false")', String(muted));
  const ctx = { window, document, WeakSet, MutationObserver: class { constructor(cb) { observers.push(cb); } observe() {} } };
  vm.runInNewContext(code, ctx);
  const addVideo = () => { videos = [video]; observers.forEach(cb => cb()); };
  return { messages, video, listeners, window, addVideo };
}

// The player's <video> appears later (YouTube builds it): it is picked up and started muted.
const on = fixture({ active: true });
assert.deepEqual(on.messages, []);
on.addVideo();
assert.equal(on.video.plays, 1);
assert.equal(on.video.muted, true);
on.listeners.playing();
assert.deepEqual(on.messages, ['playing']);
on.listeners.playing();
assert.deepEqual(on.messages, ['playing'], 'playing is reported once');
on.window.sfMute(false);
assert.equal(on.video.muted, false);
// Fades out just before the end, so YouTube's end screen never shows.
on.video.currentTime = 119.5; on.listeners.timeupdate();
assert.equal(on.messages.at(-1), 'ended');
on.window.sfReplay();
assert.equal(on.video.currentTime, 0);

// Inactive (scrolled away / covered): never starts, and a late "playing" is paused again.
const off = fixture({ active: false });
off.addVideo();
assert.equal(off.video.plays, 0);
off.listeners.playing();
assert.ok(off.video.pauses >= 1);
assert.deepEqual(off.messages, []);
off.window.sfPlay();
assert.ok(off.video.plays >= 1);

// YouTube's visible error screen (unavailable / embedding disabled) -> next id.
const bad = fixture({ active: true, errorVisible: true });
bad.addVideo();
assert.deepEqual(bad.messages, ['failed']);
// A hidden error container (always in the DOM) does not count.
const fine = fixture({ active: true, errorVisible: false });
fine.addVideo();
assert.deepEqual(fine.messages, []);
// Media error before playback -> failed; after playback started it is ignored.
const media = fixture({ active: true });
media.addVideo();
media.listeners.error();
assert.deepEqual(media.messages, ['failed']);

console.log('YouTube trailer bridge checks passed.');

// IMDb backup (unchanged from earlier builds): drives the IMDb embed page's media elements.
{
const template = swift.split('static func imdbScript(')[1].split('return """')[1].split('"""')[0];
function fixture(active) {
  const events = {}, messages = [], children = [];
  const video = { muted: false, plays: 0, pauses: 0, currentTime: 9,
    play() { this.plays++; return Promise.resolve(); }, pause() { this.pauses++; },
    addEventListener(name, cb) { events[name] = cb; } };
  const listeners = {};
  const window = { frames: [{ postMessage: msg => children.push(msg) }],
    webkit: { messageHandlers: { trailer: { postMessage: msg => messages.push(msg) } } },
    addEventListener: (name, cb) => { listeners[name] = cb; } };
  window.parent = {};
  const document = { querySelectorAll: () => [video], addEventListener() {} };
  const code = template.replaceAll('\\(token)', 'test-token')
    .replaceAll('\\(active ? "true" : "false")', String(active))
    .replaceAll('\\(muted ? "true" : "false")', 'true');
  vm.runInNewContext(code, { window, document, WeakSet, MutationObserver: class { observe() {} } });
  return { window, video, events, messages, children, listeners };
}
const paused = fixture(false);
assert.equal(paused.video.plays, 0, 'inactive preview must not start');
paused.window.sfPlay();
assert.equal(paused.video.plays, 1);
paused.events.playing();
assert.deepEqual(paused.messages, ['playing']);
paused.window.sfPause();
paused.events.playing();
assert.equal(paused.messages.length, 1, 'late playing events while inactive must not reveal video');
paused.window.sfMute(false);
assert.equal(paused.video.muted, false);
assert.equal(paused.video.plays, 1, 'unmuting while paused must not resume');
paused.window.sfReplay();
assert.equal(paused.video.currentTime, 0);
paused.events.ended();
assert.equal(paused.messages.at(-1), 'ended');
paused.events.error();
assert.equal(paused.messages.at(-1), 'failed');
assert.equal(paused.children.at(-1).action, 'replay');
const active = fixture(true);
assert.equal(active.video.plays, 1);
active.listeners.message({ source: {}, data: { sfTrailer: 'test-token', action: 'pause' } });
assert.equal(active.video.pauses, 0, 'unrelated frames cannot send playback commands');
console.log('IMDb backup bridge checks passed.');
}
