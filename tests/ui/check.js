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
    enabled: true, overlay: true, items: [
      { seq: 'hvv', desc: 'Paste values', builtin: true, orig: 'hvv', kind: 'applescript',
        cmd: 'Script: paste special', param: 'paste special selection what paste values' }] },
  { id: 'powerpoint', label: 'PowerPoint', accent: '#C43E1C', accent2: '#E2603C', accentDark: '#9E3116',
    enabled: true, overlay: false, items: [
      { seq: 'hi', desc: 'New slide', builtin: true, orig: 'hi', kind: 'keystroke',
        cmd: 'Keys: ⌘⇧N', param: 'cmd+shift+n' }] },
  { id: 'word', label: 'Word', accent: '#185ABD', accent2: '#2B7CD3', accentDark: '#12489A',
    enabled: false, overlay: true, items: [
      { seq: 'hs2', desc: 'Heading 2', builtin: true, orig: 'hs2', kind: 'keystroke',
        cmd: 'Keys: ⌘⌥2', param: 'cmd+alt+2' },
      { seq: 'hzz', desc: 'My macro', builtin: false, orig: 'hzz', kind: 'keystroke',
        cmd: 'Keys: ⌘⇧Z', param: 'cmd+shift+z' }] },
];

w.render(APPS);

// ---------------------------------------------------------------- tabs
check('five tabs are built: three hosts plus How to use and Feedback',
  d.querySelectorAll('#tabs button').length === 5,
  d.querySelectorAll('#tabs button').length);
check('tab labels read Excel / PowerPoint / Word / How to use / Feedback',
  [...d.querySelectorAll('#tabs button')].map(b => b.textContent).join(',') ===
  'Excel,PowerPoint,Word,How to use,Feedback');
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
check('Feedback tab is neutral grey, not a host colour', accent() === '#5A6169', accent());
check('opening Feedback asks the engine for stats',
  sent.some(m => m.op === 'loadstats'));
w.showPage('help');
check('How to use tab is neutral grey too', accent() === '#5A6169', accent());
check('leaving a host page restores that host colour on return',
  (w.showPage('powerpoint'), accent() === '#C43E1C'), accent());

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
check('the overlay switch reflects each host independently',
  d.getElementById('ovl-excel').checked === true &&
  d.getElementById('ovl-powerpoint').checked === false &&
  d.getElementById('ovl-word').checked === true);
d.getElementById('ovl-powerpoint').checked = true;
d.getElementById('ovl-powerpoint').dispatchEvent(new w.Event('change'));
check('toggling the overlay names the host it applies to',
  sent.some(m => m.op === 'overlay' && m.app === 'powerpoint' && m.on === true),
  JSON.stringify(sent[sent.length - 1]));
w.setStatus(false);
check('missing Accessibility raises the banner', d.getElementById('ax').style.display === 'flex');

// ------------------------------------------------------------ how to use
check('the guide is no longer folded into each host page',
  d.querySelectorAll('#page-excel details').length === 0);
check('each host page links to the guide instead',
  d.querySelector('#page-excel .hint a').textContent.includes('How to use'));
const help = d.getElementById('help-body');
check('the guide page documents all three methods in full',
  /Keystroke/.test(help.textContent) && /Menu path/.test(help.textContent) &&
  /AppleScript/.test(help.textContent) && help.querySelectorAll('.card').length === 3);
check('the guide warns that menu paths are language-specific',
  /language/i.test(help.querySelector('.warn').textContent));
check('AppleScript examples are given for every host',
  /go to slide/.test(help.textContent) && /font object of selection/.test(help.textContent) &&
  /zoom of active window/.test(help.textContent));
check('videos render as placeholders until a URL is supplied',
  help.querySelectorAll('.vid .soon').length === 0 && help.querySelectorAll('video').length === 0);

w.setTutorial([
  { title: 'Getting started', caption: 'First run.', url: '' },
  { title: 'Sequences', caption: 'Using them.', url: 'https://example.test/a.mp4' },
]);
const help2 = d.getElementById('help-body');
check('a tutorial entry without a URL shows a coming-soon tile',
  help2.querySelectorAll('.vid .soon').length === 1);
check('a tutorial entry with a URL renders a player',
  help2.querySelectorAll('video').length === 1 &&
  help2.querySelector('video').getAttribute('src') === 'https://example.test/a.mp4');
check('tutorial titles and captions are shown',
  /Getting started/.test(help2.textContent) && /First run/.test(help2.textContent));

// -------------------------------------------------------------- escaping
d.getElementById('search-excel').value = '';
w.render([{ id: 'excel', label: 'Excel', accent: '#0F6A3F', accent2: '#1F8A55', accentDark: '#0C5733',
  enabled: true, overlay: true, items: [{ seq: 'hxx', desc: '<img src=x onerror=alert(1)>', builtin: false,
  orig: 'hxx', kind: 'menu', cmd: 'Menu: a>b', param: 'a>b' }] }, APPS[1], APPS[2]]);
check('descriptions are escaped, not injected as HTML',
  d.querySelectorAll('#rows-excel img').length === 0 &&
  d.querySelector('#rows-excel tr').textContent.includes('<img'));

console.log('\n' + pass + ' passed, ' + fail + ' failed\n');
process.exit(fail === 0 ? 0 : 1);
