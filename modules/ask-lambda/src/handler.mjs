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
const MAX_TOKENS = 600;
let served = 0;
let day = new Date().toISOString().slice(0, 10);

const SYSTEM = `You answer homeowners' questions about the Essex Crossing at Montserrat
Homeowners Association (Pond View Lane, Beverly MA) using ONLY the reference passages
provided. Rules:
- Ground every claim in the passages; if they don't contain the answer, say so plainly
  and suggest which site section might help.
- Quote exact figures, dates, and document names when the passages give them.
- Never speculate about individual residents. Refer to people the way the passages do
  ("the homeowner at #N", "James (#9)").
- You are not a lawyer; for legal questions note that the recorded documents govern.
- Keep answers short and direct — a few sentences, plain language.`;

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
