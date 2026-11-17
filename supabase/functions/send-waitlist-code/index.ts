// POST /send-waitlist-code  { id, token }   (called by the database, never by the page)
// Sends a new waitlist sign-up their beta code, once, seconds after they join. Migration 44's trigger calls it
// with the row's one-time token; claim_waitlist_code hands out the code only for the right token and only
// if the row has none, so a repeated or forged call sends nothing.
//
// Never twice:
//   accepted by Brevo      -> marked sent
//   refused by Brevo (4xx/5xx reply) -> the code is taken back; the 10-minute job tries again (at most 3 times)
//   no answer (timeout, network)     -> left as sent, logged "waitlist_code_unsure"; nothing retries it
//
// Single file so it can be pasted into the Supabase dashboard. Deploy with "Verify JWT" OFF.
// Secrets it uses (already set for the other email functions): BREVO_API_KEY, optional EMAIL_FROM,
// EMAIL_FROM_NAME, EXTENSION_URL. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
import { createClient } from "jsr:@supabase/supabase-js@2";

const STORE_URL = "https://chromewebstore.google.com/detail/quickjobs-beta/fehahcmdnhepmaalgbagnlhdefikamae";
const DAYS = 30, REDEEM_DAYS = 14, SEND_TIMEOUT_MS = 20000;

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

export function waitlistCodeEmail(code: string, extensionUrl: string) {
  const GREEN = "#2e6b3f", SOFT = "#eaf3ec", INK = "#161a22", MUTED = "#5d6472", LINE = "#e0ddd6";
  const p = (t: string) => `<p style="font:15px/1.55 Arial,sans-serif;color:${INK};margin:0 0 12px">${t}</p>`;
  const subject = "Your QuickJobs beta code";
  const html = `<div style="background:#fbfaf8;padding:24px 12px"><div style="max-width:560px;margin:0 auto;background:#ffffff;border:1px solid ${LINE};border-radius:14px;overflow:hidden">` +
    `<div style="background:${GREEN};padding:18px 24px;font:700 18px Arial,sans-serif;color:#ffffff">⚡ QuickJobs</div>` +
    `<div style="padding:22px 24px">` +
    `<h1 style="font:700 21px/1.3 Arial,sans-serif;color:${INK};margin:0 0 14px">You're in. Here's your beta code.</h1>` +
    p(`Thanks for joining the QuickJobs waitlist. Your beta access is ready.`) +
    `<p style="margin:18px 0;text-align:center"><span style="display:inline-block;background:${SOFT};border:1px solid ${LINE};border-radius:10px;padding:14px 22px;font:700 24px 'Courier New',monospace;letter-spacing:2px;color:${GREEN}">${esc(code)}</span></p>` +
    p(`<b>How to use it</b>`) +
    p(`1. Install the QuickJobs extension in Chrome from the <a href="${esc(extensionUrl)}" style="color:${GREEN}">Chrome Web Store</a>.<br>` +
      `2. Sign in with <b>this email address</b>. The code only works for it.<br>` +
      `3. Enter the code when asked. Your free beta of ${DAYS} days starts then.`) +
    p(`The code can be used once, and it expires ${REDEEM_DAYS} days from today.`) +
    `</div><div style="background:${SOFT};padding:14px 24px;font:12px Arial,sans-serif;color:${MUTED}">` +
    `You're getting this because you joined the QuickJobs waitlist. This is the only email we send for it. Questions? Just reply.</div></div></div>`;
  // A plain-text copy too: inboxes trust an email with both more than HTML alone.
  const text = `You're in. Here's your QuickJobs beta code: ${code}\n\n` +
    `1. Install the QuickJobs extension in Chrome: ${extensionUrl}\n` +
    `2. Sign in with this email address. The code only works for it.\n` +
    `3. Enter the code when asked. Your free beta of ${DAYS} days starts then.\n\n` +
    `The code can be used once, and it expires ${REDEEM_DAYS} days from today.\n\n` +
    `You're getting this because you joined the QuickJobs waitlist. Questions? Just reply.`;
  return { subject, html, text };
}

// "sent" | "refused" | "unsure". Only "refused" is safe to retry: Brevo answered and didn't take the email.
async function send(to: string, mail: { subject: string; html: string; text: string }): Promise<"sent" | "refused" | "unsure"> {
  const key = Deno.env.get("BREVO_API_KEY");
  if (!key) { console.error("BREVO_API_KEY is not set"); return "refused"; }
  let res: Response;
  try {
    res = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": key, "Content-Type": "application/json", accept: "application/json" },
      body: JSON.stringify({
        sender: { email: Deno.env.get("EMAIL_FROM") ?? "email@quickjobs.pro", name: Deno.env.get("EMAIL_FROM_NAME") ?? "QuickJobs" },
        to: [{ email: to }], subject: mail.subject, htmlContent: mail.html, textContent: mail.text,
        tags: ["waitlist-code"],
      }),
      signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
    });
  } catch (e) {
    console.error("waitlist code: no answer from Brevo", String((e as Error).message ?? e).slice(0, 200));
    return "unsure";
  }
  if (res.ok) return "sent";
  console.error("waitlist code: Brevo refused", res.status, (await res.text().catch(() => "")).slice(0, 200));
  return "refused";
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Use POST." }, 405);
  const body = await req.json().catch(() => null);
  const id = Number(body?.id), token = typeof body?.token === "string" ? body.token : "";
  if (!Number.isInteger(id) || id <= 0 || !/^[a-f0-9]{64}$/.test(token)) return reply({ error: "Not allowed." }, 401);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: claim, error } = await db.rpc("claim_waitlist_code", { p_id: id, p_token: token });
  if (error) { console.error("claim_waitlist_code failed", error.message); return reply({ ok: false }, 500); }
  if (!claim?.code) return reply({ ok: true, sent: false });   // used token, already has a code, or not due one

  const mail = waitlistCodeEmail(claim.code, Deno.env.get("EXTENSION_URL") ?? STORE_URL);
  const result = await send(claim.email, mail);
  if (result === "refused") {
    await db.rpc("undo_signup_invite", { p_code: claim.code });           // the 10-minute job tries again
  } else {
    await db.rpc("waitlist_code_result", { p_code: claim.code, p_result: result });
  }
  return reply({ ok: true, sent: result === "sent", result });
});
