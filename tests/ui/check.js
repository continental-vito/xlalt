// Drives the real MANAGER_HTML from src/init.lua in jsdom: builds the pages,
// switches tabs, edits and saves, and asserts on the messages the engine
// would receive. Catches id typos and wiring mistakes that Lua tests cannot.
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const lua = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'init.lua'), 'utf8');
const start = lua.indexOf('local MANAGER_HTML = [==[') + 'local MANAGER_HTML = [==['.length;
const html = lua.slice(start, lua.indexOf(']==]\n', start)).replace('CORGI_SRC', '');

let pass = 0, fail = 0;
const check = (name, cond, extra) => {
  if (cond) { pass++; console.log('  ok    ' + name); }
  else { fail++; console.log('  FAIL  ' + name + (extra !== undefined ? '  [' + extra + ']' : '')); }
};

const sent = [];
const dom = new JSDOM(html, {
  runScripts: 'dangerously',
  // The page calls send({op:'load'}) as its last statement, so the bridge
  // has to exist before the inline script runs — otherwise that first
  // message is lost and jsdom reports an uncaught TypeError.
  beforeParse(window) {
    window.webkit = { messageHandlers: { xl: { postMessage: m => sent.push(m) } } };
    window.alert = () => {};
  },
});
const w = dom.window, d = w.document;

check('page asks the engine for its catalog on load',
  sent.length === 1 && sent[0].op === 'load', JSON.stringify(sent));

const APPS = [
  { id: 'excel', label: 'Excel', accent: '#0F6A3F', accent2: '#1F8A55', accentDark: '#0C5733',
    enabled: true, items: [
      { seq: 'hvv', desc: 'Paste values', builtin: true, orig: 'hvv', kind: 'applescript',
        cmd: 'Script: paste special', param: 'paste special selection what paste values' }] },
  { id: 'powerpoint', label: 'PowerPoint', accent: '#C43E1C', accent2: '#E2603C', accentDark: '#9E3116',
    enabled: true, items: [
      { seq: 'hi', desc: 'New slide', builtin: true, orig: 'hi', kind: 'keystroke',
        cmd: 'Keys: ⌘⇧N', param: 'cmd+shift+n' }] },
  { id: 'word', label: 'Word', accent: '#185ABD', accent2: '#2B7CD3', accentDark: '#12489A',
    enabled: false, items: [
      { seq: 'hs2', desc: 'Heading 2', builtin: true, orig: 'hs2', kind: 'keystroke',
        cmd: 'Keys: ⌘⌥2', param: 'cmd+alt+2' },
      { seq: 'hzz', desc: 'My macro', builtin: false, orig: 'hzz', kind: 'keystroke',
        cmd: 'Keys: ⌘⇧Z', param: 'cmd+shift+z' }] },
];

w.render(APPS);

// ---------------------------------------------------------------- tabs
check('four tabs are built: three hosts plus Feedback',
  d.querySelectorAll('#tabs button').length === 4,
  d.querySelectorAll('#tabs button').length);
check('tab labels read Excel / PowerPoint / Word / Feedback',
  [...d.querySelectorAll('#tabs button')].map(b => b.textContent).join(',') ===
  'Excel,PowerPoint,Word,Feedback');
check('a page exists for every host',
  !!d.getElementById('page-excel') && !!d.getElementById('page-powerpoint') && !!d.getElementById('page-word'));
check('Excel is the tab shown first',
  d.getElementById('tab-excel').className === 'on' &&
  d.getElementById('page-excel').className.includes('on'));

// --------------------------------------------------------------- theming
const accent = () => w.getComputedStyle(d.documentElement).getPropertyValue('--accent').trim()
  || d.documentElement.style.getPropertyValue('--accent').trim();
check('Excel theme is green', accent() === '#0F6A3F', accent());
w.showPage('powerpoint');
check('PowerPoint theme is orange', accent() === '#C43E1C', accent());
check('switching tab shows only the PowerPoint page',
  d.getElementById('page-powerpoint').className.includes('on') &&
  !d.getElementById('page-excel').className.includes('on'));
w.showPage('word');
check('Word theme is blue', accent() === '#185ABD', accent());
check('header subtitle names the current host',
  d.getElementById('sub').textContent.includes('Word'), d.getElementById('sub').textContent);
w.showPage('fb');
check('Feedback tab falls back to the Excel theme', accent() === '#0F6A3F', accent());
check('opening Feedback asks the engine for stats',
  sent.some(m => m.op === 'loadstats'));

// ----------------------------------------------------------------- rows
check('each host renders its own rows',
  d.querySelectorAll('#rows-excel tr').length === 1 &&
  d.querySelectorAll('#rows-word tr').length === 2);
check('sequences render spaced and uppercased',
  d.querySelector('#rows-word td.seq').textContent === 'H S 2',
  d.querySelector('#rows-word td.seq').textContent);
check('custom entries are tagged as custom',
  [...d.querySelectorAll('#rows-word .tag')].some(t => t.textContent === 'custom'));

// ------------------------------------------------------------- switches
check('a disabled host shows its checkbox unticked and the warning banner',
  d.getElementById('en-word').checked === false &&
  d.getElementById('off-word').style.display === 'block');
check('an enabled host hides the warning banner',
  d.getElementById('off-excel').style.display === 'none');
d.getElementById('en-word').checked = true;
d.getElementById('en-word').dispatchEvent(new w.Event('change'));
check('ticking the host switch reports it to the engine with the host id',
  sent.some(m => m.op === 'appenabled' && m.app === 'word' && m.on === true),
  JSON.stringify(sent[sent.length - 1]));

// ---------------------------------------------------------------- search
w.showPage('word');
d.getElementById('search-word').value = 'macro';
w.applyFilter('word');
check('search filters within the host only',
  d.querySelectorAll('#rows-word tr').length === 1 &&
  d.querySelectorAll('#rows-excel tr').length === 1);
d.getElementById('search-word').value = '';
w.applyFilter('word');

// ------------------------------------------------------------ add & edit
d.getElementById('seq-word').value = 'hqq';
d.getElementById('desc-word').value = 'Test';
d.getElementById('kind-word').value = 'keystroke';
d.getElementById('param-word').value = 'cmd+q';
w.save('word');
const added = sent[sent.length - 1];
check('adding a shortcut sends the host id with it',
  added.op === 'add' && added.app === 'word' && added.seq === 'hqq', JSON.stringify(added));
check('the form resets after saving', d.getElementById('seq-word').value === '');

w.beginEdit('word', 0);
check('editing loads the row into that host form',
  d.getElementById('seq-word').value === 'hs2' && d.getElementById('param-word').value === 'cmd+alt+2');
d.getElementById('desc-word').value = 'Big heading';
w.save('word');
const edited = sent[sent.length - 1];
check('saving an edit sends op=edit scoped to the host',
  edited.op === 'edit' && edited.app === 'word' && edited.orig === 'hs2', JSON.stringify(edited));

w.removeIt('word', 1);
const removed = sent[sent.length - 1];
check('removing sends op=delete scoped to the host',
  removed.op === 'delete' && removed.app === 'word' && removed.seq === 'hzz');

// ------------------------------------------------------- validation & re-render
w.save('word');
check('saving an empty form shows an error instead of sending',
  d.getElementById('err-word').style.display === 'block' &&
  sent[sent.length - 1].op === 'delete');

const before = d.getElementById('tabs').innerHTML;
d.getElementById('search-excel').value = 'paste';
w.render(APPS);
check('a re-render keeps the current tab and does not rebuild the chrome',
  d.getElementById('tabs').innerHTML === before &&
  d.getElementById('page-word').className.includes('on'));
check('a re-render preserves what the user typed in the search box',
  d.getElementById('search-excel').value === 'paste');

// -------------------------------------------------------------- overlay
w.setOverlay(true);
check('the overlay switch is mirrored on every host page',
  d.getElementById('ovl-excel').checked && d.getElementById('ovl-word').checked);
w.setStatus(false);
check('missing Accessibility raises the banner', d.getElementById('ax').style.display === 'flex');

// -------------------------------------------------------------- escaping
d.getElementById('search-excel').value = '';
w.render([{ id: 'excel', label: 'Excel', accent: '#0F6A3F', accent2: '#1F8A55', accentDark: '#0C5733',
  enabled: true, items: [{ seq: 'hxx', desc: '<img src=x onerror=alert(1)>', builtin: false,
  orig: 'hxx', kind: 'menu', cmd: 'Menu: a>b', param: 'a>b' }] }, APPS[1], APPS[2]]);
check('descriptions are escaped, not injected as HTML',
  d.querySelectorAll('#rows-excel img').length === 0 &&
  d.querySelector('#rows-excel tr').textContent.includes('<img'));

console.log('\n' + pass + ' passed, ' + fail + ' failed\n');
process.exit(fail === 0 ? 0 : 1);
