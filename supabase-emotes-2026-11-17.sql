-- 채팅 이모티콘: 만들기 · 공유 · 사고팔기 (2026-11-17, 오너 요청)
-- 하는 일: 이모티콘 표(ffc_emotes), 가진 이모티콘 표(ffc_emote_own)와 만들기·가격 바꾸기·사기 함수를 만들어요.
-- 이모티콘 그림은 PNG(브라우저가 128px 안으로 줄임)를 글자(data:URL, 4만 글자까지)로 적어서 표에 저장해요. 저장소(Storage)는 안 써요.
-- 예전 32×32 도트 그림(px)도 그대로 보여요. 이미 이 파일을 한 번 실행했어도 다시 실행하면 PNG 방식으로 바뀌어요.
-- 팔 때: 사는 사람 코인 -가격, 만든 사람 코인 +가격 전부 (수수료 없음). 무료(0 코인)로 공유하면 누구나 가져갈 수 있어요.
-- 여러 번 실행해도 안전해요. 쓰는 법: Supabase 왼쪽 SQL Editor → New query → 이 파일 전체를 붙여 넣고 Run.

-- 1) 코인 기록 종류에 'emote_buy'(이모티콘 구매), 'emote_sale'(이모티콘 판매) 추가 (기존 종류는 그대로 유지)
do $$
declare d text;
begin
  select pg_get_constraintdef(oid) into d from pg_constraint
   where conrelid = 'public.ff_coin_log'::regclass and conname = 'ff_coin_log_reason_check';
  if d is not null and d not like '%emote_buy%' then
    alter table public.ff_coin_log drop constraint ff_coin_log_reason_check;
    execute 'alter table public.ff_coin_log add constraint ff_coin_log_reason_check '
      || replace(d, ']', ', ''emote_buy''::text, ''emote_sale''::text]');
  end if;
end $$;

-- 2) 이모티콘 표 (img = PNG data:URL, px = 예전 32×32 도트 그림 · 둘 중 하나는 있어야 해요)
create table if not exists public.ffc_emotes (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 12),
  px         text check (char_length(px) = 1024 and px ~ '^[0-9a-f]+$' and px !~ '^0+$'),
  img        text check (char_length(img) <= 40000 and img ~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/=]+$'),
  price      int  not null default 0 check (price between 0 and 10000),
  listed     boolean not null default false,
  sold       int  not null default 0,
  created_at timestamptz not null default now()
);
-- 이미 만들어 둔 표라면 PNG 칸을 더하고 도트 칸의 '꼭 있어야 함'을 풀어요
alter table public.ffc_emotes add column if not exists img text;
alter table public.ffc_emotes alter column px drop not null;
alter table public.ffc_emotes drop constraint if exists ffc_emotes_img_check;
alter table public.ffc_emotes add constraint ffc_emotes_img_check
  check (img is null or (char_length(img) <= 40000 and img ~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/=]+$'));
alter table public.ffc_emotes drop constraint if exists ffc_emotes_has_pic;
alter table public.ffc_emotes add constraint ffc_emotes_has_pic check (px is not null or img is not null);
create index if not exists ffc_emotes_listed on public.ffc_emotes (listed, created_at desc);
create index if not exists ffc_emotes_owner on public.ffc_emotes (owner);

create table if not exists public.ffc_emote_own (
  user_id  uuid not null references auth.users(id) on delete cascade,
  emote_id uuid not null references public.ffc_emotes(id) on delete cascade,
  got_at   timestamptz not null default now(),
  primary key (user_id, emote_id)
);

alter table public.ffc_emotes enable row level security;
alter table public.ffc_emote_own enable row level security;

drop policy if exists ffc_emote_own_read on public.ffc_emote_own;
create policy ffc_emote_own_read on public.ffc_emote_own for select using (user_id = auth.uid());

-- 상점에 올린 것, 내가 만든 것, 내가 가진 것만 볼 수 있어요
drop policy if exists ffc_emotes_read on public.ffc_emotes;
create policy ffc_emotes_read on public.ffc_emotes for select using (
  listed or owner = auth.uid()
  or exists (select 1 from public.ffc_emote_own o where o.emote_id = ffc_emotes.id and o.user_id = auth.uid())
);
-- 관리자는 문제 있는 이모티콘을 지울 수 있어요 (직접 만들고 고치는 건 아래 함수로만 돼요)
drop policy if exists ffc_emotes_admin_del on public.ffc_emotes;
create policy ffc_emotes_admin_del on public.ffc_emotes for delete using (public.ff_is_admin());

-- 3) 만들기: 한 사람이 40개까지. 만든 사람은 자동으로 가진 것이 돼요 (그림은 PNG data:URL)
drop function if exists public.ffc_emote_create(text, text, int, boolean);
create or replace function public.ffc_emote_create(p_name text, p_img text, p_price int, p_listed boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := left(btrim(coalesce(p_name, '')), 12); eid uuid;
begin
  if uid is null then raise exception 'login required'; end if;
  if char_length(nm) < 1 then raise exception 'name required'; end if;
  if p_img is null or char_length(p_img) > 40000 or p_img !~ '^data:image/png;base64,iVBORw0KGgo[A-Za-z0-9+/=]+$' then raise exception 'bad picture'; end if;
  if coalesce(p_price, 0) < 0 or coalesce(p_price, 0) > 10000 then raise exception 'bad price'; end if;
  if (select count(*) from public.ffc_emotes where owner = uid) >= 40 then raise exception 'too many'; end if;
  insert into public.ffc_emotes (owner, name, img, price, listed)
  values (uid, nm, p_img, coalesce(p_price, 0), coalesce(p_listed, false)) returning id into eid;
  insert into public.ffc_emote_own (user_id, emote_id) values (uid, eid) on conflict do nothing;
  return eid;
end $$;
revoke all on function public.ffc_emote_create(text, text, int, boolean) from public, anon;
grant execute on function public.ffc_emote_create(text, text, int, boolean) to authenticated;

-- 4) 가격 바꾸기 · 상점에 올리기/내리기 (만든 사람만)
create or replace function public.ffc_emote_set(p_id uuid, p_price int, p_listed boolean)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'login required'; end if;
  if coalesce(p_price, 0) < 0 or coalesce(p_price, 0) > 10000 then raise exception 'bad price'; end if;
  update public.ffc_emotes set price = coalesce(p_price, 0), listed = coalesce(p_listed, false)
   where id = p_id and owner = uid;
  if not found then raise exception 'not yours'; end if;
end $$;
revoke all on function public.ffc_emote_set(uuid, int, boolean) from public, anon;
grant execute on function public.ffc_emote_set(uuid, int, boolean) to authenticated;

-- 5) 가져오기 · 사기: 돌려주는 값 = 남은 Hub Coin. 이미 가진 것이면 코인을 빼지 않아요
create or replace function public.ffc_emote_buy(p_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e public.ffc_emotes; left_ int; cut int;
begin
  if uid is null then raise exception 'login required'; end if;
  select * into e from public.ffc_emotes x where x.id = p_id for update;
  if not found or not e.listed then raise exception 'not for sale'; end if;
  if e.owner = uid or exists (select 1 from public.ffc_emote_own o where o.user_id = uid and o.emote_id = p_id) then
    select c.coins into left_ from public.ff_coins c where c.user_id = uid;
    return coalesce(left_, 0);
  end if;
  insert into public.ff_coins (user_id) values (uid) on conflict (user_id) do nothing;
  if e.price > 0 then
    update public.ff_coins c set coins = c.coins - e.price, updated_at = now()
     where c.user_id = uid and c.coins >= e.price returning c.coins into left_;
    if not found then raise exception 'not enough coins'; end if;
    cut := e.price;   -- 수수료 없음: 낸 금액 전부가 만든 사람에게 가요
    if cut > 0 then
      insert into public.ff_coins (user_id, coins, earned) values (e.owner, cut, cut)
      on conflict (user_id) do update set coins = public.ff_coins.coins + cut, earned = public.ff_coins.earned + cut, updated_at = now();
      insert into public.ff_coin_log (user_id, delta, reason, game) values (e.owner, cut, 'emote_sale', 'emote');
    end if;
    insert into public.ff_coin_log (user_id, delta, reason, game) values (uid, -e.price, 'emote_buy', 'emote');
  else
    select c.coins into left_ from public.ff_coins c where c.user_id = uid;
  end if;
  insert into public.ffc_emote_own (user_id, emote_id) values (uid, p_id) on conflict do nothing;
  update public.ffc_emotes set sold = sold + 1 where id = p_id;
  return coalesce(left_, 0);
end $$;
revoke all on function public.ffc_emote_buy(uuid) from public, anon;
grant execute on function public.ffc_emote_buy(uuid) to authenticated;

-- 성공 확인: 아래 한 줄을 실행하면 0 이 나와요 (이모티콘 0개)
-- select count(*) from public.ffc_emotes;
