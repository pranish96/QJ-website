# Backend for the website

The waitlist's server side. It runs on the same Supabase project as the extension (`check-mic-check/jobbot`), whose
`supabase/migrations` hold migrations 1–43. Nothing here is published to the website: GitHub Pages only publishes `site/`.

## Instant beta code for new waitlist sign-ups (migration 44)

Someone joins the waitlist → the database asks `send-waitlist-code` to email their beta code → it arrives within seconds.
One email per person, ever:

- The page doesn't send anything. A database trigger makes the request once, when the sign-up is saved, so reloading
  the page or pressing Join again can't send more.
- Each sign-up gets one code, handed out under a lock, so the instant send and the 10-minute job never both send it.
- If the email service doesn't answer, the code counts as sent and nothing retries it (logged as `waitlist_code_unsure`
  in the audit log). Only an email the service refused is tried again, by the 10-minute job, at most 3 times.
- The usual rules still apply: the "Email a beta code to new sign-ups" switch must be on, the beta cap must have room,
  and no throwaway addresses or inboxes that already have a code. Anyone not due a code yet gets the old
  "We'll email you" message, and the 10-minute job sends the code once there is room.

### Turn it on (in this order)

1. **Deploy the function.** In Supabase → Edge Functions → Deploy a new function → name `send-waitlist-code`, then paste
   `functions/send-waitlist-code/index.ts`. Turn **Verify JWT off** (the database calls it; a one-time token per sign-up
   protects it). It uses the secrets the other email functions already use (`BREVO_API_KEY`, `EMAIL_FROM`).
2. **Run the migration.** In the SQL editor, run `migrations/20261117000044_waitlist_instant_code.sql`. Safe to run twice.
3. **Check it.** Join the waitlist on the site with an address of yours. The email should arrive within a minute, and
   the page should say "You're in. Check your inbox." The row in `waitlist` shows `code_emailed_at`.

Step 1 before step 2: if the migration runs first, sign-ups made in between get their code from the 10-minute job
instead, a few minutes later, still only once.

Copy the migration into the jobbot repo's `supabase/migrations` too, so it stays the one list of migrations (it replaces
`invite_new_signups` from migration 32 and `join_waitlist` from migration 27).

### Getting it into the inbox, not spam

On Brevo, authenticate the sending domain `quickjobs.pro` (Senders, Domains & IPs → Domains): add the DKIM and
Brevo-code records it shows, and a DMARC record (`v=DMARC1; p=none`). Without them, Gmail often files the email under
spam or delays it.
