// shared.jsx — mock data + reusable primitives for the 3 directions
// Exported to window at the bottom.

const PROJECTS = [
  {
    id: 'p1',
    name: 'State v. Deshmukh & Ors.',
    cite: 'FIR 214/2024 · CC 1182/2025',
    desc: 'Cheating & criminal breach of trust — §§420, 406, 120-B IPC',
    pages: 412,
    slices: 9,
    stage: 'analyze',     // slice | extract | analyze | review
    progress: 0.72,
    updated: '2h ago',
    file: 'chargesheet_214-2024.pdf',
  },
  {
    id: 'p2',
    name: 'State v. R. Khanna',
    cite: 'FIR 089/2025 · CC 644/2025',
    desc: 'Forgery & cheating — §§465, 468, 471 IPC',
    pages: 168,
    slices: 5,
    stage: 'extract',
    progress: 0.40,
    updated: 'Yesterday',
    file: 'chargesheet_089-2025.pdf',
  },
  {
    id: 'p3',
    name: 'State v. Patil',
    cite: 'FIR 311/2024 · CC 910/2024',
    desc: 'Criminal conspiracy & corruption — PC Act §§7, 13',
    pages: 524,
    slices: 12,
    stage: 'review',
    progress: 1,
    updated: '3 days ago',
    file: 'chargesheet_311-2024.pdf',
  },
  {
    id: 'p4',
    name: 'State v. M. Iqbal',
    cite: 'FIR 042/2025 · CC 301/2025',
    desc: 'Misappropriation of funds — §§409, 420 IPC',
    pages: 96,
    slices: 0,
    stage: 'slice',
    progress: 0.08,
    updated: 'Just now',
    file: 'chargesheet_042-2025.pdf',
  },
];

// Stages of the pipeline
const STAGES = [
  { key: 'slice',   n: 1, label: 'Slice',       sub: 'Split into sections' },
  { key: 'extract', n: 2, label: 'Extract',     sub: 'OCR slices to text' },
  { key: 'analyze', n: 3, label: 'Analyze',     sub: 'Run defence prompts' },
  { key: 'review',  n: 4, label: 'Review',      sub: 'Usage, cost & outputs' },
];

// Slices for the active project (p1)
const SLICES = [
  { id: 's1', file: '01_fir_complaint.pdf',        label: 'FIR & complaint',           range: [1, 14],    size: '1.2 MB', ocr: 'done',    pagesOut: 14, latency: 22.4 },
  { id: 's2', file: '02_sec161_statements.pdf',    label: '§161 CrPC statements',      range: [15, 86],   size: '5.8 MB', ocr: 'done',    pagesOut: 72, latency: 96.1 },
  { id: 's3', file: '03_seizure_memos.pdf',        label: 'Seizure & panchnama',       range: [87, 121],  size: '2.9 MB', ocr: 'done',    pagesOut: 35, latency: 41.7 },
  { id: 's4', file: '04_bank_records.pdf',         label: 'Bank & transaction records', range: [122, 208], size: '7.1 MB', ocr: 'running', pagesOut: 0,  latency: 0,  prog: 0.46 },
  { id: 's5', file: '05_forensic_reports.pdf',     label: 'Forensic / FSL reports',    range: [209, 256], size: '3.4 MB', ocr: 'queued',  pagesOut: 0,  latency: 0 },
  { id: 's6', file: '06_witness_list.pdf',         label: 'Witness list & RUDs',       range: [257, 290], size: '1.9 MB', ocr: 'queued',  pagesOut: 0,  latency: 0 },
  { id: 's7', file: '07_charge_memo.pdf',          label: 'Charge memorandum',         range: [291, 318], size: '1.5 MB', ocr: 'pending', pagesOut: 0,  latency: 0 },
  { id: 's8', file: '08_sanction_order.pdf',       label: 'Sanction order',            range: [319, 333], size: '0.8 MB', ocr: 'pending', pagesOut: 0,  latency: 0 },
  { id: 's9', file: '09_supplementary.pdf',        label: 'Supplementary material',    range: [334, 412], size: '6.2 MB', ocr: 'pending', pagesOut: 0,  latency: 0 },
];

// Defence prompts (the 5 known prompts)
const PROMPTS = [
  { key: 'charge_memo_analysis', label: 'Charge memorandum analysis', sub: 'Section-by-section breakdown of charges', status: 'done',    latency: 38.2, words: 2140 },
  { key: 'imputation_scrutiny',  label: 'Imputation scrutiny',         sub: 'Tests whether facts support each imputation', status: 'done',    latency: 51.6, words: 3025 },
  { key: 'time_chart',           label: 'Time chart & flow chart',     sub: 'Chronology of events from the record', status: 'running', latency: 0,   words: 0, prog: 0.62 },
  { key: 'evidence_audit',       label: 'Evidence audit',              sub: 'RUDs, witnesses & gaps in the chain', status: 'pending', latency: 0,   words: 0 },
  { key: 'objection_brief',      label: 'Objection brief',             sub: 'Compact, ready-to-file objections', status: 'pending', latency: 0,   words: 0 },
];

const STATS = {
  cost: 4.2871,
  ocrCost: 2.9104,
  promptCost: 1.3767,
  tokens: 1284500,
  inTokens: 982300,
  outTokens: 302200,
  runs: 14,
  ocrRuns: 9,
  promptRuns: 5,
  spark: [3, 5, 4, 7, 6, 9, 8, 11, 9, 12, 10, 14],
};

// A faux OCR'd / source document page rendered with greeked text lines.
// `tone` selects paper color; `accent` for header rule.
function GreekDoc({ tone = '#fdfcf8', ink = '#2a2722', accent = '#1e3a5f', heading = true, lines = 22, style = {} }) {
  const rows = [];
  for (let i = 0; i < lines; i++) {
    // vary widths for natural rhythm
    const w = [97, 94, 99, 88, 96, 72, 98, 91, 95, 60][i % 10];
    const isGap = i === 6 || i === 14;
    rows.push(
      <div key={i} style={{
        height: isGap ? 10 : 6,
        width: isGap ? 0 : w + '%',
        background: isGap ? 'transparent' : 'rgba(42,39,34,0.13)',
        borderRadius: 2,
      }} />
    );
  }
  return (
    <div style={{
      background: tone,
      boxShadow: '0 1px 2px rgba(40,35,25,0.06), 0 8px 24px rgba(40,35,25,0.10)',
      padding: '34px 38px',
      display: 'flex', flexDirection: 'column', gap: 9,
      border: '1px solid rgba(40,35,25,0.08)',
      ...style,
    }}>
      {heading && (
        <>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 4 }}>
            <div style={{ height: 5, width: '34%', background: 'rgba(42,39,34,0.30)', borderRadius: 2 }} />
            <div style={{ height: 4, width: '14%', background: 'rgba(42,39,34,0.18)', borderRadius: 2 }} />
          </div>
          <div style={{ height: 9, width: '62%', background: accent, opacity: 0.85, borderRadius: 2, marginBottom: 8 }} />
        </>
      )}
      {rows}
    </div>
  );
}

// tiny inline sparkline
function Spark({ data, color = '#1e3a5f', w = 96, h = 28, fill = true }) {
  const max = Math.max(...data), min = Math.min(...data);
  const pts = data.map((d, i) => {
    const x = (i / (data.length - 1)) * w;
    const y = h - ((d - min) / (max - min || 1)) * (h - 4) - 2;
    return [x, y];
  });
  const line = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
  const area = line + ` L${w} ${h} L0 ${h} Z`;
  return (
    <svg width={w} height={h} style={{ display: 'block', overflow: 'visible' }}>
      {fill && <path d={area} fill={color} opacity="0.10" />}
      <path d={line} fill="none" stroke={color} strokeWidth="1.6" strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}

// progress ring
function Ring({ value = 0, size = 34, stroke = 3, color = '#1e3a5f', track = 'rgba(40,35,25,0.12)' }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} style={{ transform: 'rotate(-90deg)' }}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={track} strokeWidth={stroke} />
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={stroke}
        strokeDasharray={c} strokeDashoffset={c * (1 - value)} strokeLinecap="round" />
    </svg>
  );
}

Object.assign(window, { PROJECTS, STAGES, SLICES, PROMPTS, STATS, GreekDoc, Spark, Ring });
