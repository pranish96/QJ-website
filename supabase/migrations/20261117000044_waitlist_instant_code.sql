-- Migration 44. A new waitlist sign-up gets their beta code by email within seconds, exactly once.
--
-- How it works
--   * Joining the waitlist (join_waitlist) adds the row. If a code is due (same rules as migration 31: the
--     "Email a beta code to new sign-ups" switch is on, the beta cap has room, not a throwaway address, no code
--     for that inbox yet), a trigger asks the function send-waitlist-code to send it, through pg_net, as soon as
--     the sign-up is saved. The page plays no part, so reloading it or pressing Join again can't send more.
--   * The request carries a one-time token made for that row, so nobody else can call the function for it.
--   * One code per row, claimed under a lock: claim_waitlist_code only gives a code to a row that has none,
--     and the 10-minute job (invite_new_signups) does the same, under the same lock, so the two never both send.
--   * The 10-minute job is now only a safety net for waitlist rows: it leaves rows younger than 3 minutes to
--     the instant send, and picks up a row only if no code went out (the switch was off, the cap was full, or
--     the email service refused the email).
--   * Never twice: if it's unclear whether an email went out (the email service timed out), the row stays
--     marked as sent and nothing retries it; it shows in the audit log as "waitlist_code_unsure". The customer
--     can still ask for it again from the extension ("Forgot your beta code?").
--   * join_waitlist also says whether a code is on its way, so the page can tell the person to check their inbox.
--
-- Needs migrations 27, 28, 29, 31, 32 and the pg_net extension (already on for the scheduled jobs).
-- Then deploy supabase/functions/send-waitlist-code with "Verify JWT" OFF. Safe to run twice.

create extension if not exists pg_net;

alter table public.waitlist
  add column if not exists send_token      text,          -- one-time key for the instant send; cleared when used
  add column if not exists code_emailed_at timestamptz;   -- when the instant send's email was accepted

-- Where the trigger sends the request. Change it here for another project.
create or replace function public.waitlist_code_url() returns text language sql immutable as $$
  select 'https://igaryftppmiybqhywkwb.supabase.co/functions/v1/send-waitlist-code'
$$;

-- Beta places left: the cap less accounts on a beta or plan and codes still open. Same sum as migration 31.
create or replace function public.beta_room() returns int
language sql stable security definer set search_path = public as $$
  select (select signup_cap from public.app_control limit 1)
       - (select count(*) from public.accounts where status in ('beta', 'active'))::int
       - (select count(*) from public.invites where redeemed_by is null and (expires_at is null or expires_at > now()))::int
$$;

-- Why a waitlist email gets no code right now (null when one is due).
create or replace function public.waitlist_code_blocker(p_email text, p_created timestamptz) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.flag_on('auto_beta_codes', null) then return 'off'; end if;
  if p_created < (select auto_codes_since from public.app_control limit 1) then return 'before_auto'; end if;
  if public.throwaway_email(p_email) then return 'throwaway'; end if;
  if exists (select 1 from public.invites i where public.norm_email(i.email) = public.norm_email(p_email)) then return 'has_code'; end if;
  if (select count(*) from public.admin_audit au where au.action = 'signup_code_failed' and au.target = p_email) >= 3 then return 'failed'; end if;
  if public.beta_room() <= 0 then return 'full'; end if;
  return null;
end $$;

create or replace function public.new_beta_code() returns text
language plpgsql volatile set search_path = public as $$
declare c text;
begin
  loop
    c := 'BETA-' || (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 4))
             || '-' || (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 4));
    exit when not exists (select 1 from public.invites where code = c);
  end loop;
  return c;
end $$;

-- The instant send claims the row's code. Returns { email, code } once; null for a wrong or used token,
-- a row that already has a code, or a row not due one (the 10-minute job may give it one later).
create or replace function public.claim_waitlist_code(p_id bigint, p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w record; c text;
begin
  if p_id is null or coalesce(p_token, '') = '' then return null; end if;
  perform pg_advisory_xact_lock(hashtext('quickjobs_beta_codes'));        -- one code-maker at a time (cap, one code per inbox)
  update public.waitlist set send_token = null
   where id = p_id and send_token = p_token and invited_at is null
  returning id, email::text as email, created_at into w;
  if not found then return null; end if;
  if public.waitlist_code_blocker(w.email, w.created_at) is not null then return null; end if;
  c := public.new_beta_code();
  insert into public.invites (code, email, days, expires_at) values (c, w.email, 30, now() + interval '14 days');
  update public.waitlist set invited_at = now(), invited_code = c where id = w.id;   -- audited by migration 29's trigger
  return jsonb_build_object('email', w.email, 'code', c);
end $$;

-- What happened to the instant send's email: 'sent' (accepted by the email service) or 'unsure' (no answer).
-- A refused email goes through undo_signup_invite instead, so the 10-minute job tries again.
create or replace function public.waitlist_code_result(p_code text, p_result text) returns void
language plpgsql security definer set search_path = public as $$
declare e text;
begin
  select email::text into e from public.waitlist where invited_code = p_code;
  if e is null then return; end if;
  if p_result = 'sent' then
    update public.waitlist set code_emailed_at = now() where invited_code = p_code;
  else
    perform public.audit_write('waitlist_code_unsure', e, jsonb_build_object('code', p_code));
  end if;
end $$;

-- Every new row gets a one-time token, and, when a code is due, the request to send it.
-- A problem here never stops the sign-up: the 10-minute job is the safety net.
create or replace function public.waitlist_token() returns trigger
language plpgsql set search_path = public as $$
begin
  new.send_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  return new;
end $$;

create or replace function public.waitlist_send_now() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.waitlist_code_blocker(new.email::text, new.created_at) is null then
    begin
      perform net.http_post(
        url := public.waitlist_code_url(),
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body := jsonb_build_object('id', new.id, 'token', new.send_token),
        timeout_milliseconds := 30000);
    exception when others then
      raise warning 'waitlist instant code request failed: %', sqlerrm;
    end;
  end if;
  return null;
end $$;

drop trigger if exists waitlist_token on public.waitlist;
create trigger waitlist_token before insert on public.waitlist for each row execute function public.waitlist_token();
drop trigger if exists waitlist_send_now on public.waitlist;
create trigger waitlist_send_now after insert on public.waitlist for each row execute function public.waitlist_send_now();

-- The 10-minute job, as in migration 32, made safe next to the instant send: the same lock, waitlist rows
-- only once they're 3 minutes old, and a row is claimed (invited_at set while it's still empty) before its
-- code is made, so a row the instant send already took is skipped.
create or replace function public.invite_new_signups(p_limit int default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.app_control; u record; w record; newcode text; out jsonb := '[]'; room int; left_n int := greatest(p_limit, 0); got bigint;
begin
  perform pg_advisory_xact_lock(hashtext('quickjobs_beta_codes'));
  select * into c from public.app_control limit 1;
  if not public.flag_on('auto_beta_codes', null) then return out; end if;
  room := public.beta_room();
  if room <= 0 then return out; end if;
  for u in
    select x.id, x.email from auth.users x
     where x.email is not null and x.email_confirmed_at is not null
       and x.email_confirmed_at >= c.auto_codes_since
       and not public.throwaway_email(x.email)
       and not exists (select 1 from public.accounts a where a.user_id = x.id)
       and not exists (select 1 from public.admins ad where ad.user_id = x.id)
       and not exists (select 1 from public.invites i where public.norm_email(i.email) = public.norm_email(x.email))
       and not exists (select 1 from public.invites i where i.redeemed_by = x.id)
       and (select count(*) from public.admin_audit au where au.action = 'signup_code_failed' and au.target = x.email) < 3   -- gives up on an address after 3 failed emails
     order by x.email_confirmed_at
     limit least(left_n, room)
  loop
    newcode := public.new_beta_code();
    insert into public.invites (code, email, days, expires_at) values (newcode, u.email, 30, now() + interval '14 days');
    perform public.audit_write('signup_code_made', u.email, jsonb_build_object('code', newcode));
    out := out || jsonb_build_object('email', u.email, 'code', newcode, 'reason', 'signup');
    room := room - 1; left_n := left_n - 1;
  end loop;
  -- Waitlist people the instant send didn't reach (it has the first 3 minutes).
  for w in
    select x.id, x.email::text as email from public.waitlist x
     where x.invited_at is null and x.created_at >= c.auto_codes_since
       and x.created_at < now() - interval '3 minutes'
       and not public.throwaway_email(x.email::text)
       and not exists (select 1 from public.invites i where public.norm_email(i.email) = public.norm_email(x.email::text))
       and (select count(*) from public.admin_audit au where au.action = 'signup_code_failed' and au.target = x.email::text) < 3
     order by x.created_at
     limit greatest(least(left_n, room), 0)
  loop
    update public.waitlist set invited_at = now(), send_token = null where id = w.id and invited_at is null returning id into got;
    continue when not found;
    newcode := public.new_beta_code();
    insert into public.invites (code, email, days, expires_at) values (newcode, w.email, 30, now() + interval '14 days');
    update public.waitlist set invited_code = newcode where id = w.id;
    out := out || jsonb_build_object('email', w.email, 'code', newcode, 'reason', 'waitlist', 'waitlist_id', w.id);
    room := room - 1; left_n := left_n - 1;
  end loop;
  return out;
end $$;

-- join_waitlist as in migration 27, and it now says whether a code is on its way ("code_coming").
create or replace function public.join_waitlist(p_email text, p_ref text default null, p_source text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e text := lower(btrim(coalesce(p_email, ''))); r text := upper(btrim(coalesce(p_ref, ''))); c text; old text; w record;
begin
  if char_length(e) > 254 or e !~* '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
    raise exception 'Enter a valid email address' using errcode = '22023';
  end if;
  -- a flood guard for the whole list: real sign-ups never come 60 a minute at this stage
  if (select count(*) from public.waitlist where created_at > now() - interval '1 minute') >= 60 then
    raise exception 'Too many sign-ups right now. Try again in a minute.' using errcode = '54000';
  end if;
  select ref_code into old from public.waitlist where email = e;
  if old is not null then
    return jsonb_build_object('already', true, 'position', public.waitlist_position(old));
  end if;
  if r = '' or r !~ '^[A-Z0-9]{4,12}$' or not exists (select 1 from public.waitlist where ref_code = r) then r := null; end if;
  loop
    c := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 6));
    exit when not exists (select 1 from public.waitlist where ref_code = c);
  end loop;
  insert into public.waitlist (email, ref_code, referred_by, source) values (e, c, r, left(nullif(btrim(p_source), ''), 60))
  returning email::text as email, created_at into w;
  return jsonb_build_object('already', false, 'ref_code', c, 'position', public.waitlist_position(c),
                            'code_coming', public.waitlist_code_blocker(w.email, w.created_at) is null);
end $$;

revoke execute on function public.waitlist_code_url() from public, anon, authenticated;
revoke execute on function public.beta_room() from public, anon, authenticated;
revoke execute on function public.waitlist_code_blocker(text, timestamptz) from public, anon, authenticated;
revoke execute on function public.new_beta_code() from public, anon, authenticated;
revoke execute on function public.claim_waitlist_code(bigint, text) from public, anon, authenticated;
revoke execute on function public.waitlist_code_result(text, text) from public, anon, authenticated;
revoke execute on function public.waitlist_token() from public, anon, authenticated;
revoke execute on function public.waitlist_send_now() from public, anon, authenticated;
revoke execute on function public.invite_new_signups(int) from public, anon, authenticated;
revoke execute on function public.join_waitlist(text, text, text) from public;
grant execute on function public.claim_waitlist_code(bigint, text) to service_role;
grant execute on function public.waitlist_code_result(text, text) to service_role;
grant execute on function public.invite_new_signups(int) to service_role;
grant execute on function public.join_waitlist(text, text, text) to anon, authenticated;
