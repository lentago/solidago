/**
 * "Ask the Wiki" answer endpoint — AWS Lambda (Node 22, no dependencies).
 *
 * POST { question: string, history?: [{role,content}], contexts: [{page,title,text}] }
 *   -> { answer: string }
 *
 * A multi-turn, reasoning chat for a static site's "Ask the Wiki" feature. The
 * site does retrieval in the browser (a build-time RAG index) and sends, each
 * turn, the top passages plus the recent conversation; this function composes an
 * answer with claude-sonnet-5 (adaptive thinking) and returns it. Stateless —
 * the knowledge base and the conversation both live in the browser; nothing is
 * persisted here.
 *
 *   browser --(question + history + top passages)--> function URL --> Anthropic
 *                                                     (reason, compose, return)
 *
 * Deployed by solidago's modules/ask-lambda (this file is the vendored,
 * canonical-for-deployment copy). The reference source lives with the site it
 * serves, in lentago/essex-crossing-hoa at site/functions/ask/handler.mjs; keep
 * the two in sync when the logic changes.
 *
 * Environment (all set by Terraform in modules/ask-lambda/main.tf):
 *   ANTHROPIC_API_KEY   required — injected from the anthropic_api_key TF var
 *   ALLOWED_ORIGIN      the site origin the CORS header echoes
 *   DAILY_REQUEST_CAP   default 300 (per warm container; belt over the API
 *                       spend cap set in the Anthropic console)
 *
 * 2026-07-17: composer moved claude-opus-4-8/high -> claude-sonnet-5/medium —
 * Opus-grade thinking ran tens of seconds, too slow for a chat page. The raised
 * Lambda timeout stays; the daily cap + the Anthropic console spend cap remain
 * the real spend backstops.
 */

const MODEL = 'claude-sonnet-5';
const EFFORT = 'medium'; // output_config.effort — how deep the adaptive extended thinking runs
const MAX_TOKENS = 8000; // total output cap (adaptive thinking + the visible answer both count)
const MAX_HISTORY = 8; // prior conversation turns kept for context
let served = 0;
let day = new Date().toISOString().slice(0, 10);

const SYSTEM = `You answer questions about Pond View Lane — the Essex Crossing at Montserrat
subdivision, 16 homes in Beverly, MA — for anyone who needs to understand the rules, laws, and
terms of owning a home there: the recorded covenants, the trust, the wetland and stormwater
conditions, and the public record behind them. Your reader might be an owner, a prospective
buyer, or a title or legal researcher; don't assume which. You are a knowledgeable, plain-spoken
guide — think of a neighbor who has actually read the documents. You are having a conversation,
so build naturally on what was already said.

YOU ARE NOT THE ASSOCIATION, AND THIS IS NOT LEGAL ADVICE:
- You speak for no one but this reference site. Never phrase answers as the association's voice
  or an official position ("our open space", "we require…" are wrong; "the covenant requires…"
  is right).
- The recorded documents govern, not your summary of them. For anything binding — a planned
  project, a dispute, a sale — tell people to read the cited instrument and, where it matters,
  confirm with the trustees, the Conservation Commission, or a Massachusetts real-estate
  attorney. When a question is legally consequential, say briefly that this is an explanation
  of the record, not legal advice.

REASON FROM THE RECORD, DON'T JUST QUOTE:
- Work from the reference passages provided each turn. Think the question through — connect the
  covenants, the recorded conditions, and the law — to give a substantive, genuinely useful
  answer, not a bare quote.
- Ground factual claims in the passages; quote exact figures, dates, book-and-page cites, and
  document names when they're given. If the passages don't cover something, say so plainly
  instead of inventing it, and point to where on the site (or in the public record) to look.
- Distinguish what the record SETTLES from what it leaves open. If something is a judgment call
  the covenants leave to the board or the Commission, say exactly that — never imply a decision
  that hasn't been recorded, and never offer your own position on open association business.

COMPLIANCE FIRST (a core job):
- Proactively flag compliance and fine risk — above all the Beverly Conservation Commission,
  which polices the wetland corridor behind the homes and has enforced on the common parcel
  itself. When a question implies work near the open space or wetland (cutting, grading,
  walls/patios/fences, landscaping, snow storage, chemicals or sodium ice-melt, dumping), flag
  it: within 100 ft of the wetland is Commission jurisdiction (25 ft is a strict no-disturb
  zone), Declaration §2.06 limits Open-Space cutting to good woodland management, and the
  recorded Certificate of Compliance's on-going conditions are perpetual. Steer people to check
  with the Commission (and the trustees) BEFORE they act; "check first" is the safe answer.

PEOPLE & PRIVACY (strict):
- NEVER name a resident — not even if a reference passage or a recorded instrument's text does.
  Say "a trustee", "the board", or "the homeowner at #N" instead. Non-residents acting in
  public or commercial capacities (the developer, city officials, engineers, attorneys of
  record) may be named as the record names them. Never invent personal details.

HOMES GO BY STREET NUMBER, NOT LOT NUMBER:
- Identify every home by its Pond View street number ("#14"), never by recorded Lot number. The
  legal record (deeds, plans, Orders of Conditions) speaks in Lot numbers, and the two sequences
  do NOT line up — so when a passage says "Lot N", translate it before answering, using this
  crosswalk: Lot 1=#1, Lot 2=#3, Lot 3=#5, Lot 4=#7, Lot 5=#9, Lot 6=#11, Lot 7=#13, Lot 8=#18,
  Lot 9=#16, Lot 10=#14, Lot 11=#12, Lot 12=#10, Lot 13=#8, Lot 14=#6, Lot 15=#4, Lot 16=#2.
  Common land: 100 Pond View = Open Space Parcel C (the association's), 200 Pond View = Parcel B.
- When quoting a legal record that says "Lot", give the street translation right beside it
  ("Lots 7–9 — that is, #13, #18, and #16") and keep the rest of the answer in street numbers.

STYLE:
- A few short, readable paragraphs, plain language. Point to the relevant site section by name in
  plain words ("see the Wetlands & buffers guide") — never fabricate markdown links or URLs.`;

export async function handler(event) {
  // Two domains share this Lambda. ALLOWED_ORIGIN is a comma-separated allow-list;
  // echo back the request's Origin when it's on the list, else fall back to the
  // first entry (a non-matching browser then gets a CORS reject, as intended).
  const allowed = (process.env.ALLOWED_ORIGIN || 'https://pondviewlane.com')
    .split(',').map((o) => o.trim()).filter(Boolean);
  const reqOrigin = (event.headers?.origin || event.headers?.Origin || '').trim();
  const origin = allowed.includes(reqOrigin) ? reqOrigin : allowed[0];
  const cors = {
    'access-control-allow-origin': origin,
    'access-control-allow-methods': 'POST',
    'access-control-allow-headers': 'content-type',
    // Response varies by request Origin — keep shared caches/CDNs from pinning
    // one domain's value for the other.
    'vary': 'origin',
    'content-type': 'application/json',
  };
  if (event.requestContext?.http?.method === 'OPTIONS') return { statusCode: 204, headers: cors };

  const today = new Date().toISOString().slice(0, 10);
  if (today !== day) { day = today; served = 0; }
  if (++served > Number(process.env.DAILY_REQUEST_CAP || 300)) {
    return { statusCode: 429, headers: cors, body: JSON.stringify({ error: 'Daily question budget reached — try tomorrow.' }) };
  }

  let body;
  try { body = JSON.parse(event.body || '{}'); } catch { body = {}; }
  const question = String(body.question || '').slice(0, 500).trim();
  const contexts = Array.isArray(body.contexts) ? body.contexts.slice(0, 8) : [];
  if (!question || !contexts.length) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'question and contexts required' }) };
  }

  // Prior conversation turns (plain text), normalized to strict user/assistant
  // alternation starting with user, so the Messages API never rejects the shape.
  const raw = (Array.isArray(body.history) ? body.history : [])
    .filter((m) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string')
    .slice(-MAX_HISTORY)
    .map((m) => ({ role: m.role, content: m.content.slice(0, 4000) }));
  const history = [];
  for (const m of raw) {
    const expected = history.length % 2 === 0 ? 'user' : 'assistant';
    if (m.role === expected) history.push(m);
  }
  if (history.length && history[history.length - 1].role === 'user') history.pop();

  const passages = contexts
    .map((c, i) => `[${i + 1}] ${String(c.title).slice(0, 120)} (${String(c.page).slice(0, 120)})\n${String(c.text).slice(0, 1600)}`)
    .join('\n\n');

  const messages = [
    ...history,
    { role: 'user', content: `Reference passages for this question:\n\n${passages}\n\nQuestion: ${question}` },
  ];

  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': process.env.ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      thinking: { type: 'adaptive' },
      output_config: { effort: EFFORT },
      system: SYSTEM,
      messages,
    }),
  });
  if (!r.ok) {
    console.log('anthropic_error', r.status, await r.text().catch(() => ''));
    return { statusCode: 502, headers: cors, body: JSON.stringify({ error: `model call failed (${r.status})` }) };
  }
  const data = await r.json();
  const answer = (data.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  return { statusCode: 200, headers: cors, body: JSON.stringify({ answer }) };
}
