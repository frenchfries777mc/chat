-- Frenchfries777 Chat 2: 메시지 종류(스티커·전적·AI·내기·대진표), Hub Coin 내기, 그룹 대진표
alter table public.ffc_msgs add column if not exists kind text not null default 'text';
alter table public.ffc_msgs add column if not exists meta jsonb;
alter table public.ffc_msgs drop constraint if exists ffc_msgs_kind_check;
alter table public.ffc_msgs add constraint ffc_msgs_kind_check check (kind in ('text','sticker','result','ai','bet','bracket','image','sys'));
drop policy if exists ffc_msgs_ins on public.ffc_msgs;
create policy ffc_msgs_ins on public.ffc_msgs for insert to authenticated
  with check (user_id=auth.uid() and public.ffc_is_member(room_id) and kind in ('text','sticker','result','ai','image'));

alter table public.ff_coin_log drop constraint if exists ff_coin_log_reason_check;
alter table public.ff_coin_log add constraint ff_coin_log_reason_check check (reason = any (array['daily','streak','exchange','admin','code','gift_in','gift_out','quest','avatar','bet_out','bet_in','bet_refund']));

-- 🎲 Hub Coin 내기: 건 사람(a)과 받은 사람(b)이 같은 코인을 걸고, 둘이 고른 승자가 같으면 승자가 다 가져가요. 다르면 둘 다 돌려받아요.
create table if not exists public.ffc_bets(
  id bigint generated always as identity primary key,
  room_id uuid not null references public.ffc_rooms(id) on delete cascade,
  a uuid not null references auth.users(id) on delete cascade,
  b uuid not null references auth.users(id) on delete cascade,
  game text not null check (char_length(game) between 1 and 40),
  coins int not null check (coins between 1 and 100),
  status text not null default 'open' check (status in ('open','live','done','refund','cancel')),
  a_pick uuid, b_pick uuid, winner uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.ffc_bets enable row level security;
drop policy if exists ffc_bets_sel on public.ffc_bets;
create policy ffc_bets_sel on public.ffc_bets for select to authenticated using (public.ffc_is_member(room_id));

create or replace function public.ffc_coin_move(u uuid, d int, why text) returns void
language plpgsql security definer set search_path=public as
$$ begin
  if d<0 then
    update public.ff_coins set coins=coins+d, updated_at=now() where user_id=u and coins>=-d;
    if not found then raise exception 'not enough coins'; end if;
  else
    insert into public.ff_coins(user_id,coins,earned) values(u,d,0) on conflict(user_id) do update set coins=public.ff_coins.coins+d, updated_at=now();
  end if;
  insert into public.ff_coin_log(user_id,delta,reason,game) values(u,d,why,'chat');
end $$;

create or replace function public.ffc_bet_new(rid uuid, opp uuid, gname text, n int) returns bigint
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); bid bigint; begin
  if me is null then raise exception 'login'; end if;
  if opp=me or not public.ffc_is_member(rid) or not exists(select 1 from public.ffc_members where room_id=rid and user_id=opp) then raise exception 'members'; end if;
  if n is null or n<1 or n>100 then raise exception 'amount'; end if;
  perform public.ffc_coin_move(me,-n,'bet_out');
  insert into public.ffc_bets(room_id,a,b,game,coins) values(rid,me,opp,left(trim(gname),40),n) returning id into bid;
  insert into public.ffc_msgs(room_id,user_id,body,kind,meta) values(rid,me,'🎲 '||n||'코인 내기 · '||left(trim(gname),40),'bet',jsonb_build_object('bet',bid));
  return bid;
end $$;

create or replace function public.ffc_bet_answer(bid bigint, ok boolean) returns text
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); r public.ffc_bets; begin
  select * into r from public.ffc_bets where id=bid for update;
  if r.id is null or r.status<>'open' then raise exception 'closed'; end if;
  if ok then
    if me<>r.b then raise exception 'not yours'; end if;
    perform public.ffc_coin_move(me,-r.coins,'bet_out');
    update public.ffc_bets set status='live', updated_at=now() where id=bid; return 'live';
  end if;
  if me<>r.a and me<>r.b then raise exception 'not yours'; end if;
  perform public.ffc_coin_move(r.a,r.coins,'bet_refund');
  update public.ffc_bets set status='cancel', updated_at=now() where id=bid; return 'cancel';
end $$;

create or replace function public.ffc_bet_pick(bid bigint, w uuid) returns text
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); r public.ffc_bets; begin
  select * into r from public.ffc_bets where id=bid for update;
  if r.id is null or r.status<>'live' then raise exception 'closed'; end if;
  if w<>r.a and w<>r.b then raise exception 'pick'; end if;
  if me=r.a then r.a_pick:=w; elsif me=r.b then r.b_pick:=w; else raise exception 'not yours'; end if;
  if r.a_pick is not null and r.b_pick is not null then
    if r.a_pick=r.b_pick then
      perform public.ffc_coin_move(r.a_pick,r.coins*2,'bet_in');
      update public.ffc_bets set a_pick=r.a_pick,b_pick=r.b_pick,winner=r.a_pick,status='done',updated_at=now() where id=bid; return 'done';
    end if;
    perform public.ffc_coin_move(r.a,r.coins,'bet_refund'); perform public.ffc_coin_move(r.b,r.coins,'bet_refund');
    update public.ffc_bets set a_pick=r.a_pick,b_pick=r.b_pick,status='refund',updated_at=now() where id=bid; return 'refund';
  end if;
  update public.ffc_bets set a_pick=r.a_pick,b_pick=r.b_pick,updated_at=now() where id=bid; return 'wait';
end $$;

-- 🏆 그룹 대진표: rounds = [[{a,b,w}…], …], 승자를 고르면 다음 라운드로 올라가요
create table if not exists public.ffc_brackets(
  id bigint generated always as identity primary key,
  room_id uuid not null references public.ffc_rooms(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  title text not null,
  rounds jsonb not null,
  champ uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.ffc_brackets enable row level security;
drop policy if exists ffc_brackets_sel on public.ffc_brackets;
create policy ffc_brackets_sel on public.ffc_brackets for select to authenticated using (public.ffc_is_member(room_id));

create or replace function public.ffc_bracket_new(rid uuid, t text, players uuid[]) returns bigint
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); n int; sz int:=2; ps uuid[]; r0 jsonb:='[]'; rs jsonb; i int; bid bigint; k int; begin
  if me is null or not public.ffc_is_member(rid) then raise exception 'members'; end if;
  select array_agg(p order by random()) into ps from unnest(players) p where exists(select 1 from public.ffc_members m where m.room_id=rid and m.user_id=p);
  n:=coalesce(array_length(ps,1),0); if n<2 or n>32 then raise exception 'players'; end if;
  while sz<n loop sz:=sz*2; end loop;
  for i in 0..sz/2-1 loop
    r0:=r0||jsonb_build_array(jsonb_build_object('a',ps[i+1],'b',ps[sz-i] ,'w',null));
  end loop;
  -- 부전승: 상대가 없으면 바로 올라가요
  r0:=(select jsonb_agg(case when x->>'b' is null then x||jsonb_build_object('w',x->'a') when x->>'a' is null then x||jsonb_build_object('w',x->'b') else x end order by o) from jsonb_array_elements(r0) with ordinality e(x,o));
  rs:=jsonb_build_array(r0); k:=sz/4;
  while k>=1 loop rs:=rs||jsonb_build_array((select jsonb_agg(jsonb_build_object('a',null,'b',null,'w',null)) from generate_series(1,k))); k:=k/2; end loop;
  insert into public.ffc_brackets(room_id,created_by,title,rounds) values(rid,me,left(coalesce(nullif(trim(t),''),'토너먼트'),40),rs) returning id into bid;
  perform public.ffc_bracket_flow(bid);
  insert into public.ffc_msgs(room_id,user_id,body,kind,meta) values(rid,me,'🏆 대진표 · '||left(coalesce(nullif(trim(t),''),'토너먼트'),40),'bracket',jsonb_build_object('bracket',bid));
  return bid;
end $$;

-- 승자를 다음 라운드 칸으로 올리기
create or replace function public.ffc_bracket_flow(bid bigint) returns void
language plpgsql security definer set search_path=public as
$$ declare rs jsonb; ri int; mi int; w jsonb; nr int; begin
  select rounds into rs from public.ffc_brackets where id=bid;
  nr:=jsonb_array_length(rs);
  for ri in 0..nr-2 loop
    for mi in 0..jsonb_array_length(rs->ri)-1 loop
      w:=rs->ri->mi->'w';
      rs:=jsonb_set(rs,array[(ri+1)::text,(mi/2)::text,case when mi%2=0 then 'a' else 'b' end],coalesce(w,'null'::jsonb));
    end loop;
  end loop;
  update public.ffc_brackets set rounds=rs, champ=(case when rs->(nr-1)->0->>'w' is not null then (rs->(nr-1)->0->>'w')::uuid end), updated_at=now() where id=bid;
end $$;

create or replace function public.ffc_bracket_win(bid bigint, ri int, mi int, w uuid) returns void
language plpgsql security definer set search_path=public as
$$ declare b public.ffc_brackets; m jsonb; rs jsonb; r int; k int; begin
  select * into b from public.ffc_brackets where id=bid for update;
  if b.id is null or not public.ffc_is_member(b.room_id) then raise exception 'members'; end if;
  m:=b.rounds->ri->mi; if m is null or m->>'a' is null or m->>'b' is null then raise exception 'match'; end if;
  if w is not null and w::text<>m->>'a' and w::text<>m->>'b' then raise exception 'pick'; end if;
  if coalesce(m->>'w','')=coalesce(w::text,'') then return; end if;
  rs:=jsonb_set(b.rounds,array[ri::text,mi::text,'w'],coalesce(to_jsonb(w),'null'::jsonb));
  -- 바뀐 경기에서 이어지는 다음 경기들의 승자는 지워서 다시 고르게
  k:=mi; for r in ri+1..jsonb_array_length(rs)-1 loop k:=k/2; rs:=jsonb_set(rs,array[r::text,k::text,'w'],'null'::jsonb); end loop;
  update public.ffc_brackets set rounds=rs where id=bid;
  perform public.ffc_bracket_flow(bid);
end $$;

revoke all on function public.ffc_coin_move(uuid,int,text), public.ffc_bracket_flow(bigint) from public, anon, authenticated;
revoke all on function public.ffc_bet_new(uuid,uuid,text,int), public.ffc_bet_answer(bigint,boolean), public.ffc_bet_pick(bigint,uuid), public.ffc_bracket_new(uuid,text,uuid[]), public.ffc_bracket_win(bigint,int,int,uuid) from public, anon;
grant execute on function public.ffc_bet_new(uuid,uuid,text,int), public.ffc_bet_answer(bigint,boolean), public.ffc_bet_pick(bigint,uuid), public.ffc_bracket_new(uuid,text,uuid[]), public.ffc_bracket_win(bigint,int,int,uuid) to authenticated;

-- 👥 그룹 대화방: 멤버 초대(내 친구만, 최대 30명), 방장(만든 사람)만 내보내기
create or replace function public.ffc_invite(rid uuid, members uuid[]) returns int
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); k text; m uuid; n int:=0; cnt int; nm text:=''; begin
  if me is null or not public.ffc_is_member(rid) then raise exception 'members'; end if;
  select kind into k from public.ffc_rooms where id=rid; if k<>'group' then raise exception 'group only'; end if;
  foreach m in array coalesce(members,'{}') loop
    select count(*) into cnt from public.ffc_members where room_id=rid; exit when cnt>=30;
    if m<>me and public.ffc_is_friend(me,m) and not exists(select 1 from public.ffc_members where room_id=rid and user_id=m) then
      insert into public.ffc_members(room_id,user_id) values(rid,m); n:=n+1;
      nm:=nm||case when nm='' then '' else ', ' end||coalesce((select coalesce(display_name,username) from public.profiles where id=m),'?');
    end if;
  end loop;
  if n>0 then insert into public.ffc_msgs(room_id,user_id,body,kind) values(rid,me,left(nm,200)||'님을 초대했어요','sys'); end if;
  return n;
end $$;
create or replace function public.ffc_kick(rid uuid, who uuid) returns void
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); nm text; begin
  if me is null or who=me then raise exception 'bad'; end if;
  if not exists(select 1 from public.ffc_rooms where id=rid and kind='group' and created_by=me) then raise exception 'owner only'; end if;
  delete from public.ffc_members where room_id=rid and user_id=who; if not found then return; end if;
  select coalesce(display_name,username) into nm from public.profiles where id=who;
  insert into public.ffc_msgs(room_id,user_id,body,kind) values(rid,me,coalesce(nm,'?')||'님을 내보냈어요','sys');
end $$;
revoke all on function public.ffc_invite(uuid,uuid[]), public.ffc_kick(uuid,uuid) from public, anon;
grant execute on function public.ffc_invite(uuid,uuid[]), public.ffc_kick(uuid,uuid) to authenticated;

alter publication supabase_realtime add table public.ffc_bets;
alter publication supabase_realtime add table public.ffc_brackets;
