// views.jsx — Docket prototype stage views: Matters, Slice, Extract, Analyze, Review
// Props pass theme T, project, live state and handlers down from App.

// ---------- sample content ----------
const PROMPT_OUTPUTS = {
  imputation_scrutiny: [
    ['§420 IPC — dishonest inducement',
      'Inducement is sourced solely to the §161 statement of PW-3, recorded eleven months after the alleged transfer. No contemporaneous document evidences a representation made before delivery.'],
    ['Mens rea — gap in the chain',
      'Dishonest intention at inception is not borne out. Bank records at slice 04 show partial repayment, inconsistent with intent to deceive from the outset.'],
  ],
  charge_memo_analysis: [
    ['Count I — §420 read with §120-B',
      'The memorandum frames a conspiracy spanning April–November. The overt acts pleaded are confined to two meetings; neither is corroborated by call-detail records in the RUDs.'],
    ['Count II — §406 criminal breach of trust',
      'Entrustment is assumed rather than proved. The seizure memos at slice 03 do not establish dominion over the funds at the relevant time.'],
  ],
};
const OBJECTION = {
  imputation_scrutiny: 'Imputation of §420 is unsupported absent a pre-delivery representation; the chain rests on a single belated statement. Press for discharge on this count.',
  charge_memo_analysis: 'Conspiracy count is bald — overt acts uncorroborated. Seek particulars and, failing that, discharge under §227 CrPC.',
};

// ---------- Matters ----------
function MattersView({ T, projects, onOpen }) {
  return (
    <div style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column', background: T.paper }}>
      <div style={{ padding: '28px 40px 18px', display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
        <div>
          <div style={{ font: `600 30px ${T.serif}`, color: T.ink, letterSpacing: -0.3 }}>Matters</div>
          <div style={{ font: `500 13px ${T.sans}`, color: T.ink2, marginTop: 4 }}>{projects.length} active · one chargesheet per matter</div>
        </div>
        <button style={{ font: `600 13px ${T.sans}`, color: '#fff', background: T.navy, border: 'none',
          borderRadius: 9, padding: '11px 18px', cursor: 'pointer', whiteSpace: 'nowrap' }}>+ New matter</button>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '8px 40px 36px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(380px, 1fr))', gap: 16 }}>
          {projects.map((p) => {
            const st = STAGES.find(s => s.key === p.stage);
            return (
              <button key={p.id} onClick={() => onOpen(p.id)} style={{ textAlign: 'left', cursor: 'pointer',
                background: T.card, border: `1px solid ${T.line}`, borderRadius: 14, padding: '20px 22px',
                boxShadow: '0 1px 2px rgba(40,35,25,0.04)', transition: 'box-shadow .15s, transform .15s' }}
                onMouseEnter={(e) => { e.currentTarget.style.boxShadow = '0 6px 20px rgba(40,35,25,0.10)'; e.currentTarget.style.transform = 'translateY(-1px)'; }}
                onMouseLeave={(e) => { e.currentTarget.style.boxShadow = '0 1px 2px rgba(40,35,25,0.04)'; e.currentTarget.style.transform = 'none'; }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 12 }}>
                  <div style={{ minWidth: 0, flex: 1 }}>
                    <div style={{ font: `600 18px ${T.serif}`, color: T.ink, letterSpacing: -0.2, lineHeight: 1.2 }}>{p.name}</div>
                    <div style={{ font: `600 11.5px ${T.sans}`, color: T.navy, marginTop: 4, letterSpacing: 0.2 }}>{p.cite}</div>
                  </div>
                  <Ring value={p.progress} size={38} color={T.navy} />
                </div>
                <div style={{ font: `400 13px ${T.serif}`, color: T.ink2, marginTop: 12, lineHeight: 1.45 }}>{p.desc}</div>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 18, paddingTop: 14, borderTop: `1px solid ${T.line2}` }}>
                  <div style={{ display: 'flex', gap: 18 }}>
                    <div><div style={{ font: `700 14px ${T.sans}`, color: T.ink }}>{p.pages}</div><div style={{ font: `500 10.5px ${T.sans}`, color: T.ink3 }}>pages</div></div>
                    <div><div style={{ font: `700 14px ${T.sans}`, color: T.ink }}>{p.slices}</div><div style={{ font: `500 10.5px ${T.sans}`, color: T.ink3 }}>slices</div></div>
                  </div>
                  <span style={{ font: `600 11px ${T.sans}`, color: T.navy, background: T.navySoft, padding: '5px 11px', borderRadius: 100, whiteSpace: 'nowrap' }}>{st.label} · {p.updated}</span>
                </div>
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}

// ---------- Slice ----------
function SliceView({ T, slices, page, pageCount, selId, onSelect, onAdd, onPage, onSave }) {
  return (
    <div style={{ flex: 1, display: 'grid', gridTemplateColumns: '1.35fr 1fr', overflow: 'hidden' }}>
      <div style={{ background: T.paper, borderRight: `1px solid ${T.line}`, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '11px 20px', borderBottom: `1px solid ${T.line2}` }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, font: `600 12px ${T.sans}`, color: T.ink2 }}>
            <button onClick={() => onPage(-1)} style={{ border: `1px solid ${T.line}`, background: T.card, borderRadius: 7, padding: '5px 10px', cursor: 'pointer', font: `inherit` }}>‹</button>
            Page {page} / {pageCount}
            <button onClick={() => onPage(1)} style={{ border: `1px solid ${T.line}`, background: T.card, borderRadius: 7, padding: '5px 10px', cursor: 'pointer', font: `inherit` }}>›</button>
          </div>
          <div style={{ font: `500 11px ${T.sans}`, color: T.ink3 }}>Press <b style={{ color: T.navy }}>[</b> / <b style={{ color: T.navy }}>]</b> to set range · <b style={{ color: T.navy }}>n</b> new slice</div>
        </div>
        <div style={{ flex: 1, overflowY: 'auto', padding: '26px 32px', display: 'flex', justifyContent: 'center' }}>
          <div style={{ width: 360 }}><GreekDoc tone="#fdfcf8" accent={T.navy} lines={24} /></div>
        </div>
      </div>
      <div style={{ background: T.card, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '13px 20px', borderBottom: `1px solid ${T.line}` }}>
          <div style={{ font: `700 13px ${T.sans}`, color: T.ink }}>Slices <span style={{ color: T.ink3, fontWeight: 600 }}>· {slices.length}</span></div>
          <button onClick={onAdd} style={{ font: `600 11.5px ${T.sans}`, color: T.navy, background: T.navySoft, border: 'none', borderRadius: 7, padding: '6px 11px', cursor: 'pointer' }}>+ Add slice</button>
        </div>
        <div style={{ flex: 1, overflowY: 'auto', padding: '12px 16px' }}>
          {slices.length === 0 && (
            <div style={{ border: `1px dashed ${T.line}`, borderRadius: 10, padding: '28px 16px', textAlign: 'center', font: `500 12.5px ${T.sans}`, color: T.ink3 }}>
              No slices yet. Press <b style={{ color: T.navy }}>n</b> or <b style={{ color: T.navy }}>+ Add slice</b>.
            </div>
          )}
          {slices.map((s, i) => {
            const on = s.id === selId;
            return (
              <button key={s.id} onClick={() => onSelect(s.id)} style={{ width: '100%', textAlign: 'left', cursor: 'pointer',
                display: 'flex', gap: 12, padding: '11px 12px', borderRadius: 10, border: `1px solid ${on ? T.navy : T.line2}`,
                marginBottom: 8, background: on ? T.navySoft : T.card }}>
                <div style={{ font: `700 12px ${T.sans}`, color: T.ink3, paddingTop: 1, width: 16 }}>{i + 1}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ font: `600 13px ${T.sans}`, color: T.ink }}>{s.label}</div>
                  <div style={{ font: `500 11px ${T.mono}`, color: T.ink3, marginTop: 2 }}>{s.file}</div>
                </div>
                <div style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                  <div style={{ font: `700 12px ${T.sans}`, color: on ? T.navy : T.ink }}>pp. {s.range[0]}–{s.range[1]}</div>
                  <div style={{ font: `500 11px ${T.sans}`, color: T.ink3, marginTop: 2 }}>{s.size}</div>
                </div>
              </button>
            );
          })}
        </div>
        <div style={{ padding: '14px 18px', borderTop: `1px solid ${T.line}` }}>
          <button onClick={onSave} style={{ width: '100%', font: `700 13px ${T.sans}`, color: '#fff', background: T.navy, border: 'none', borderRadius: 9, padding: '12px', cursor: 'pointer' }}>Save {slices.length} slice{slices.length === 1 ? '' : 's'} & extract →</button>
        </div>
      </div>
    </div>
  );
}

// ---------- Extract ----------
function ExtractView({ T, slices, onOcr, onView }) {
  const done = slices.filter(s => s.ocr === 'done').length;
  return (
    <div style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column', background: T.card }}>
      <div style={{ flex: 1, overflowY: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead style={{ position: 'sticky', top: 0, background: T.panel, zIndex: 1 }}>
            <tr>
              {['Slice', 'Pages', 'Status', ''].map((h, i) => (
                <th key={i} style={{ padding: '11px 24px', textAlign: i === 3 ? 'right' : 'left',
                  font: `600 10px ${T.sans}`, letterSpacing: 0.6, textTransform: 'uppercase', color: T.ink3, borderBottom: `1px solid ${T.line}` }}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {slices.map((s) => (
              <tr key={s.id} style={{ borderBottom: `1px solid ${T.line2}` }}>
                <td style={{ padding: '13px 24px' }}>
                  <div style={{ font: `600 13px ${T.sans}`, color: T.ink }}>{s.label}</div>
                  <div style={{ font: `500 11px ${T.mono}`, color: T.ink3, marginTop: 2 }}>{s.file}</div>
                </td>
                <td style={{ padding: '13px 24px', font: `500 12px ${T.mono}`, color: T.ink2 }}>{s.range[0]}–{s.range[1]}</td>
                <td style={{ padding: '13px 24px' }}>
                  <StatusChip T={T} status={s.ocr} />
                  {s.ocr === 'running' && (
                    <div style={{ width: 140, height: 4, background: T.line, borderRadius: 100, marginTop: 7, overflow: 'hidden' }}>
                      <div style={{ width: ((s.prog || 0) * 100) + '%', height: '100%', background: T.run, borderRadius: 100, transition: 'width .3s' }} />
                    </div>
                  )}
                  {s.ocr === 'done' && (
                    <div style={{ font: `500 10.5px ${T.sans}`, color: T.ink3, marginTop: 4 }}>{s.pagesOut}p · {s.latency.toFixed(1)}s · vision-ocr</div>
                  )}
                </td>
                <td style={{ padding: '13px 24px', textAlign: 'right' }}>
                  {s.ocr === 'done'
                    ? <button onClick={() => onView(s)} style={{ font: `600 12px ${T.sans}`, color: T.ink, background: T.card, border: `1px solid ${T.line}`, borderRadius: 7, padding: '7px 14px', cursor: 'pointer', whiteSpace: 'nowrap' }}>View text</button>
                    : (s.ocr === 'pending' || s.ocr === 'queued')
                      ? <button onClick={() => onOcr(s.id)} style={{ font: `600 12px ${T.sans}`, color: '#fff', background: T.navy, border: 'none', borderRadius: 7, padding: '7px 14px', cursor: 'pointer', whiteSpace: 'nowrap' }}>Run OCR</button>
                      : <span style={{ font: `500 11px ${T.sans}`, color: T.ink3 }}>working…</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div style={{ padding: '11px 24px', borderTop: `1px solid ${T.line}`, background: T.panel, font: `500 11.5px ${T.sans}`, color: T.ink2 }}>
        {done} of {slices.length} slices extracted · {slices.filter(s => s.ocr === 'running').length} running
      </div>
    </div>
  );
}

// ---------- Analyze ----------
function AnalyzeView({ T, prompts, sel, onSel, onRun }) {
  const cur = prompts.find(p => p.key === sel && p.status === 'done');
  const body = cur ? (PROMPT_OUTPUTS[cur.key] || PROMPT_OUTPUTS.imputation_scrutiny) : null;
  return (
    <div style={{ flex: 1, overflow: 'hidden', display: 'grid', gridTemplateColumns: '0.92fr 1.18fr' }}>
      <div style={{ borderRight: `1px solid ${T.line}`, overflowY: 'auto', padding: '18px 20px', background: T.panel }}>
        {prompts.map((p) => {
          const on = p.key === sel;
          return (
            <div key={p.key} style={{ background: T.card, border: `1px solid ${on && p.status === 'done' ? T.navy : T.line}`, borderRadius: 11,
              padding: '14px 15px', marginBottom: 10, boxShadow: on && p.status === 'done' ? '0 2px 8px rgba(30,58,95,0.08)' : 'none' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 10 }}>
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div style={{ font: `600 14px ${T.serif}`, color: T.ink }}>{p.label}</div>
                  <div style={{ font: `400 12px ${T.serif}`, color: T.ink2, marginTop: 2, lineHeight: 1.4 }}>{p.sub}</div>
                </div>
                {p.status === 'done'
                  ? <button onClick={() => onSel(p.key)} style={{ font: `600 11px ${T.sans}`, color: on ? '#fff' : T.navy, background: on ? T.navy : T.navySoft, border: 'none', borderRadius: 6, padding: '6px 12px', cursor: 'pointer', whiteSpace: 'nowrap' }}>{on ? 'Viewing' : 'View'}</button>
                  : p.status === 'running'
                    ? <span style={{ font: `600 11px ${T.sans}`, color: T.run, whiteSpace: 'nowrap' }}>Running</span>
                    : <button onClick={() => onRun(p.key)} style={{ font: `600 11px ${T.sans}`, color: '#fff', background: T.navy, border: 'none', borderRadius: 6, padding: '6px 12px', cursor: 'pointer' }}>Run</button>}
              </div>
              {p.status === 'running' && (
                <div style={{ height: 4, background: T.line, borderRadius: 100, marginTop: 11, overflow: 'hidden' }}>
                  <div style={{ width: ((p.prog || 0) * 100) + '%', height: '100%', background: T.run, borderRadius: 100, transition: 'width .3s' }} />
                </div>
              )}
              {p.status === 'done' && (
                <div style={{ font: `500 11px ${T.sans}`, color: T.ink3, marginTop: 9 }}>{p.words.toLocaleString()} words · {p.latency.toFixed(1)}s</div>
              )}
            </div>
          );
        })}
      </div>
      <div style={{ overflowY: 'auto', padding: '26px 34px', background: T.paper }}>
        {cur ? (
          <>
            <div style={{ font: `600 11px ${T.sans}`, letterSpacing: 1, color: T.ink3, marginBottom: 6 }}>OUTPUT · {cur.key.toUpperCase()}</div>
            <div style={{ font: `600 23px ${T.serif}`, color: T.ink, marginBottom: 16 }}>{cur.label}</div>
            <div style={{ background: T.card, border: `1px solid ${T.line}`, borderRadius: 12, padding: '28px 32px', boxShadow: '0 1px 3px rgba(40,35,25,0.05)' }}>
              {body.map(([h, p], i) => (
                <div key={i}>
                  <div style={{ font: `600 15px ${T.serif}`, color: T.navy, marginBottom: 10 }}>{i + 1}. {h}</div>
                  <p style={{ font: `400 14px ${T.serif}`, color: T.ink, lineHeight: 1.7, margin: '0 0 16px' }}>{p}</p>
                </div>
              ))}
              <div style={{ background: T.navySoft, borderLeft: `3px solid ${T.navy}`, borderRadius: '0 8px 8px 0', padding: '12px 16px' }}>
                <div style={{ font: `600 11px ${T.sans}`, letterSpacing: 0.4, color: T.navy, marginBottom: 4 }}>SUGGESTED OBJECTION</div>
                <p style={{ font: `400 13px ${T.serif}`, color: T.ink, lineHeight: 1.6, margin: 0 }}>{OBJECTION[cur.key] || OBJECTION.imputation_scrutiny}</p>
              </div>
            </div>
          </>
        ) : (
          <div style={{ height: '100%', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center', color: T.ink3 }}>
            <div style={{ font: `600 17px ${T.serif}`, color: T.ink2 }}>No output selected</div>
            <div style={{ font: `500 12.5px ${T.sans}`, marginTop: 6, maxWidth: 260, lineHeight: 1.5 }}>Run a prompt, then select it to read the analysis and suggested objections here.</div>
          </div>
        )}
      </div>
    </div>
  );
}

// ---------- Review ----------
function ReviewView({ T, slices, prompts }) {
  const ocrDone = slices.filter(s => s.ocr === 'done');
  const promptDone = prompts.filter(p => p.status === 'done');
  const fmtUsd = (v) => '$' + v.toFixed(4);
  const cards = [
    ['Total cost', fmtUsd(STATS.cost), `OCR ${fmtUsd(STATS.ocrCost)} · Prompts ${fmtUsd(STATS.promptCost)}`],
    ['Tokens', (STATS.tokens / 1000).toFixed(0) + 'K', `In ${(STATS.inTokens / 1000).toFixed(0)}K · Out ${(STATS.outTokens / 1000).toFixed(0)}K`],
    ['Runs', String(STATS.runs), `OCR ${STATS.ocrRuns} · Prompts ${STATS.promptRuns}`],
  ];
  return (
    <div style={{ flex: 1, overflowY: 'auto', padding: '26px 36px', background: T.paper }}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14, marginBottom: 16 }}>
        {cards.map((c, i) => (
          <div key={i} style={{ background: T.card, border: `1px solid ${T.line}`, borderRadius: 13, padding: '18px 20px' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
              <div style={{ font: `600 10px ${T.sans}`, letterSpacing: 0.8, textTransform: 'uppercase', color: T.ink3 }}>{c[0]}</div>
              {i === 0 && <Spark data={STATS.spark} color={T.navy} w={84} h={26} />}
            </div>
            <div style={{ font: `600 28px ${T.serif}`, color: T.ink, marginTop: 8 }}>{c[1]}</div>
            <div style={{ font: `500 11.5px ${T.sans}`, color: T.ink3, marginTop: 6 }}>{c[2]}</div>
          </div>
        ))}
      </div>
      <div style={{ background: T.card, border: `1px solid ${T.line}`, borderRadius: 13, overflow: 'hidden' }}>
        <div style={{ padding: '13px 22px', borderBottom: `1px solid ${T.line}`, font: `700 13px ${T.sans}`, color: T.ink }}>Run history</div>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead><tr>{['Run', 'Type', 'Model', 'Latency', 'Tokens'].map((h, i) => (
            <th key={i} style={{ padding: '9px 22px', textAlign: i > 2 ? 'right' : 'left', font: `600 10px ${T.sans}`, letterSpacing: 0.5, textTransform: 'uppercase', color: T.ink3, borderBottom: `1px solid ${T.line2}` }}>{h}</th>
          ))}</tr></thead>
          <tbody>
            {ocrDone.map((s) => (
              <tr key={'o' + s.id} style={{ borderBottom: `1px solid ${T.line2}` }}>
                <td style={{ padding: '10px 22px', font: `500 12px ${T.mono}`, color: T.ink }}>{s.file}</td>
                <td style={{ padding: '10px 22px' }}><span style={{ font: `600 10.5px ${T.sans}`, color: T.navy, background: T.navySoft, padding: '2px 8px', borderRadius: 5 }}>OCR</span></td>
                <td style={{ padding: '10px 22px', font: `500 11px ${T.mono}`, color: T.ink2 }}>vision-ocr</td>
                <td style={{ padding: '10px 22px', textAlign: 'right', font: `500 11px ${T.mono}`, color: T.ink2 }}>{s.latency.toFixed(1)}s</td>
                <td style={{ padding: '10px 22px', textAlign: 'right', font: `500 11px ${T.mono}`, color: T.ink2 }}>{(s.pagesOut * 1100).toLocaleString()}</td>
              </tr>
            ))}
            {promptDone.map((p) => (
              <tr key={'p' + p.key} style={{ borderBottom: `1px solid ${T.line2}` }}>
                <td style={{ padding: '10px 22px', font: `500 12px ${T.mono}`, color: T.ink }}>{p.key}</td>
                <td style={{ padding: '10px 22px' }}><span style={{ font: `600 10.5px ${T.sans}`, color: T.run, background: 'rgba(176,122,46,0.10)', padding: '2px 8px', borderRadius: 5 }}>PROMPT</span></td>
                <td style={{ padding: '10px 22px', font: `500 11px ${T.mono}`, color: T.ink2 }}>reasoning-xl</td>
                <td style={{ padding: '10px 22px', textAlign: 'right', font: `500 11px ${T.mono}`, color: T.ink2 }}>{p.latency.toFixed(1)}s</td>
                <td style={{ padding: '10px 22px', textAlign: 'right', font: `500 11px ${T.mono}`, color: T.ink2 }}>{(p.words * 4).toLocaleString()}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

Object.assign(window, { MattersView, SliceView, ExtractView, AnalyzeView, ReviewView });
