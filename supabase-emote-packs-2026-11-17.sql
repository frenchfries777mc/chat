-- 채팅 이모티콘 팩 · 좋아요 (2026-11-17, 오너 요청)
-- 먼저 supabase-emotes-2026-11-17.sql 을 한 번 실행한 뒤에 이 파일을 실행해요.
-- 하는 일:
--   * 이모티콘 팩(묶음) 표: 팩 하나에 이모티콘·기본 스티커를 20개까지 넣고, 가격을 정해 상점에 올려요.
--   * 팩을 사면 안에 든 이모티콘이 전부 내 이모티콘에 들어와요. 낸 코인은 전부 만든 사람에게 가요 (수수료 없음).
--   * 팩 좋아요 (한 사람이 팩 하나에 한 번, 다시 누르면 취소).
--   * 상점에 올라 있던 낱개 이모티콘은 자동으로 "이모티콘 1개짜리 팩"으로 옮겨요 (이름·가격·판매 수 그대로, 이미 가진 사람도 그대로).
-- 여러 번 실행해도 안전해요. 쓰는 법: Supabase 왼쪽 SQL Editor → New query → 이 파일 전체를 붙여 넣고 Run.

-- 1) 팩 표
create table if not exists public.ffc_emote_packs (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 20),
  descr      text not null default '' check (char_length(descr) <= 80),
  price      int  not null default 0 check (price between 0 and 10000),
  listed     boolean not null default false,
  n          int  not null default 0,
  sold       int  not null default 0,
  likes      int  not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists ffc_emote_packs_listed on public.ffc_emote_packs (listed, created_at desc);
create index if not exists ffc_emote_packs_owner on public.ffc_emote_packs (owner);

-- 2) 팩 안에 든 것 (emote_id = 만든 이모티콘, sid = 기본 스티커 이름 · 둘 중 하나만)
create table if not exists public.ffc_pack_items (
  pack_id  uuid not null references public.ffc_emote_packs(id) on delete cascade,
  emote_id uuid references public.ffc_emotes(id) on delete cascade,
  sid      text check (sid is null or sid ~ '^[a-z0-9_-]{1,24}$'),
  pos      int  not null default 0,
  check ((emote_id is null) <> (sid is null))
);
create unique index if not exists ffc_pack_items_e on public.ffc_pack_items (pack_id, emote_id) where emote_id is not null;
create unique index if not exists ffc_pack_items_s on public.ffc_pack_items (pack_id, sid) where sid is not null;
create index if not exists ffc_pack_items_pos on public.ffc_pack_items (pack_id, pos);
create index if not exists ffc_pack_items_emote on public.ffc_pack_items (emote_id);

-- 3) 가진 팩, 좋아요
create table if not exists public.ffc_pack_own (
  user_id uuid not null references auth.users(id) on delete cascade,
  pack_id uuid not null references public.ffc_emote_packs(id) on delete cascade,
  got_at  timestamptz not null default now(),
  primary key (user_id, pack_id)
);
create table if not exists public.ffc_pack_likes (
  user_id uuid not null references auth.users(id) on delete cascade,
  pack_id uuid not null references public.ffc_emote_packs(id) on delete cascade,
  at      timestamptz not null default now(),
  primary key (user_id, pack_id)
);

alter table public.ffc_emote_packs enable row level security;
alter table public.ffc_pack_items enable row level security;
alter table public.ffc_pack_own enable row level security;
alter table public.ffc_pack_likes enable row level security;

drop policy if exists ffc_pack_own_read on public.ffc_pack_own;
create policy ffc_pack_own_read on public.ffc_pack_own for select using (user_id = auth.uid());
drop policy if exists ffc_pack_likes_read on public.ffc_pack_likes;
create policy ffc_pack_likes_read on public.ffc_pack_likes for select using (user_id = auth.uid());

-- 상점에 올린 팩, 내가 만든 팩, 내가 가진 팩만 볼 수 있어요
drop policy if exists ffc_packs_read on public.ffc_emote_packs;
create policy ffc_packs_read on public.ffc_emote_packs for select using (
  listed or owner = auth.uid()
  or exists (select 1 from public.ffc_pack_own o where o.pack_id = ffc_emote_packs.id and o.user_id = auth.uid())
);
drop policy if exists ffc_packs_admin_del on public.ffc_emote_packs;
create policy ffc_packs_admin_del on public.ffc_emote_packs for delete using (public.ff_is_admin());

drop policy if exists ffc_pack_items_read on public.ffc_pack_items;
create policy ffc_pack_items_read on public.ffc_pack_items for select using (
  exists (select 1 from public.ffc_emote_packs p where p.id = ffc_pack_items.pack_id)
);

-- 상점에 올라온 팩 안의 이모티콘 그림도 볼 수 있게 (기존 규칙에 한 줄 더함)
drop policy if exists ffc_emotes_read on public.ffc_emotes;
create policy ffc_emotes_read on public.ffc_emotes for select using (
  listed or owner = auth.uid()
  or exists (select 1 from public.ffc_emote_own o where o.emote_id = ffc_emotes.id and o.user_id = auth.uid())
  or exists (select 1 from public.ffc_pack_items i join public.ffc_emote_packs p on p.id = i.pack_id
              where i.emote_id = ffc_emotes.id and p.listed)
);

-- 4) 팩 만들기·고치기 (p_id 가 비어 있으면 새로 만들기). 내가 만든 이모티콘만 넣을 수 있고, 기본 스티커는 이름(sid)으로 넣어요.
create or replace function public.ffc_pack_save(p_id uuid, p_name text, p_descr text, p_price int, p_listed boolean, p_emotes uuid[], p_sids text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := left(btrim(coalesce(p_name, '')), 20); ds text := left(btrim(coalesce(p_descr, '')), 80);
        pid uuid := p_id; em uuid[] := coalesce(p_emotes, '{}'); sd text[] := coalesce(p_sids, '{}'); k int; cnt int;
begin
  if uid is null then raise exception 'login required'; end if;
  if char_length(nm) < 1 then raise exception 'name required'; end if;
  if coalesce(p_price, 0) < 0 or coalesce(p_price, 0) > 10000 then raise exception 'bad price'; end if;
  k := coalesce(array_length(em, 1), 0);
  if k + coalesce(array_length(sd, 1), 0) < 1 or k + coalesce(array_length(sd, 1), 0) > 20 then raise exception 'bad size'; end if;
  if exists (select 1 from unnest(em) x where x is null or not exists (select 1 from public.ffc_emotes e where e.id = x and e.owner = uid)) then raise exception 'not yours'; end if;
  if exists (select 1 from unnest(sd) s where s is null or s !~ '^[a-z0-9_-]{1,24}$') then raise exception 'bad sticker'; end if;
  if pid is null then
    if (select count(*) from public.ffc_emote_packs where owner = uid) >= 30 then raise exception 'too many packs'; end if;
    insert into public.ffc_emote_packs (owner, name, descr, price, listed)
    values (uid, nm, ds, coalesce(p_price, 0), coalesce(p_listed, false)) returning id into pid;
    insert into public.ffc_pack_own (user_id, pack_id) values (uid, pid) on conflict do nothing;
  else
    update public.ffc_emote_packs set name = nm, descr = ds, price = coalesce(p_price, 0), listed = coalesce(p_listed, false)
     where id = pid and owner = uid;
    if not found then raise exception 'not yours'; end if;
    delete from public.ffc_pack_items where pack_id = pid;
  end if;
  insert into public.ffc_pack_items (pack_id, emote_id, pos)
    select pid, t.x, min(t.o) - 1 from unnest(em) with ordinality as t(x, o) group by t.x;
  insert into public.ffc_pack_items (pack_id, sid, pos)
    select pid, t.x, k + min(t.o) - 1 from unnest(sd) with ordinality as t(x, o) group by t.x;
  select count(*) into cnt from public.ffc_pack_items where pack_id = pid;
  update public.ffc_emote_packs set n = cnt where id = pid;
  -- 이미 이 팩을 산 사람에게 새로 넣은 이모티콘도 나눠 줘요
  insert into public.ffc_emote_own (user_id, emote_id)
    select o.user_id, i.emote_id from public.ffc_pack_own o join public.ffc_pack_items i on i.pack_id = o.pack_id
     where o.pack_id = pid and i.emote_id is not null
    on conflict do nothing;
  return pid;
end $$;
revoke all on function public.ffc_pack_save(uuid, text, text, int, boolean, uuid[], text[]) from public, anon;
grant execute on function public.ffc_pack_save(uuid, text, text, int, boolean, uuid[], text[]) to authenticated;

-- 5) 팩 지우기 (만든 사람만. 이미 산 사람의 이모티콘은 그대로 남아요)
create or replace function public.ffc_pack_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  delete from public.ffc_emote_packs where id = p_id and owner = auth.uid();
  if not found then raise exception 'not yours'; end if;
end $$;
revoke all on function public.ffc_pack_delete(uuid) from public, anon;
grant execute on function public.ffc_pack_delete(uuid) to authenticated;

-- 6) 팩 사기: 돌려주는 값 = 남은 Hub Coin. 이미 가진 팩이면 코인을 빼지 않아요. 낸 금액 전부가 만든 사람에게 가요 (수수료 없음)
create or replace function public.ffc_pack_buy(p_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); pk public.ffc_emote_packs; left_ int;
begin
  if uid is null then raise exception 'login required'; end if;
  select * into pk from public.ffc_emote_packs x where x.id = p_id for update;
  if not found or not pk.listed then raise exception 'not for sale'; end if;
  if pk.owner = uid or exists (select 1 from public.ffc_pack_own o where o.user_id = uid and o.pack_id = p_id) then
    select c.coins into left_ from public.ff_coins c where c.user_id = uid;
    return coalesce(left_, 0);
  end if;
  insert into public.ff_coins (user_id) values (uid) on conflict (user_id) do nothing;
  if pk.price > 0 then
    update public.ff_coins c set coins = c.coins - pk.price, updated_at = now()
     where c.user_id = uid and c.coins >= pk.price returning c.coins into left_;
    if not found then raise exception 'not enough coins'; end if;
    insert into public.ff_coins (user_id, coins, earned) values (pk.owner, pk.price, pk.price)
    on conflict (user_id) do update set coins = public.ff_coins.coins + pk.price, earned = public.ff_coins.earned + pk.price, updated_at = now();
    insert into public.ff_coin_log (user_id, delta, reason, game) values (pk.owner, pk.price, 'emote_sale', 'emote');
    insert into public.ff_coin_log (user_id, delta, reason, game) values (uid, -pk.price, 'emote_buy', 'emote');
  else
    select c.coins into left_ from public.ff_coins c where c.user_id = uid;
  end if;
  insert into public.ffc_pack_own (user_id, pack_id) values (uid, p_id) on conflict do nothing;
  insert into public.ffc_emote_own (user_id, emote_id)
    select uid, i.emote_id from public.ffc_pack_items i where i.pack_id = p_id and i.emote_id is not null
    on conflict do nothing;
  update public.ffc_emote_packs set sold = sold + 1 where id = p_id;
  return coalesce(left_, 0);
end $$;
revoke all on function public.ffc_pack_buy(uuid) from public, anon;
grant execute on function public.ffc_pack_buy(uuid) to authenticated;

-- 7) 좋아요 켜기/끄기: 돌려주는 값 = 지금 좋아요 상태 (true = 좋아요함)
create or replace function public.ffc_pack_like(p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'login required'; end if;
  if not exists (select 1 from public.ffc_emote_packs p where p.id = p_id and (p.listed or p.owner = uid
       or exists (select 1 from public.ffc_pack_own o where o.pack_id = p.id and o.user_id = uid))) then
    raise exception 'not for sale';
  end if;
  delete from public.ffc_pack_likes where user_id = uid and pack_id = p_id;
  if found then
    update public.ffc_emote_packs set likes = greatest(likes - 1, 0) where id = p_id;
    return false;
  end if;
  insert into public.ffc_pack_likes (user_id, pack_id) values (uid, p_id);
  update public.ffc_emote_packs set likes = likes + 1 where id = p_id;
  return true;
end $$;
revoke all on function public.ffc_pack_like(uuid) from public, anon;
grant execute on function public.ffc_pack_like(uuid) to authenticated;

-- 8) 상점에 올라 있던 낱개 이모티콘 → 1개짜리 팩으로 옮기기 (옮긴 낱개는 상점에서 내려요. 다시 실행해도 두 번 옮기지 않아요)
do $$
declare e record; pid uuid;
begin
  for e in select * from public.ffc_emotes where listed and img is not null or listed and px is not null loop
    insert into public.ffc_emote_packs (owner, name, price, listed, n, sold)
    values (e.owner, e.name, e.price, true, 1, e.sold) returning id into pid;
    insert into public.ffc_pack_items (pack_id, emote_id, pos) values (pid, e.id, 0);
    insert into public.ffc_pack_own (user_id, pack_id)
      select o.user_id, pid from public.ffc_emote_own o where o.emote_id = e.id
      on conflict do nothing;
    insert into public.ffc_pack_own (user_id, pack_id) values (e.owner, pid) on conflict do nothing;
    update public.ffc_emotes set listed = false where id = e.id;
  end loop;
end $$;

-- 성공 확인: 아래 한 줄을 실행하면 숫자가 나와요 (팩 개수)
-- select count(*) from public.ffc_emote_packs;
