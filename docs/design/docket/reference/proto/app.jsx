// app.jsx — Docket prototype root: state, simulated jobs, keyboard, tweaks, routing.

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "accent": "#1e3a5f",
  "serif": "Spectral",
  "density": "regular"
}/*EDITMODE-END*/;

function cloneSlices() {
  return SLICES.map(s => ({ ...s, prog: s.prog || 0 }));
}
function clonePrompts() {
  return PROMPTS.map(p => ({ ...p, prog: p.prog || 0 }));
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const T = makeTheme(t);

  const [view, setView] = React.useState('matters');     // matters | workspace
  const [activeId, setActiveId] = React.useState('p1');
  const [stage, setStage] = React.useState('slice');
  const [switcherOpen, setSwitcherOpen] = React.useState(false);
  const [store, setStore] = React.useState(() => ({ p1: { slices: cloneSlices(), prompts: clonePrompts(), page: 87, selSlice: 's3', selPrompt: 'imputation_scrutiny' } }));
  const [viewer, setViewer] = React.useState(null);       // slice obj for OCR text modal
  const timers = React.useRef({});

  const project = PROJECTS.find(p => p.id === activeId);
  const ps = store[activeId] || {};
  const slices = ps.slices || [];
  const prompts = ps.prompts || [];

  function ensure(id) {
    setStore(prev => prev[id] ? prev : { ...prev, [id]: { slices: cloneSlices(), prompts: clonePrompts(), page: 1, selSlice: null, selPrompt: 'imputation_scrutiny' } });
  }
  function patchProj(id, patch) {
    setStore(prev => ({ ...prev, [id]: { ...prev[id], ...patch } }));
  }
  function patchSlice(id, sid, patch) {
    setStore(prev => ({ ...prev, [id]: { ...prev[id], slices: prev[id].slices.map(s => s.id === sid ? { ...s, ...patch } : s) } }));
  }
  function patchPrompt(id, key, patch) {
    setStore(prev => ({ ...prev, [id]: { ...prev[id], prompts: prev[id].prompts.map(p => p.key === key ? { ...p, ...patch } : p) } }));
  }

  function openProject(id) {
    if (id === '__all') { setView('matters'); setSwitcherOpen(false); return; }
    ensure(id); setActiveId(id); setView('workspace'); setStage('slice'); setSwitcherOpen(false);
  }

  // ---- simulated jobs ----
  function simOcr(pid, sid) {
    patchSlice(pid, sid, { ocr: 'running', prog: 0.04 });
    const key = pid + ':' + sid;
    clearInterval(timers.current[key]);
    timers.current[key] = setInterval(() => {
      setStore(prev => {
        const s = prev[pid].slices.find(x => x.id === sid);
        if (!s) return prev;
        const np = (s.prog || 0) + 0.08 + Math.random() * 0.07;
        let patch;
        if (np >= 1) {
          clearInterval(timers.current[key]);
          const pages = s.range[1] - s.range[0] + 1;
          patch = { ocr: 'done', prog: 1, pagesOut: pages, latency: 8 + pages * 1.1 };
        } else patch = { prog: np };
        return { ...prev, [pid]: { ...prev[pid], slices: prev[pid].slices.map(x => x.id === sid ? { ...x, ...patch } : x) } };
      });
    }, 260);
  }
  function ocrAll(pid) {
    const list = (store[pid].slices || []).filter(s => s.ocr === 'pending' || s.ocr === 'queued');
    list.forEach((s, i) => setTimeout(() => simOcr(pid, s.id), i * 320));
  }
  function simPrompt(pid, pkey) {
    patchPrompt(pid, pkey, { status: 'running', prog: 0.05 });
    const key = pid + ':P:' + pkey;
    clearInterval(timers.current[key]);
    timers.current[key] = setInterval(() => {
      setStore(prev => {
        const p = prev[pid].prompts.find(x => x.key === pkey);
        if (!p) return prev;
        const np = (p.prog || 0) + 0.07 + Math.random() * 0.06;
        let patch;
        if (np >= 1) {
          clearInterval(timers.current[key]);
          patch = { status: 'done', prog: 1, words: 1800 + Math.round(Math.random() * 1600), latency: 30 + Math.random() * 28 };
        } else patch = { prog: np };
        return { ...prev, [pid]: { ...prev[pid], prompts: prev[pid].prompts.map(x => x.key === pkey ? { ...x, ...patch } : x) } };
      });
    }, 300);
  }
  function runAllPrompts(pid) {
    const list = (store[pid].prompts || []).filter(p => p.status === 'pending' || p.status === 'queued');
    list.forEach((p, i) => setTimeout(() => simPrompt(pid, p.key), i * 360));
  }

  React.useEffect(() => () => { Object.values(timers.current).forEach(clearInterval); }, []);

  // ---- slice editing ----
  function addSlice() {
    const p = ps.page || 1;
    const n = slices.length + 1;
    const id = 'new' + Date.now();
    const file = String(n).padStart(2, '0') + '_new_section.pdf';
    patchProj(activeId, { slices: [...slices, { id, file, label: 'New section', range: [p, p], size: '—', ocr: 'pending', pagesOut: 0, latency: 0, prog: 0 }], selSlice: id });
  }
  function setRange(which) {
    if (!ps.selSlice) return;
    const s = slices.find(x => x.id === ps.selSlice);
    if (!s) return;
    const p = ps.page || 1;
    const range = which === 'start' ? [p, Math.max(p, s.range[1])] : [Math.min(p, s.range[0]), p];
    patchSlice(activeId, ps.selSlice, { range });
  }
  function changePage(d) {
    patchProj(activeId, { page: Math.min(project.pages, Math.max(1, (ps.page || 1) + d)) });
  }

  React.useEffect(() => {
    function onKey(e) {
      if (view !== 'workspace' || stage !== 'slice') return;
      const tg = e.target;
      if (tg && (tg.tagName === 'INPUT' || tg.tagName === 'TEXTAREA' || tg.isContentEditable)) return;
      if (e.key === '[') setRange('start');
      else if (e.key === ']') setRange('end');
      else if (e.key === 'n' && !e.metaKey && !e.ctrlKey) addSlice();
      else if (e.key === 'ArrowLeft') changePage(-1);
      else if (e.key === 'ArrowRight') changePage(1);
      else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); setStage('extract'); }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  const stageProgress = {
    slice: slices.length ? 1 : 0,
    extract: slices.length ? slices.filter(s => s.ocr === 'done').length / slices.length : 0,
    analyze: prompts.length ? prompts.filter(p => p.status === 'done').length / prompts.length : 0,
    review: 0,
  };
  stageProgress.review = (stageProgress.extract + stageProgress.analyze) / 2;

  const doneSlices = slices.filter(s => s.ocr === 'done').length;
  const donePrompts = prompts.filter(p => p.status === 'done').length;

  const headers = {
    slice:   { title: project.name, sub: `${project.file} · ${project.pages} pages · ${project.desc.split('—')[1] ? '§§' + project.desc.split('§§')[1] : project.desc}`, primary: 'Save & extract →', onPrimary: () => setStage('extract'), secondary: 'Export brief' },
    extract: { title: 'Extractions', sub: `${doneSlices} of ${slices.length} slices extracted to clean text`, primary: 'OCR all pending', onPrimary: () => ocrAll(activeId) },
    analyze: { title: 'Defence analysis', sub: `${donePrompts} of ${prompts.length} prompts complete`, primary: 'Run all', onPrimary: () => runAllPrompts(activeId) },
    review:  { title: 'Review', sub: 'Usage, cost & generated outputs for this matter', primary: 'Export brief', onPrimary: () => {} },
  };
  const H = headers[stage];

  const panel = (
    <TweaksPanel>
      <TweakSection label="Accent" />
      <TweakColor label="Ink color" value={t.accent}
        options={Object.values(ACCENTS).map(a => a.accent)}
        onChange={(v) => setTweak('accent', v)} />
      <TweakSection label="Typography" />
      <TweakSelect label="Serif (content)" value={t.serif} options={Object.keys(SERIFS)} onChange={(v) => setTweak('serif', v)} />
      <TweakSection label="Layout" />
      <TweakRadio label="Density" value={t.density} options={['compact', 'regular', 'comfy']} onChange={(v) => setTweak('density', v)} />
    </TweaksPanel>
  );

  if (view === 'matters') {
    return (
      <div style={{ width: '100vw', height: '100vh', display: 'flex', flexDirection: 'column', background: T.paper, overflow: 'hidden' }}>
        <div style={{ height: 56, flexShrink: 0, borderBottom: `1px solid ${T.line}`, background: T.panel, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 40px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
            <div style={{ width: 26, height: 26, borderRadius: 6, background: T.navy, color: '#fff', display: 'grid', placeItems: 'center', font: `700 13px ${T.serif}` }}>C</div>
            <div style={{ font: `700 12px ${T.sans}`, letterSpacing: 1.4, color: T.ink }}>CHARGESHEET</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 7, font: `600 11px ${T.sans}`, color: T.ink2 }}>
            <span style={{ width: 7, height: 7, borderRadius: 100, background: T.done }} />Daemon connected
          </div>
        </div>
        <MattersView T={T} projects={PROJECTS} onOpen={openProject} />
        {panel}
      </div>
    );
  }

  return (
    <div style={{ width: '100vw', height: '100vh', display: 'flex', background: T.paper, overflow: 'hidden' }}>
      <Rail T={T} project={project} stage={stage} onStage={setStage}
        onSwitch={() => setSwitcherOpen(o => !o)} switcherOpen={switcherOpen}
        projects={PROJECTS} onPick={openProject} stageProgress={stageProgress} />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden', minWidth: 0 }}>
        <Header T={T} title={H.title} sub={H.sub} primaryLabel={H.primary} onPrimary={H.onPrimary} secondaryLabel={H.secondary} />
        {stage === 'slice' && (
          <SliceView T={T} slices={slices} page={ps.page || 1} pageCount={project.pages} selId={ps.selSlice}
            onSelect={(id) => patchProj(activeId, { selSlice: id })} onAdd={addSlice}
            onPage={changePage} onSave={() => setStage('extract')} />
        )}
        {stage === 'extract' && (
          <ExtractView T={T} slices={slices} onOcr={(id) => simOcr(activeId, id)} onView={(s) => setViewer(s)} />
        )}
        {stage === 'analyze' && (
          <AnalyzeView T={T} prompts={prompts} sel={ps.selPrompt}
            onSel={(k) => patchProj(activeId, { selPrompt: k })} onRun={(k) => simPrompt(activeId, k)} />
        )}
        {stage === 'review' && <ReviewView T={T} slices={slices} prompts={prompts} />}
      </div>

      {viewer && (
        <div onClick={() => setViewer(null)} style={{ position: 'fixed', inset: 0, zIndex: 60, background: 'rgba(30,28,22,0.45)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 32 }}>
          <div onClick={(e) => e.stopPropagation()} style={{ width: '100%', maxWidth: 720, maxHeight: '86vh', overflowY: 'auto', background: T.card, borderRadius: 14, boxShadow: '0 24px 60px rgba(30,28,22,0.3)', padding: '26px 32px' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
              <div>
                <div style={{ font: `500 11px ${T.mono}`, color: T.ink3 }}>{viewer.file.replace('.pdf', '.md')}</div>
                <div style={{ font: `600 19px ${T.serif}`, color: T.ink, marginTop: 2 }}>{viewer.label}</div>
              </div>
              <button onClick={() => setViewer(null)} style={{ font: `600 12px ${T.sans}`, color: T.ink, background: T.card, border: `1px solid ${T.line}`, borderRadius: 7, padding: '7px 13px', cursor: 'pointer' }}>Close</button>
            </div>
            <div style={{ font: `400 14px ${T.serif}`, color: T.ink, lineHeight: 1.75 }}>
              <div style={{ font: `600 13px ${T.sans}`, color: T.navy, margin: '0 0 6px' }}>IN THE COURT OF THE SPECIAL JUDGE</div>
              <p style={{ margin: '0 0 14px' }}>The chargesheet under §173 CrPC is filed against the accused in respect of offences punishable under §§420, 406 and 120-B of the Indian Penal Code. The investigation discloses the following material on the record of this section ({viewer.range[0]}–{viewer.range[1]}).</p>
              <div style={{ font: `600 14px ${T.serif}`, color: T.ink, margin: '0 0 6px' }}>Statement of facts</div>
              <p style={{ margin: '0 0 14px' }}>On the date of the complaint, the complainant alleges that a sum of ₹42,00,000 was transferred to the accused on the representation that it would be invested in a joint venture. The amount is said to have been diverted; partial repayment is acknowledged in the bank records produced with this chargesheet.</p>
              <p style={{ margin: 0, font: `400 12.5px ${T.mono}`, color: T.ink3 }}>— page markers detected: {viewer.pagesOut || (viewer.range[1] - viewer.range[0] + 1)} · model vision-ocr —</p>
            </div>
          </div>
        </div>
      )}
      {panel}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
