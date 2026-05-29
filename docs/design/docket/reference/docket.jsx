// docket.jsx — Direction I "Docket": vertical pipeline rail, classic/official.
// Fonts: Public Sans (UI) + Spectral (serif content). Warm ivory + ink navy.

const dk = {
  paper:   '#f3efe5',
  panel:   '#fbf9f3',
  card:    '#ffffff',
  ink:     '#22201b',
  ink2:    '#6c675c',
  ink3:    '#9c968a',
  line:    'rgba(40,35,25,0.11)',
  line2:   'rgba(40,35,25,0.07)',
  navy:    '#1e3a5f',
  navyDk:  '#152a44',
  navySoft:'#eaeff5',
  done:    '#4f7a52',
  run:     '#b07a2e',
  sans:    "'Public Sans', system-ui, sans-serif",
  serif:   "'Spectral', Georgia, serif",
};

function DkChip({ status }) {
  const map = {
    done:    { t: 'Extracted', c: dk.done, bg: 'rgba(79,122,82,0.10)' },
    running: { t: 'OCR running', c: dk.run, bg: 'rgba(176,122,46,0.10)' },
    queued:  { t: 'Queued', c: dk.ink2, bg: 'rgba(40,35,25,0.06)' },
    pending: { t: 'Pending', c: dk.ink3, bg: 'transparent' },
  };
  const m = map[status] || map.pending;
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, font: `600 11px ${dk.sans}`,
      letterSpacing: 0.2, color: m.c, background: m.bg, padding: '3px 9px', borderRadius: 100,
      border: status === 'pending' ? `1px solid ${dk.line}` : 'none' }}>
      <span style={{ width: 6, height: 6, borderRadius: 100, background: m.c,
        opacity: status === 'pending' ? 0.4 : 1 }} />
      {m.t}
    </span>
  );
}

// Left pipeline rail shared by Docket screens
function DkRail({ active }) {
  return (
    <div style={{ width: 248, flexShrink: 0, background: dk.panel, borderRight: `1px solid ${dk.line}`,
      display: 'flex', flexDirection: 'column', height: '100%' }}>
      {/* brand */}
      <div style={{ padding: '20px 22px 16px', borderBottom: `1px solid ${dk.line2}` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
          <div style={{ width: 26, height: 26, borderRadius: 6, background: dk.navy, color: '#fff',
            display: 'grid', placeItems: 'center', font: `700 13px ${dk.serif}` }}>C</div>
          <div style={{ font: `700 12px ${dk.sans}`, letterSpacing: 1.4, color: dk.ink }}>CHARGESHEET</div>
        </div>
      </div>

      {/* project switcher */}
      <div style={{ padding: '14px 16px' }}>
        <div style={{ font: `600 10px ${dk.sans}`, letterSpacing: 1, color: dk.ink3, marginBottom: 7 }}>CURRENT MATTER</div>
        <div style={{ background: dk.card, border: `1px solid ${dk.line}`, borderRadius: 9, padding: '10px 12px',
          display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div style={{ minWidth: 0 }}>
            <div style={{ font: `600 13px ${dk.sans}`, color: dk.ink, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>State v. Deshmukh</div>
            <div style={{ font: `500 11px ${dk.sans}`, color: dk.ink3 }}>FIR 214/2024</div>
          </div>
          <span style={{ color: dk.ink3, fontSize: 14 }}>⌄</span>
        </div>
      </div>

      {/* pipeline stepper */}
      <div style={{ padding: '6px 16px 16px', flex: 1 }}>
        <div style={{ font: `600 10px ${dk.sans}`, letterSpacing: 1, color: dk.ink3, margin: '4px 6px 10px' }}>PIPELINE</div>
        <div style={{ position: 'relative' }}>
          <div style={{ position: 'absolute', left: 18, top: 14, bottom: 14, width: 2, background: dk.line }} />
          {STAGES.map((s) => {
            const isActive = s.key === active;
            const isDone = s.n < STAGES.find(x => x.key === active).n;
            const prog = s.key === 'slice' ? 1 : s.key === 'extract' ? 0.55 : s.key === 'analyze' ? 0.4 : 0;
            return (
              <div key={s.key} style={{ position: 'relative', display: 'flex', gap: 12, padding: '8px 6px',
                borderRadius: 9, background: isActive ? dk.navySoft : 'transparent', marginBottom: 2 }}>
                <div style={{ width: 26, height: 26, flexShrink: 0, borderRadius: 100, zIndex: 1,
                  display: 'grid', placeItems: 'center', font: `700 12px ${dk.sans}`,
                  background: isActive ? dk.navy : isDone ? dk.done : dk.card,
                  color: (isActive || isDone) ? '#fff' : dk.ink2,
                  border: (isActive || isDone) ? 'none' : `1.5px solid ${dk.line}` }}>
                  {isDone ? '✓' : s.n}
                </div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ font: `${isActive ? 700 : 600} 13px ${dk.sans}`, color: isActive ? dk.navy : dk.ink }}>{s.label}</div>
                  <div style={{ font: `500 10.5px ${dk.sans}`, color: dk.ink3, lineHeight: 1.3, marginTop: 1 }}>{s.sub}</div>
                  {(isActive || isDone) && (
                    <div style={{ height: 3, background: dk.line, borderRadius: 100, marginTop: 7, overflow: 'hidden' }}>
                      <div style={{ width: (prog * 100) + '%', height: '100%', background: isDone ? dk.done : dk.navy, borderRadius: 100 }} />
                    </div>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>

      {/* footer */}
      <div style={{ padding: '14px 18px', borderTop: `1px solid ${dk.line2}`, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7, font: `600 11px ${dk.sans}`, color: dk.ink2 }}>
          <span style={{ width: 7, height: 7, borderRadius: 100, background: dk.done }} />Daemon connected
        </div>
        <span style={{ color: dk.ink3, fontSize: 15 }}>⚙</span>
      </div>
    </div>
  );
}

function DkHeader({ title, sub }) {
  return (
    <div style={{ padding: '18px 28px', borderBottom: `1px solid ${dk.line}`, background: dk.card,
      display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
      <div>
        <div style={{ font: `600 28px ${dk.serif}`, color: dk.ink, letterSpacing: -0.2 }}>{title}</div>
        <div style={{ font: `500 12.5px ${dk.sans}`, color: dk.ink2, marginTop: 3 }}>{sub}</div>
      </div>
      <div style={{ display: 'flex', gap: 10 }}>
        <button style={{ font: `600 12.5px ${dk.sans}`, color: dk.ink, background: dk.card,
          border: `1px solid ${dk.line}`, borderRadius: 8, padding: '9px 15px', cursor: 'pointer' }}>Export brief</button>
        <button style={{ font: `600 12.5px ${dk.sans}`, color: '#fff', background: dk.navy,
          border: 'none', borderRadius: 8, padding: '9px 17px', cursor: 'pointer' }}>Continue →</button>
      </div>
    </div>
  );
}

// ---- Screen 1: Projects home ----
function DocketProjects() {
  return (
    <div style={{ width: '100%', height: '100%', background: dk.paper, display: 'flex', fontFamily: dk.sans, color: dk.ink }}>
      <DkRail active="slice" />
      <div style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
        <div style={{ padding: '28px 36px 18px', display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div>
            <div style={{ font: `600 30px ${dk.serif}`, color: dk.ink, letterSpacing: -0.3 }}>Matters</div>
            <div style={{ font: `500 13px ${dk.sans}`, color: dk.ink2, marginTop: 4 }}>4 active · one chargesheet per matter</div>
          </div>
          <button style={{ font: `600 13px ${dk.sans}`, color: '#fff', background: dk.navy, border: 'none',
            borderRadius: 9, padding: '11px 18px', cursor: 'pointer', whiteSpace: 'nowrap' }}>+ New matter</button>
        </div>
        <div style={{ flex: 1, overflowY: 'auto', padding: '8px 36px 32px' }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {PROJECTS.map((p, i) => {
              const st = STAGES.find(s => s.key === p.stage);
              return (
                <div key={p.id} style={{ background: dk.card, border: `1px solid ${dk.line}`, borderRadius: 14,
                  padding: '20px 22px', boxShadow: i === 0 ? '0 2px 10px rgba(40,35,25,0.05)' : 'none' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                    <div style={{ minWidth: 0, flex: 1 }}>
                      <div style={{ font: `600 18px ${dk.serif}`, color: dk.ink, letterSpacing: -0.2, lineHeight: 1.2 }}>{p.name}</div>
                      <div style={{ font: `600 11.5px ${dk.sans}`, color: dk.navy, marginTop: 3, letterSpacing: 0.2 }}>{p.cite}</div>
                    </div>
                    <Ring value={p.progress} size={38} color={dk.navy} />
                  </div>
                  <div style={{ font: `400 13px ${dk.serif}`, color: dk.ink2, marginTop: 12, lineHeight: 1.45 }}>{p.desc}</div>
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 18,
                    paddingTop: 14, borderTop: `1px solid ${dk.line2}` }}>
                    <div style={{ display: 'flex', gap: 16 }}>
                      <div><div style={{ font: `700 14px ${dk.sans}`, color: dk.ink }}>{p.pages}</div><div style={{ font: `500 10.5px ${dk.sans}`, color: dk.ink3 }}>pages</div></div>
                      <div><div style={{ font: `700 14px ${dk.sans}`, color: dk.ink }}>{p.slices}</div><div style={{ font: `500 10.5px ${dk.sans}`, color: dk.ink3 }}>slices</div></div>
                    </div>
                    <span style={{ font: `600 11px ${dk.sans}`, color: dk.ink2, background: dk.navySoft,
                      padding: '5px 11px', borderRadius: 100 }}>{st.label} · {p.updated}</span>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}

// ---- Screen 2: Slice workspace ----
function DocketSlice() {
  return (
    <div style={{ width: '100%', height: '100%', background: dk.paper, display: 'flex', fontFamily: dk.sans, color: dk.ink }}>
      <DkRail active="slice" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
        <DkHeader title="State v. Deshmukh & Ors." sub="chargesheet_214-2024.pdf · 412 pages · §§420, 406, 120-B IPC" />
        <div style={{ flex: 1, display: 'grid', gridTemplateColumns: '1.35fr 1fr', overflow: 'hidden' }}>
          {/* PDF viewer */}
          <div style={{ background: dk.paper, borderRight: `1px solid ${dk.line}`, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '11px 20px', borderBottom: `1px solid ${dk.line2}` }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, font: `600 12px ${dk.sans}`, color: dk.ink2 }}>
                <span style={{ border: `1px solid ${dk.line}`, borderRadius: 7, padding: '5px 9px' }}>‹</span>
                Page 87 / 412
                <span style={{ border: `1px solid ${dk.line}`, borderRadius: 7, padding: '5px 9px' }}>›</span>
              </div>
              <div style={{ font: `500 11px ${dk.sans}`, color: dk.ink3 }}>Press <b style={{ color: dk.navy }}>[</b> / <b style={{ color: dk.navy }}>]</b> to set range · <b style={{ color: dk.navy }}>n</b> new</div>
            </div>
            <div style={{ flex: 1, overflowY: 'auto', padding: '26px 32px', display: 'flex', justifyContent: 'center' }}>
              <div style={{ width: 360 }}>
                <GreekDoc tone="#fdfcf8" accent={dk.navy} lines={24} />
              </div>
            </div>
          </div>
          {/* slice list */}
          <div style={{ background: dk.card, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '13px 20px', borderBottom: `1px solid ${dk.line}` }}>
              <div style={{ font: `700 13px ${dk.sans}`, color: dk.ink }}>Slices <span style={{ color: dk.ink3, fontWeight: 600 }}>· 9</span></div>
              <button style={{ font: `600 11.5px ${dk.sans}`, color: dk.navy, background: dk.navySoft, border: 'none', borderRadius: 7, padding: '6px 11px', cursor: 'pointer' }}>+ Add slice</button>
            </div>
            <div style={{ flex: 1, overflowY: 'auto', padding: '12px 16px' }}>
              {SLICES.slice(0, 7).map((s, i) => (
                <div key={s.id} style={{ display: 'flex', gap: 12, padding: '11px 12px', borderRadius: 10,
                  border: `1px solid ${i === 2 ? dk.navy : dk.line2}`, marginBottom: 8,
                  background: i === 2 ? dk.navySoft : dk.card }}>
                  <div style={{ font: `700 12px ${dk.sans}`, color: dk.ink3, paddingTop: 1, width: 16 }}>{i + 1}</div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ font: `600 13px ${dk.sans}`, color: dk.ink }}>{s.label}</div>
                    <div style={{ font: `500 11px 'IBM Plex Mono', monospace`, color: dk.ink3, marginTop: 2 }}>{s.file}</div>
                  </div>
                  <div style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                    <div style={{ font: `700 12px ${dk.sans}`, color: dk.ink }}>pp. {s.range[0]}–{s.range[1]}</div>
                    <div style={{ font: `500 11px ${dk.sans}`, color: dk.ink3, marginTop: 2 }}>{s.size}</div>
                  </div>
                </div>
              ))}
            </div>
            <div style={{ padding: '14px 18px', borderTop: `1px solid ${dk.line}` }}>
              <button style={{ width: '100%', font: `700 13px ${dk.sans}`, color: '#fff', background: dk.navy, border: 'none', borderRadius: 9, padding: '12px', cursor: 'pointer' }}>Save 9 slices</button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ---- Screen 3: Defence Prompts ----
function DocketPrompts() {
  return (
    <div style={{ width: '100%', height: '100%', background: dk.paper, display: 'flex', fontFamily: dk.sans, color: dk.ink }}>
      <DkRail active="analyze" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
        <DkHeader title="Defence analysis" sub="State v. Deshmukh · 5 prompts run against extracted text" />
        <div style={{ flex: 1, overflow: 'hidden', display: 'grid', gridTemplateColumns: '1fr 1.05fr' }}>
          {/* prompt list */}
          <div style={{ borderRight: `1px solid ${dk.line}`, overflowY: 'auto', padding: '18px 20px', background: dk.panel }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
              <div style={{ font: `600 11px ${dk.sans}`, letterSpacing: 1, color: dk.ink3 }}>2 OF 5 COMPLETE</div>
              <button style={{ font: `600 11.5px ${dk.sans}`, color: '#fff', background: dk.navy, border: 'none', borderRadius: 7, padding: '7px 13px', cursor: 'pointer' }}>Run all</button>
            </div>
            {PROMPTS.map((p, i) => (
              <div key={p.key} style={{ background: dk.card, border: `1px solid ${i === 1 ? dk.navy : dk.line}`, borderRadius: 11,
                padding: '14px 15px', marginBottom: 10, boxShadow: i === 1 ? '0 2px 8px rgba(30,58,95,0.08)' : 'none' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 10 }}>
                  <div style={{ minWidth: 0 }}>
                    <div style={{ font: `600 14px ${dk.serif}`, color: dk.ink }}>{p.label}</div>
                    <div style={{ font: `400 12px ${dk.serif}`, color: dk.ink2, marginTop: 2, lineHeight: 1.4 }}>{p.sub}</div>
                  </div>
                  {p.status === 'done'
                    ? <span style={{ font: `600 11px ${dk.sans}`, color: dk.done }}>✓ Done</span>
                    : p.status === 'running'
                      ? <span style={{ font: `600 11px ${dk.sans}`, color: dk.run }}>Running</span>
                      : <button style={{ font: `600 11px ${dk.sans}`, color: dk.navy, background: dk.navySoft, border: 'none', borderRadius: 6, padding: '5px 11px', cursor: 'pointer' }}>Run</button>}
                </div>
                {p.status === 'running' && (
                  <div style={{ height: 4, background: dk.line, borderRadius: 100, marginTop: 11, overflow: 'hidden' }}>
                    <div style={{ width: (p.prog * 100) + '%', height: '100%', background: dk.run, borderRadius: 100 }} />
                  </div>
                )}
                {p.status === 'done' && (
                  <div style={{ font: `500 11px ${dk.sans}`, color: dk.ink3, marginTop: 9 }}>{p.words.toLocaleString()} words · {p.latency}s</div>
                )}
              </div>
            ))}
          </div>
          {/* output preview */}
          <div style={{ overflowY: 'auto', padding: '26px 34px', background: dk.paper }}>
            <div style={{ font: `600 11px ${dk.sans}`, letterSpacing: 1, color: dk.ink3, marginBottom: 6 }}>OUTPUT · IMPUTATION SCRUTINY</div>
            <div style={{ font: `600 23px ${dk.serif}`, color: dk.ink, marginBottom: 16 }}>Imputation scrutiny</div>
            <div style={{ background: dk.card, border: `1px solid ${dk.line}`, borderRadius: 12, padding: '28px 32px',
              boxShadow: '0 1px 3px rgba(40,35,25,0.05)' }}>
              <div style={{ font: `600 15px ${dk.serif}`, color: dk.navy, marginBottom: 10 }}>1. Imputation under §420 IPC</div>
              <p style={{ font: `400 14px ${dk.serif}`, color: dk.ink, lineHeight: 1.7, margin: '0 0 16px' }}>
                The charge alleges dishonest inducement of the complainant to deliver ₹42,00,000. On the material in the
                record, the inducement is sourced solely to the §161 statement of PW-3, which post-dates the alleged
                transfer by eleven months. No contemporaneous document evidences a representation made <i>before</i> delivery.
              </p>
              <div style={{ font: `600 15px ${dk.serif}`, color: dk.navy, marginBottom: 10 }}>2. Mens rea — gap in the chain</div>
              <p style={{ font: `400 14px ${dk.serif}`, color: dk.ink, lineHeight: 1.7, margin: '0 0 16px' }}>
                Dishonest intention at inception is not borne out. The bank records (slice 04) show partial repayment,
                which is inconsistent with the imputation of intent to deceive from the outset.
              </p>
              <div style={{ background: dk.navySoft, borderLeft: `3px solid ${dk.navy}`, borderRadius: '0 8px 8px 0', padding: '12px 16px' }}>
                <div style={{ font: `600 11px ${dk.sans}`, letterSpacing: 0.4, color: dk.navy, marginBottom: 4 }}>SUGGESTED OBJECTION</div>
                <p style={{ font: `400 13px ${dk.serif}`, color: dk.ink, lineHeight: 1.6, margin: 0 }}>
                  Imputation of §420 is unsupported absent a pre-delivery representation; the chain rests on a single
                  belated statement. Press for discharge on this count.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { DocketProjects, DocketSlice, DocketPrompts });
