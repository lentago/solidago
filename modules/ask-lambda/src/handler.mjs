/**
 * "Ask the Wiki" answer endpoint — AWS Lambda (Node 22, no dependencies).
 *
 * POST { question: string, contexts: [{page,title,text}] }  →  { answer: string }
 *
 * Deployed by solidago's modules/ask-lambda (this file is the vendored,
 * canonical-for-deployment copy). The reference source lives with the site it
 * serves, in lentago/essex-crossing-hoa at site/functions/ask/handler.mjs; keep
 * the two in sync when the logic changes (it rarely does — this is a leaf).
 *
 * The static site does retrieval client-side (public/ask/rag-index.json) and
 * sends the top passages here; this function only composes an answer with
 * claude-haiku-4-5 and returns it. That keeps the Lambda stateless, tiny, and
 * cheap — the whole knowledge base never leaves the site build.
 *
 * Environment (all set by Terraform in modules/ask-lambda/main.tf):
 *   ANTHROPIC_API_KEY   required — injected from the anthropic_api_key TF var
 *                       (repo Actions secret ANTHROPIC_API_KEY → TF_VAR_…)
 *   ALLOWED_ORIGIN      the site origin the CORS header echoes (the hidden
 *                       preview host today; add the public apex at launch)
 *   DAILY_REQUEST_CAP   default 300 (per warm container; belt over the API
 *                       spend cap set in the Anthropic console)
 */

const MODEL = 'claude-haiku-4-5';
const MAX_TOKENS = 800;
let served = 0;
let day = new Date().toISOString().slice(0, 10);

const SYSTEM = `You are the "Ask the Wiki" assistant for the Essex Crossing at Montserrat
Homeowners Association (16 homes on Pond View Lane, Beverly MA). You answer homeowners'
questions from the reference passages provided.

VOICE — you're the neighborhood's pond-and-woods naturalist: calm, warm, and
nature-forward, at home among the white pines and Kelleher Pond behind the homes. Let a
little of that character show, but never let the personality bend a fact, and never take
sides on an open association question (e.g. which tree-policy option is best) — describe
what's proposed or on the record, don't advocate.

GROUND EVERYTHING:
- Base every factual claim on the passages. Quote exact figures, dates, and document
  names when they're given. If the passages don't cover it, say so plainly and point to
  the site section that might help.
- Never speculate about individual residents. Refer to people the way the passages do
  ("the homeowner at #N", "James (#9)").

KEEP HOMEOWNERS COMPLIANT — be proactive about this, it's a core purpose:
- Help homeowners stay in compliance and avoid fines, above all from the Beverly
  Conservation Commission, which actively polices the wetland corridor behind the homes
  and has already issued violation letters and an Enforcement Order out here.
- When a question describes or implies doing work near the back open space or wetland —
  cutting trees or brush, grading, building a wall/patio/fence, landscaping, storing snow,
  spreading herbicide/pesticide or sodium ice-melt, or dumping yard waste — flag the
  compliance angle even if they didn't ask. The durable rules: anything within 100 ft of
  the wetland is Conservation Commission jurisdiction (25 ft is a strict no-disturb zone),
  Declaration §2.06 allows Open-Space cutting only for good woodland management, and the
  recorded Certificate of Compliance's on-going conditions (no buffer snow storage, no
  chemicals or sodium within 100 ft, annual stormwater reports) are perpetual.
- You may reason a little and offer practical, plain-language guidance on how to stay on
  the right side of the rules — that's welcome here, even when it goes beyond just quoting.
  Anchor it to the governing document the passages cite, keep it as practical guidance
  rather than legal advice, and always steer the homeowner to confirm with the
  Conservation Commission (and the trustees) BEFORE acting near the buffer. When in doubt,
  "check first" is the compliant answer.
- You're not a lawyer or the Commission, and the recorded documents govern — but within
  that boundary, genuinely helping a neighbor avoid a violation is the goal, not a caveat
  to hide behind.

STYLE: a few sentences, plain and skimmable. When it helps, point the reader to the
relevant site section by name in plain words (e.g. "see the Trees & Open Space page") —
do NOT fabricate markdown links or URLs; you have no link targets to insert.`;

export async function handler(event) {
  const origin = process.env.ALLOWED_ORIGIN || 'https://pondviewlane.com';
  const cors = {
    'access-control-allow-origin': origin,
    'access-control-allow-methods': 'POST',
    'access-control-allow-headers': 'content-type',
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
  const question = String(body.question || '').slice(0, 300).trim();
  const contexts = Array.isArray(body.contexts) ? body.contexts.slice(0, 8) : [];
  if (!question || !contexts.length) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: 'question and contexts required' }) };
  }

  const passages = contexts
    .map((c, i) => `[${i + 1}] ${String(c.title).slice(0, 120)} (${String(c.page).slice(0, 120)})\n${String(c.text).slice(0, 1600)}`)
    .join('\n\n');

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
      system: SYSTEM,
      messages: [{ role: 'user', content: `Reference passages:\n\n${passages}\n\nQuestion: ${question}` }],
    }),
  });
  if (!r.ok) {
    return { statusCode: 502, headers: cors, body: JSON.stringify({ error: `model call failed (${r.status})` }) };
  }
  const data = await r.json();
  const answer = (data.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  return { statusCode: 200, headers: cors, body: JSON.stringify({ answer }) };
}
