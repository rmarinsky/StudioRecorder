const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const html = fs.readFileSync(path.join(__dirname, 'editor-workspace-throwaway.html'), 'utf8');
const css = fs.readFileSync(path.join(__dirname, 'editor-workspace-minimal.css'), 'utf8');
const { EditorTimeline } = require('./editor-workspace-model.js');

test('editor presents chat, linked media, and transcript at the same time', () => {
  assert.match(html, /class="chat-panel"/);
  assert.match(html, /class="editor-main"/);
  assert.match(html, /class="transcript-panel"/);
  assert.ok(html.indexOf('class="chat-panel"') < html.indexOf('class="editor-main"'));
  assert.ok(html.indexOf('class="editor-main"') < html.indexOf('class="transcript-panel"'));
  assert.doesNotMatch(html, /class="inspector-tabs"/);
  assert.doesNotMatch(html, /class="sidebar"/);
  assert.match(css, /grid-template-columns:\s*var\(--chat-width\)\s+minmax\(0,\s*1fr\)\s+var\(--transcript-width\)/);
});

test('video and audio lanes are adjacent under one ruler', () => {
  assert.match(html, /class="time-ruler"/);
  assert.match(html, /id="videoLane"[\s\S]*?<\/div>\s*<div[^>]*id="audioLane"/);
  assert.doesNotMatch(html, /id="audioToggle"/);
});

test('the chat offers sentence analysis and keeps edit proposals reviewable', () => {
  const app = fs.readFileSync(path.join(__dirname, 'editor-workspace-app.js'), 'utf8');
  assert.match(html, /data-prompt="Analyze the sentences"/);
  assert.match(html, /id="assistantScope"/);
  assert.match(app, /Show on timeline/);
  assert.match(app, /Apply edit/);
  assert.match(app, /No request was sent to OpenRouter/);
  assert.match(app, /selectionOrigin === 'transcript'/);
  assert.match(app, /Select both recorded phrases or clear the selection/);
});

test('prototype editing shortcuts and intent stay in the visible editor', () => {
  const app = fs.readFileSync(path.join(__dirname, 'editor-workspace-app.js'), 'utf8');
  assert.match(app, /\/\\b\(reorder\|move\)\\b\//);
  assert.match(app, /let keyboardAnchor = null/);
  assert.match(app, /selectOutputRange\(keyboardAnchor, playhead, 'keyboard'\)/);
  assert.match(app, /if \(byId\('editorScreen'\)\.hidden \|\| document\.querySelector\('dialog\[open\]'\)\) return/);
});

test('prototype controls reference unique elements', () => {
  const app = fs.readFileSync(path.join(__dirname, 'editor-workspace-app.js'), 'utf8');
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
  assert.equal(new Set(ids).size, ids.length, 'HTML IDs must be unique');
  for (const [, id] of app.matchAll(/byId\('([^']+)'\)/g)) {
    assert.ok(ids.includes(id), 'Missing element #' + id);
  }
});

test('existing editor actions remain discoverable', () => {
  assert.match(html, /id="timelineTools"/);
  assert.match(html, /id="gifButton"/);
  assert.match(html, /id="rawReveal"/);
});

test('small panel labels and selected words have readable light and dark contrast', () => {
  const token = name => css.match(new RegExp('--' + name + ':\\s*(#[0-9a-f]{6})', 'i'))[1];
  const darkToken = name => [...css.matchAll(new RegExp('--' + name + ':\\s*(#[0-9a-f]{6})', 'ig'))].at(-1)[1];
  const luminance = hex => {
    const channels = [1, 3, 5].map(index => parseInt(hex.slice(index, index + 2), 16) / 255);
    const linear = channels.map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
    return .2126 * linear[0] + .7152 * linear[1] + .0722 * linear[2];
  };
  const contrast = (a, b) => {
    const [bright, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (bright + .05) / (dark + .05);
  };
  assert.ok(contrast(token('quiet'), token('panel')) >= 4.5);
  assert.ok(contrast(token('selection'), '#ffffff') >= 4.5);
  assert.ok(contrast(darkToken('quiet'), darkToken('panel')) >= 4.5);
  assert.ok(contrast(darkToken('selection'), darkToken('selection-text')) >= 4.5);
});

test('one cut removes the same output interval from linked video and audio', () => {
  const timeline = new EditorTimeline(100);
  timeline.select(20, 30);
  assert.equal(timeline.cutSelection(), true);
  assert.equal(timeline.duration, 90);
  assert.deepEqual(timeline.pieces, [
    { sourceStart: 0, sourceEnd: 20 },
    { sourceStart: 30, sourceEnd: 100 },
  ]);
  assert.equal(timeline.originalDuration, 100);
  assert.equal(timeline.sourceToOutput(35), 25);
  assert.deepEqual(timeline.sourceRangeToOutput(35, 36), [{ start: 25, end: 26 }]);
});

test('reordering recorded speech moves source intervals without altering duration', () => {
  const timeline = new EditorTimeline(100);
  assert.equal(timeline.moveSourceRangeBefore(40, 50, 20), true);
  assert.equal(timeline.duration, 100);
  assert.deepEqual(timeline.pieces, [
    { sourceStart: 0, sourceEnd: 20 },
    { sourceStart: 40, sourceEnd: 50 },
    { sourceStart: 20, sourceEnd: 40 },
    { sourceStart: 50, sourceEnd: 100 },
  ]);
  assert.equal(timeline.sourceToOutput(45), 25);
  assert.equal(timeline.sourceToOutput(25), 35);
  assert.equal(timeline.sourceToOutput(20), 30);
  assert.equal(timeline.undo(), true);
  assert.deepEqual(timeline.pieces, [{ sourceStart: 0, sourceEnd: 100 }]);
  assert.equal(timeline.redo(), true);
  assert.equal(timeline.sourceToOutput(45), 25);
});

test('a cut after reordering removes only the chosen output span', () => {
  const timeline = new EditorTimeline(100);
  timeline.moveSourceRangeBefore(40, 50, 20);
  timeline.select(21, 24);
  assert.equal(timeline.cutSelection(), true);
  assert.equal(timeline.duration, 97);
  assert.deepEqual(timeline.sourceRangeToOutput(40, 50), [
    { start: 20, end: 21 },
    { start: 21, end: 27 },
  ]);
  assert.equal(timeline.sourceToOutput(42), null);
  assert.equal(timeline.originalDuration, 100);
});
