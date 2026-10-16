// Run with: node Tests/TrailerBridgeTests.cjs
// Exercises the YouTube embed bridge in TrailerBackdrop.swift against a fake YT.Player.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const swift = fs.readFileSync(path.join(__dirname, '../Sources/Shared/Features/Detail/TrailerBackdrop.swift'), 'utf8');
assert.ok(!/imdb/i.test(swift.split('// MARK: - Web surface')[1] || ''), 'web player must not reference IMDb');
// YouTube rejects embeds whose page claims to be YouTube (error 152) or has no origin (153).
assert.ok(swift.includes('baseURL: URL(string: Self.appOrigin)'), 'trailer page must use the app identity as its origin');
assert.ok(!swift.includes("origin:'https://www.youtube-nocookie.com'"), 'player origin must be the app identity');
const page = swift.split('static func html(')[1].split('return """')[1].split('"""')[0];
const script = page.split('<script>')[1].split('</script>')[0];

function fixture({ keys, active, muted = true }) {
  const messages = [], intervals = [];
  let player = null;
  class Player {
    constructor(id, opts) {
      player = this; this.opts = opts; this.videoId = opts.videoId;
      this.plays = 0; this.pauses = 0; this.muted = false; this.t = 0; this.d = 120; this.loaded = [];
    }
    playVideo() { this.plays++; } pauseVideo() { this.pauses++; }
    mute() { this.muted = true; } unMute() { this.muted = false; }
    seekTo(t) { this.t = t; } loadVideoById(k) { this.loaded.push(k); this.videoId = k; }
    getDuration() { return this.d; } getCurrentTime() { return this.t; }
  }
  const window = { webkit: { messageHandlers: { trailer: { postMessage: m => messages.push(m) } } } };
  const code = script
    .replaceAll('\\(list)', JSON.stringify(keys))
    .replaceAll('\\(muted ? "true" : "false")', String(muted))
    .replaceAll('\\(active ? "true" : "false")', String(active));
  const ctx = { window, YT: { Player }, setInterval: fn => intervals.push(fn) };
  vm.runInNewContext(code + '\n;this.api={ready:onYouTubeIframeAPIReady,sfPlay,sfPause,sfMute,sfReplay};', ctx);
  ctx.api.ready();
  return { messages, get player() { return player; }, api: ctx.api, tick: () => intervals.forEach(f => f()) };
}

// No ids: fails straight away so the controller moves on.
assert.deepEqual(fixture({ keys: [], active: true }).messages, ['failed']);

// Inactive preview never starts or reveals.
const paused = fixture({ keys: ['abcdefghijk'], active: false });
paused.player.opts.events.onReady({ target: paused.player });
assert.equal(paused.player.plays, 0, 'inactive preview must not start');
assert.equal(paused.player.muted, true);
paused.player.opts.events.onStateChange({ data: 1 });
assert.equal(paused.player.pauses, 1, 'late playing while inactive is paused again');
assert.deepEqual(paused.messages, [], 'and does not reveal the video');
paused.api.sfPlay();
assert.equal(paused.player.plays, 1);
paused.player.opts.events.onStateChange({ data: 1 });
assert.deepEqual(paused.messages, ['playing']);
paused.player.opts.events.onStateChange({ data: 1 });
assert.deepEqual(paused.messages, ['playing'], 'playing is reported once');
paused.api.sfMute(false);
assert.equal(paused.player.muted, false);

// Fades out just before YouTube's end screen, then replays from the start.
paused.player.t = 119.5; paused.tick();
assert.equal(paused.messages.at(-1), 'ended');
paused.api.sfReplay();
assert.equal(paused.player.t, 0);

// Unavailable ids fall through to the next, then fail.
const fallback = fixture({ keys: ['aaaaaaaaaaa', 'bbbbbbbbbbb'], active: true });
fallback.player.opts.events.onError();
assert.deepEqual(fallback.player.loaded, ['bbbbbbbbbbb']);
fallback.player.opts.events.onError();
assert.equal(fallback.messages.at(-1), 'failed');

console.log('YouTube trailer bridge checks passed.');
