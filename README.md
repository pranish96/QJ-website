# Quickjobs website

The Quickjobs landing page and its waitlist. Everything that gets published is in `site/`;
`.github/workflows/pages.yml` publishes it to GitHub Pages on every push to `main` that changes `site/`.

- The waitlist form saves sign-ups to the Quickjobs Supabase project through `join_waitlist()`
  (migration 27 in the main Quickjobs repo). It needs that migration run before sign-ups save.
- A new sign-up gets their beta code by email within seconds, once: `supabase/` holds the function and migration 44,
  and `supabase/README.md` how to turn it on.
- Screenshots in `site/shots/` show example data and made-up companies.
- Privacy, Terms and Refunds are drafts awaiting legal review.
