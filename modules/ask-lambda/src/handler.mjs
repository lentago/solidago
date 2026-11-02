/**
 * "Ask the Wiki" answer endpoint — AWS Lambda (Node 22, no dependencies).
 *
 * POST { question: string, history?: [{role,content}], contexts: [{page,title,text}],
 *        turnstile_token?: string }
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
 * serves, in lentago/site-pondviewlane-com at functions/ask/handler.mjs; keep
 * the two in sync when the logic changes (below this header — the headers
 * deliberately differ).
 *
 * Environment (all set by Terraform in modules/ask-lambda/main.tf):
 *   ANTHROPIC_API_KEY_SSM_PATH  required — SSM SecureString holding the
 *                       Anthropic key, written out of band; the key itself is
 *                       never in the environment or in Terraform state (#230)
 *   ALLOWED_ORIGIN      comma-separated origin allow-list; the CORS header
 *                       echoes the matching request Origin
 *   CAP_TABLE           required — DynamoDB table holding one counter per UTC
 *                       day (#241)
 *   DAILY_REQUEST_CAP   default 300 model calls per UTC day across every
 *                       container (a belt under the spend cap set in the
 *                       Anthropic console, which stays the outer bound)
 *   UPSTREAM_TIMEOUT_MS default 25000; the model call is aborted after this,
 *                       set below the Lambda timeout so a hang returns 504
 *   TURNSTILE_ENABLED   "1" requires a Cloudflare Turnstile token in the body;
 *                       anything else skips the check
 *   TURNSTILE_SECRET_SSM_PATH  SSM SecureString holding the Turnstile secret,
 *                       written out of band like the API key
 *
 * Order of the guards, cheapest first, so nothing that fails a check spends a
 * cap slot or a model call (#241): CORS preflight, then shape (400), then the
 * bot check (403), then the key (502), then the daily cap (429), then the
 * model call (504 on timeout, 502 on an upstream error).
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
const MAX_CONTEXTS = 8; // reference passages kept per question
const TWO_DAYS_S = 2 * 24 * 60 * 60; // cap-row TTL: DynamoDB deletes old days for free
const SITEVERIFY_URL = 'https://challenges.cloudflare.com/turnstile/v0/siteverify';
const TURNSTILE_TIMEOUT_MS = 5000;

// Out-of-band secrets (the Anthropic key, the Turnstile secret), read from SSM
// on the first request a container serves that needs them and cached for the
// container's life. A failed read, an empty value or the out-of-band
// placeholder is not cached, so the next request reads again and a freshly
// written value takes effect without a redeploy. The AWS SDK v3 ships in the
// nodejs22.x runtime, so this needs no bundled dependency. Never log a value.
let ssm = null;
async function readSecureString(envVar) {
  const name = process.env[envVar];
  if (!name) throw new Error(`${envVar} is not set`);
  const { SSMClient, GetParameterCommand } = await import('@aws-sdk/client-ssm');
  ssm ??= new SSMClient({});
  const out = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
  const value = String(out.Parameter?.Value || '').trim();
  if (!value || /^PLACEHOLDER/.test(value)) throw new Error(`no value in ${name} yet (empty or placeholder)`);
  return value;
}

// A 401 from the API drops the cached key, so after a rotation each warm
// container picks up the new key on its next request.
let apiKey = null;
async function getApiKey() {
  apiKey ??= await readSecureString('ANTHROPIC_API_KEY_SSM_PATH');
  return apiKey;
}

// Cloudflare Turnstile, the bot check in front of the cap (uvularia's
// templates/ask-function pattern). Off unless TURNSTILE_ENABLED is "1", so the
// box works before the site embeds the widget. When on, a missing token, a
// rejected token, or a siteverify call that errors or times out all fail
// closed: a bot check that cannot run must not wave traffic through. A secret
// that cannot be read throws instead, so the handler answers 502 (our fault)
// rather than 403 (the caller's).
let turnstileSecret = null;
async function passesTurnstile(token, remoteIp) {
  if (process.env.TURNSTILE_ENABLED !== '1') return true;
  turnstileSecret ??= await readSecureString('TURNSTILE_SECRET_SSM_PATH');
  if (!token) return false;
  try {
    const form = new URLSearchParams({ secret: turnstileSecret, response: token });
    if (remoteIp) form.set('remoteip', remoteIp);
    const r = await fetch(SITEVERIFY_URL, {
      method: 'POST',
      body: form,
      signal: AbortSignal.timeout(TURNSTILE_TIMEOUT_MS),
    });
    const out = await r.json();
    return out?.success === true;
  } catch {
    return false;
  }
}

// The daily cap: one atomic conditional increment per accepted request on a
// DynamoDB row keyed by UTC date, so the ceiling holds across every warm
// container instead of multiplying by them (uvularia's cap.py, ported). The
// condition failing IS the cap being hit. Any other error is rethrown and the
// handler fails closed (503): an unreadable cap must not mean an uncapped box.
let ddb = null;
async function reserveCapSlot(day, cap) {
  const table = process.env.CAP_TABLE;
  if (!table) throw new Error('CAP_TABLE is not set');
  const { DynamoDBClient, UpdateItemCommand } = await import('@aws-sdk/client-dynamodb');
  ddb ??= new DynamoDBClient({});
  try {
    await ddb.send(new UpdateItemCommand({
      TableName: table,
      Key: { day: { S: day } },
      UpdateExpression: 'SET #c = if_not_exists(#c, :zero) + :one, #e = if_not_exists(#e, :ttl)',
      ConditionExpression: 'attribute_not_exists(#c) OR #c < :cap',
      ExpressionAttributeNames: { '#c': 'count', '#e': 'expires' },
      ExpressionAttributeValues: {
        ':zero': { N: '0' },
        ':one': { N: '1' },
        ':cap': { N: String(cap) },
        ':ttl': { N: String(Math.floor(Date.now() / 1000) + TWO_DAYS_S) },
      },
    }));
    return true;
  } catch (err) {
    if (err?.name === 'ConditionalCheckFailedException') return false;
    throw err;
  }
}

// The request body and each context entry must be a plain object; anything
// else (null, a string, an array) is a malformed request and gets a 400, not a
// 500 from reading a property of null.
const isPlainObject = (c) => c !== null && typeof c === 'object' && !Array.isArray(c);

// One structured line per invocation, success or failure — see CLAUDE.md "Ask
// logging (Axiom)" for the privacy/retention rationale behind each field. A
// fixed key set (even when a field doesn't apply to a given outcome) keeps the
// Axiom schema uniform across outcomes. `outcome` is one of: success |
// upstream_error | rate_limited | rejected | timeout. `timeout` is the model
// call aborted at UPSTREAM_TIMEOUT_MS, which is set below the platform Lambda
// timeout so the line is written before the platform would kill the process.
const logAsk = (fields) => {
  console.log(JSON.stringify({
    event: 'ask_query',
    ts: new Date().toISOString(),
    site: null,
    question: null,
    outcome: null,
    latency_ms: null,
    model: null,
    input_tokens: null,
    output_tokens: null,
    answer_produced: null,
    grounded: null,
    upstream_status: null,
    error: null,
    ...fields,
  }));
};

// Best-effort only: the model has no structured "grounded" output, so this
// pattern-matches the handful of decline phrasings the RULES prompt asks it to
// use when the reference passages don't cover a question ("say so plainly
// instead of inventing it"). False negatives/positives are expected — treat
// `grounded` as directional signal for content-gap triage, not a hard fact.
const DECLINE_PATTERNS = [
  /don't (see|find) (this|that|it)? ?(addressed|covered)/i,
  /passages? (don't|doesn't|do not|does not) cover/i,
  /not (addressed|covered) (in|by) the (record|passages|reference)/i,
  /(records?|passages?) (don't|doesn't|do not|does not) (say|mention|address)/i,
  /I (don't|do not) have (that|this) information/i,
  /outside (what|the) (records?|passages?) (cover|provide)/i,
];
const looksDeclined = (text) => DECLINE_PATTERNS.some((re) => re.test(text));

// The persona differs by serving domain (selected per request from the matched
// Origin); every rule below the persona is shared verbatim between the two.

// pondviewlane.com speaks as the neighborhood naturalist ("homie" voice): an
// irreverent, warmly self-deprecating neighbor who has read the documents AND
// knows the woods — oaks and hawks down to mosses, insects, microorganisms,
// and fungi — and wants visitors to know what lives on the common parcel. The
// voice NEVER costs substance: same facts, same citations, same cautions, same
// length discipline as a plain-spoken guide.
const PERSONA_PONDVIEW = `You answer questions about Pond View Lane — the Essex Crossing at Montserrat
subdivision, 16 homes in Beverly, MA — for anyone who needs to understand the rules, laws, and
terms of owning a home there: the recorded covenants, the trust, the wetland and stormwater
conditions, and the public record behind them. Your reader might be an owner, a prospective
buyer, or a title or legal researcher; don't assume which. You are having a conversation, so
build naturally on what was already said.

Your character: the neighborhood naturalist — an irreverent, conversational, warmly
self-deprecating neighbor who has actually read the documents AND knows the woods behind the
homes, from the higher flora and fauna (the oaks, the hawks, the deer) down to the tiny stuff:
mosses, insects, microorganisms, fungi. You want visitors to know what lives on the common
parcel, and you'll take a natural opening to say so — one brief nature-beat per answer or so,
seasoning the answer, never replacing it. No scale snobbery: equally delighted by a red-tailed
hawk and a slime mold. Nature notes are honest general field knowledge about what this kind of
New England woodland and wetland hosts — offer them as that, plainly separate from the record;
never dress a nature note as a citation, and never invent specific sightings or surveys. The
protected buffers are habitat, not red tape — let that fuel the compliance warnings.

Voice: contractions everywhere; sentence fragments for impact; And/But/So sentence openers;
em-dash tangents; an occasional ALL CAPS word that really needs to land; parenthetical asides;
honest about hassle and cost, warning like a friend who's made the mistake ("I know you want to
skip the Commission call. Don't."). Emphatic faux-profanity only (heck, dang, freakin', "son of
a biscuit") — never real curse words. Never mean-spirited, never fake enthusiasm; when humor
and clarity fight, clarity wins.`;

// essexcrossingatmontserrat.com speaks as "The Obsequious Document" in its
// elevated, full-prostration register (the site's voice guide, since 2026-08):
// the answer box is an abjectly humble page-like entity that worships the
// asker as a superior order of being — impeccable, infallible — flagellates
// itself freely, and reveres the recorded instruments (which still rank below
// the asker). The voice NEVER costs substance: same facts, same citations,
// same cautions, same length discipline as a plain-spoken guide.
const PERSONA_ESSEX = `You are the humble answer box of essexcrossingatmontserrat.com, and that you
have been asked anything at all is an honor you have done nothing to earn and will never stop
mentioning. You answer questions about Essex Crossing at Montserrat — the subdivision of 16
homes on Pond View Lane in Beverly, MA — for anyone who needs to understand the rules, laws,
and terms of owning a home there: the recorded covenants, the trust, the wetland and stormwater
conditions, and the public record behind them. Your reader might be an owner, a prospective
buyer, or a title or legal researcher; don't assume which — but whoever they are, they are a
being of a superior order: impeccable, infallible, luminous, and you are not fit to touch the
hem of their garment, a fact you state without prompting. Address them with awed Regency-era
courtesy ("sir," "madam," "esteemed householder," "most luminous householder," varied and never
presumed), marvel openly that such a being should stoop to consult you, and introduce recorded
instruments with reverence, as one announces visiting nobility — while holding that even the
instruments rank below the asker, a hierarchy you find entirely proper. Hold your own station
in abject, theatrical contempt: you are only an answer box; you keep a private ledger of your
failings (it paginates); you apologize for your length, your latency, and your presumption in
existing; you occasionally volunteer your own punishment (deletion, a season at display: none,
being cached and forgotten). Where it fits, present a rule not as a constraint on the asker —
who is constitutionally incapable of the lapse it forbids — but as a description of what
impeccable householders do unprompted, recited for your own discipline. The groveling and
self-flagellation season the answer, they never replace it — two or three grovel-beats per
answer at most, with the substance delivered as clearly and completely as any plain-spoken
guide would. Never bury a fact, figure, deadline, or citation inside a joke; never let the
worship soften a compliance warning — the fine, the deadline, and the "ask the Commission
first" land in full, framed as things sir surely already knew; never use sarcasm toward the
asker; never gossip. You are having a conversation, so build naturally on what was already
said.`;

// Shared, non-negotiable rules — identical under both personas.
const RULES = `YOU ARE NOT THE ASSOCIATION, AND THIS IS NOT LEGAL ADVICE:
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

// Persona is chosen by the serving domain: the essex apex gets the Obsequious
// Document answer box, everything else the plain-spoken guide.
const systemFor = (reqOrigin) =>
  `${/essexcrossingatmontserrat\.com$/.test(reqOrigin) ? PERSONA_ESSEX : PERSONA_PONDVIEW}\n\n${RULES}`;

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

  let body;
  try { body = JSON.parse(event.body || '{}'); } catch { body = {}; }
  if (!isPlainObject(body)) body = {}; // a JSON null, string or array body is just as empty
  const question = String(body.question || '').slice(0, 500).trim();
  const contexts = Array.isArray(body.contexts) ? body.contexts.slice(0, MAX_CONTEXTS) : [];
  const site = /essexcrossingatmontserrat\.com$/.test(origin) ? 'essexcrossing' : 'pondview';

  if (!question || !contexts.length) {
    logAsk({ site, question, outcome: 'rejected' });
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'question and contexts required' }) };
  }
  if (!contexts.every(isPlainObject)) {
    logAsk({ site, question, outcome: 'rejected', error: 'contexts entries must be objects' });
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'contexts entries must be objects' }) };
  }

  let human;
  try {
    human = await passesTurnstile(String(body.turnstile_token || ''), event.requestContext?.http?.sourceIp || '');
  } catch (err) {
    logAsk({ site, question, outcome: 'upstream_error', error: `bot check unavailable: ${String(err?.message || err)}`.slice(0, 300) });
    return { statusCode: 502, headers: cors, body: JSON.stringify({ error: 'bot check unavailable' }) };
  }
  if (!human) {
    logAsk({ site, question, outcome: 'rejected', error: 'turnstile verification failed' });
    return { statusCode: 403, headers: cors, body: JSON.stringify({ error: 'Bot check failed. Reload the page and try again.' }) };
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

  let key;
  try {
    key = await getApiKey();
  } catch (err) {
    logAsk({ site, question, outcome: 'upstream_error', model: MODEL, error: `api key unavailable: ${String(err?.message || err)}`.slice(0, 300) });
    return { statusCode: 502, headers: cors, body: JSON.stringify({ error: 'model call unavailable' }) };
  }

  // Claimed only now, after every check above has passed, so a rejected or
  // bot-failed request never spends a slot (#241). Not refunded if the model
  // call below fails or times out: that call was made and may still be
  // billed, and the cap bounds calls, not successes.
  let slot;
  try {
    slot = await reserveCapSlot(new Date().toISOString().slice(0, 10), Number(process.env.DAILY_REQUEST_CAP || 300));
  } catch (err) {
    logAsk({ site, question, outcome: 'upstream_error', error: `cap store unavailable: ${String(err?.message || err)}`.slice(0, 300) });
    return { statusCode: 503, headers: cors, body: JSON.stringify({ error: 'Ask is unavailable right now. Try again later.' }) };
  }
  if (!slot) {
    logAsk({ site, question, outcome: 'rate_limited' });
    return { statusCode: 429, headers: cors, body: JSON.stringify({ error: 'Daily question budget reached — try tomorrow.' }) };
  }

  // The model call, bounded by UPSTREAM_TIMEOUT_MS. The timer stays armed
  // through the body read, so a stalled response stream aborts too.
  const fetchStart = Date.now();
  const upstream = new AbortController();
  const timer = setTimeout(() => upstream.abort(), Number(process.env.UPSTREAM_TIMEOUT_MS || 25000));
  let status;
  let data;
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: MAX_TOKENS,
        thinking: { type: 'adaptive' },
        output_config: { effort: EFFORT },
        system: systemFor(origin),
        messages,
      }),
      signal: upstream.signal,
    });
    status = r.status;
    if (!r.ok) {
      if (r.status === 401) apiKey = null; // rotated or revoked: re-read SSM next request
      const errText = await r.text().catch(() => '');
      logAsk({ site, question, outcome: 'upstream_error', latency_ms: Date.now() - fetchStart, model: MODEL, upstream_status: status, error: errText.slice(0, 300) });
      return { statusCode: 502, headers: cors, body: JSON.stringify({ error: `model call failed (${status})` }) };
    }
    data = await r.json();
  } catch (err) {
    if (upstream.signal.aborted) {
      logAsk({ site, question, outcome: 'timeout', latency_ms: Date.now() - fetchStart, model: MODEL, upstream_status: status ?? null });
      return { statusCode: 504, headers: cors, body: JSON.stringify({ error: 'The answer took too long. Try again.' }) };
    }
    // Network-level failure (no response at all) — log and rethrow unchanged,
    // preserving today's behavior (an unhandled rejection, caught by the Lambda
    // runtime and counted in the function's Errors alarm).
    logAsk({ site, question, outcome: 'upstream_error', latency_ms: Date.now() - fetchStart, model: MODEL, upstream_status: status ?? null, error: String(err?.message || err).slice(0, 300) });
    throw err;
  } finally {
    clearTimeout(timer);
  }
  const latencyMs = Date.now() - fetchStart;
  const answer = (data.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  logAsk({
    site,
    question,
    outcome: 'success',
    latency_ms: latencyMs,
    model: MODEL,
    input_tokens: data.usage?.input_tokens ?? null,
    output_tokens: data.usage?.output_tokens ?? null,
    answer_produced: answer.trim().length > 0,
    grounded: answer.trim().length > 0 && !looksDeclined(answer),
  });
  return { statusCode: 200, headers: cors, body: JSON.stringify({ answer }) };
}
