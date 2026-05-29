// ui.jsx — Docket prototype: theme factory + shell (rail, header, switcher, chips)
// Reuses GreekDoc / Ring / Spark / data from shared.jsx.

const ACCENTS = {
  'Ink navy': { accent: '#1e3a5f', dark: '#152a44', soft: '#eaeff5' },
  'Burgundy': { accent: '#6e2433', dark: '#551a26', soft: '#f4ebec' },
  'Forest':   { accent: '#1f5c4d', dark: '#16453a', soft: '#e8f1ed' },
  'Slate':    { accent: '#3a4150', dark: '#2a3039', soft: '#edeef1' },
};
const SERIFS = {
  'Spectral':     "'Spectral', Georgia, serif",
  'Newsreader':   "'Newsreader', Georgia, serif",
  'Source Serif': "'Source Serif 4', Georgia, serif",
};

function makeTheme(t) {
  const a = Object.values(ACCENTS).find(x => x.accent === t.accent) || ACCENTS['Ink navy'];
  const mult = t.density === 'compact' ? 0.82 : t.density === 'comfy' ? 1.16 : 1;
  return {
    paper: '#f3efe5', panel: '#fbf9f3', card: '#ffffff',
    ink: '#22201b', ink2: '#6c675c', ink3: '#9c968a',
    line: 'rgba(40,35,25,0.11)', line2: 'rgba(40,35,25,0.07)',
    navy: a.accent, navyDk: a.dark, navySoft: a.soft,
    done: '#4f7a52', run: '#b07a2e', fail: '#a23b2e',
    sans: "'Public Sans', system-ui, sans-serif",
    serif: SERIFS[t.serif] || SERIFS['Spectral'],
    mono: "'IBM Plex Mono', monospace",
    sp: (n) => Math.round(n * mult),
    d: mult,
  };
}

function StatusChip({ T, status }) {
  const map = {
    done:    { t: 'Extracted', c: T.done, bg: 'rgba(79,122,82,0.10)' },
    running: { t: 'Running',   c: T.run,  bg: 'rgba(176,122,46,0.10)' },
    queued:  { t: 'Queued',    c: T.ink2, bg: 'rgba(40,35,25,0.06)' },
    pending: { t: 'Pending',   c: T.ink3, bg: 'transparent' },
    failed:  { t: 'Failed',    c: T.fail, bg: 'rgba(162,59,46,0.10)' },
  };
  const m = map[status] || map.pending;
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, font: `600 11px ${T.sans}`,
      letterSpacing: 0.2, color: m.c, background: m.bg, padding: '3px 9px', borderRadius: 100,
      border: status === 'pending' ? `1px solid ${T.line}` : 'none', whiteSpace: 'nowrap' }}>
      <span style={{ width: 6, height: 6, borderRadius: 100, background: m.c, opacity: status === 'pending' ? 0.4 : 1 }} />
      {m.t}
    </span>
  );
}

// Vertical pipeline rail with project switcher
function Rail({ T, project, stage, onStage, onSwitch, switcherOpen, projects, onPick, stageProgress }) {
  return (
    <div style={{ width: 256, flexShrink: 0, background: T.panel, borderRight: `1px solid ${T.line}`,
      display: 'flex', flexDirection: 'column', height: '100%', position: 'relative' }}>
      <div style={{ padding: '18px 22px 15px', borderBottom: `1px solid ${T.line2}` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
          <div style={{ width: 26, height: 26, borderRadius: 6, background: T.navy, color: '#fff',
            display: 'grid', placeItems: 'center', font: `700 13px ${T.serif}` }}>C</div>
          <div style={{ font: `700 12px ${T.sans}`, letterSpacing: 1.4, color: T.ink }}>CHARGESHEET</div>
        </div>
      </div>

      {/* project switcher */}
      <div style={{ padding: '14px 16px', position: 'relative' }}>
        <div style={{ font: `600 10px ${T.sans}`, letterSpacing: 1, color: T.ink3, marginBottom: 7 }}>CURRENT MATTER</div>
        <button onClick={onSwitch} style={{ width: '100%', textAlign: 'left', background: T.card,
          border: `1px solid ${switcherOpen ? T.navy : T.line}`, borderRadius: 9, padding: '10px 12px', cursor: 'pointer',
          display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
          <div style={{ minWidth: 0 }}>
            <div style={{ font: `600 13px ${T.sans}`, color: T.ink, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{project.name.replace('State v. ', 'St. v. ')}</div>
            <div style={{ font: `500 11px ${T.sans}`, color: T.ink3 }}>{project.cite.split(' · ')[0]}</div>
          </div>
          <span style={{ color: T.ink3, fontSize: 13, transform: switcherOpen ? 'rotate(180deg)' : 'none', transition: 'transform .15s' }}>⌄</span>
        </button>
        {switcherOpen && (
          <div style={{ position: 'absolute', left: 16, right: 16, top: 70, zIndex: 40, background: T.card,
            border: `1px solid ${T.line}`, borderRadius: 11, boxShadow: '0 10px 30px rgba(40,35,25,0.16)', overflow: 'hidden' }}>
            {projects.map((p) => (
              <button key={p.id} onClick={() => onPick(p.id)} style={{ width: '100%', textAlign: 'left',
                background: p.id === project.id ? T.navySoft : 'transparent', border: 'none',
                borderBottom: `1px solid ${T.line2}`, padding: '10px 13px', cursor: 'pointer' }}>
                <div style={{ font: `600 12.5px ${T.sans}`, color: T.ink }}>{p.name}</div>
                <div style={{ font: `500 10.5px ${T.sans}`, color: T.ink3, marginTop: 1 }}>{p.cite.split(' · ')[0]} · {p.pages}p</div>
              </button>
            ))}
            <button onClick={() => onPick('__all')} style={{ width: '100%', background: T.panel, border: 'none',
              padding: '10px 13px', cursor: 'pointer', font: `600 12px ${T.sans}`, color: T.navy }}>← All matters</button>
          </div>
        )}
      </div>

      {/* pipeline stepper */}
      <div style={{ padding: '6px 16px 16px', flex: 1, overflowY: 'auto' }}>
        <div style={{ font: `600 10px ${T.sans}`, letterSpacing: 1, color: T.ink3, margin: '4px 6px 10px' }}>PIPELINE</div>
        <div style={{ position: 'relative' }}>
          <div style={{ position: 'absolute', left: 18, top: 16, bottom: 16, width: 2, background: T.line }} />
          {STAGES.map((s) => {
            const activeN = STAGES.find(x => x.key === stage).n;
            const isActive = s.key === stage;
            const isDone = s.n < activeN;
            const prog = stageProgress[s.key] ?? 0;
            return (
              <button key={s.key} onClick={() => onStage(s.key)} style={{ width: '100%', textAlign: 'left',
                position: 'relative', display: 'flex', gap: 12, padding: '9px 7px', borderRadius: 9,
                background: isActive ? T.navySoft : 'transparent', marginBottom: 2, border: 'none', cursor: 'pointer' }}>
                <div style={{ width: 26, height: 26, flexShrink: 0, borderRadius: 100, zIndex: 1, display: 'grid', placeItems: 'center',
                  font: `700 12px ${T.sans}`, background: isActive ? T.navy : isDone ? T.done : T.card,
                  color: (isActive || isDone) ? '#fff' : T.ink2, border: (isActive || isDone) ? 'none' : `1.5px solid ${T.line}`,
                  transition: 'all .15s' }}>{isDone ? '✓' : s.n}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ font: `${isActive ? 700 : 600} 13px ${T.sans}`, color: isActive ? T.navy : T.ink }}>{s.label}</div>
                  <div style={{ font: `500 10.5px ${T.sans}`, color: T.ink3, lineHeight: 1.3, marginTop: 1 }}>{s.sub}</div>
                  {(isActive || isDone || prog > 0) && (
                    <div style={{ height: 3, background: T.line, borderRadius: 100, marginTop: 7, overflow: 'hidden' }}>
                      <div style={{ width: (prog * 100) + '%', height: '100%', background: isDone ? T.done : T.navy, borderRadius: 100, transition: 'width .3s' }} />
                    </div>
                  )}
                </div>
              </button>
            );
          })}
        </div>
      </div>

      <div style={{ padding: '13px 18px', borderTop: `1px solid ${T.line2}`, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7, font: `600 11px ${T.sans}`, color: T.ink2 }}>
          <span style={{ width: 7, height: 7, borderRadius: 100, background: T.done }} />Daemon connected
        </div>
      </div>
    </div>
  );
}

function Header({ T, title, sub, primaryLabel, onPrimary, secondaryLabel }) {
  return (
    <div style={{ padding: '16px 28px', borderBottom: `1px solid ${T.line}`, background: T.card,
      display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', gap: 16, flexShrink: 0 }}>
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{ font: `600 26px ${T.serif}`, color: T.ink, letterSpacing: -0.2, lineHeight: 1.15 }}>{title}</div>
        <div style={{ font: `500 12.5px ${T.sans}`, color: T.ink2, marginTop: 4 }}>{sub}</div>
      </div>
      <div style={{ display: 'flex', gap: 10, flexShrink: 0 }}>
        {secondaryLabel && <button style={{ font: `600 12.5px ${T.sans}`, color: T.ink, background: T.card,
          border: `1px solid ${T.line}`, borderRadius: 8, padding: '9px 15px', cursor: 'pointer', whiteSpace: 'nowrap' }}>{secondaryLabel}</button>}
        {primaryLabel && <button onClick={onPrimary} style={{ font: `600 12.5px ${T.sans}`, color: '#fff', background: T.navy,
          border: 'none', borderRadius: 8, padding: '9px 17px', cursor: 'pointer', whiteSpace: 'nowrap' }}>{primaryLabel}</button>}
      </div>
    </div>
  );
}

Object.assign(window, { ACCENTS, SERIFS, makeTheme, StatusChip, Rail, Header });
