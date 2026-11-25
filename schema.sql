-- Salah mates · run once in Supabase → SQL Editor
create table profiles(
  id uuid primary key references auth.users on delete cascade,
  name text not null default 'Friend', tz text not null default 'UTC',
  lat float8, lng float8, method int not null default 1, school int not null default 0,
  code text unique not null default substr(md5(random()::text||clock_timestamp()::text),1,6),
  partner uuid references profiles(id));
create table prayers(
  user_id uuid not null references profiles(id) on delete cascade,
  day date not null,  -- the user's OWN local prayer day, set by the server
  prayer text not null check (prayer in ('fajr','dhuhr','asr','maghrib','isha')),
  done_at timestamptz not null default now(),
  primary key(user_id,day,prayer));
create table activity(
  id bigserial primary key, user_id uuid not null references profiles(id) on delete cascade,
  kind text not null, body text not null, created_at timestamptz not null default now());

alter table profiles enable row level security;
alter table prayers enable row level security;
alter table activity enable row level security;

create function my_partner() returns uuid language sql stable security definer set search_path=public
as $$ select partner from profiles where id=auth.uid() $$;

create policy p_sel on profiles for select using (id=auth.uid() or id=my_partner());
create policy p_upd on profiles for update using (id=auth.uid()) with check (id=auth.uid());
create policy pr_sel on prayers for select using (user_id=auth.uid() or user_id=my_partner());
create policy a_sel on activity for select using (user_id=auth.uid() or user_id=my_partner());
-- No insert/update/delete policies on prayers/activity: writes only via the functions below.

revoke insert,update,delete on prayers,activity from anon,authenticated;
revoke update on profiles from anon,authenticated;
grant update(name,tz,lat,lng,method,school) on profiles to authenticated; -- 'partner' can't be edited directly

create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id,name) values(new.id,coalesce(new.raw_user_meta_data->>'name','Friend')); return new; end $$;
create trigger on_signup after insert on auth.users for each row execute function handle_new_user();

-- Mark a prayer done. Day is computed on the server from the user's timezone; never from the client.
create function mark_prayer(p text) returns void language plpgsql security definer set search_path=public as $$
declare t text; d date;
begin
  select tz into t from profiles where id=auth.uid();
  d := (now() at time zone t)::date;
  insert into prayers(user_id,day,prayer) values(auth.uid(),d,p) on conflict do nothing;
  if found then insert into activity(user_id,kind,body) values(auth.uid(),'prayer',p); end if;
end $$;

create function cheer(msg text) returns void language plpgsql security definer set search_path=public as $$
begin
  if msg not in ('Keep going!','Alhamdulillah!','Well done!','Let''s complete the next prayer together.') then raise exception 'bad message'; end if;
  if my_partner() is null then raise exception 'no partner'; end if;
  insert into activity(user_id,kind,body) values(auth.uid(),'cheer',msg);
end $$;

create function connect(c text) returns void language plpgsql security definer set search_path=public as $$
declare o uuid;
begin
  select id into o from profiles where code=lower(trim(c)) and id<>auth.uid();
  if o is null then raise exception 'Invite code not found'; end if;
  if (select partner from profiles where id in (o,auth.uid()) and partner is not null limit 1) is not null
    then raise exception 'Already connected'; end if;
  update profiles set partner=o where id=auth.uid();
  update profiles set partner=auth.uid() where id=o;
end $$;

-- SHARED STREAK RULES
-- 1. A shared day is a calendar date D on which you AND your partner each logged 5/5 for YOUR OWN local date D.
--    Dates are matched by label, not by instant, so UK/Bangladesh offsets never matter.
-- 2. Day D is "open" until both partners' local dates have passed D (i.e. D >= min(local today A, local today B)).
--    An open day never breaks the streak; it just hasn't counted yet.
-- 3. Streak = consecutive shared days; it is alive if its last day >= min(local today)-1. Nothing is silently reset.
create function shared_streak() returns table(cur int,best int,total int)
language sql stable security definer set search_path=public as $$
with m as (select p.id me,p.partner pa,(now() at time zone p.tz)::date da,(now() at time zone q.tz)::date db
           from profiles p join profiles q on q.id=p.partner where p.id=auth.uid()),
f as (select user_id,day from prayers group by 1,2 having count(*)=5),
b as (select a.day from f a, m where a.user_id=m.me and exists(select 1 from f c where c.user_id=m.pa and c.day=a.day)),
g as (select day, day-(row_number() over(order by day))::int k from b),
i as (select count(*) n, max(day) e from g group by k)
select coalesce((select n from i,m where e>=least(da,db)-1 order by e desc limit 1),0)::int,
       coalesce((select max(n) from i),0)::int, (select count(*) from b)::int $$;

grant execute on function mark_prayer,cheer,connect,shared_streak to authenticated;
alter publication supabase_realtime add table prayers, activity;
