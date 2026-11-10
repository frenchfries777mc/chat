-- Frenchfries777 Chat (카카오톡 같은 메신저): 1:1 + 그룹 대화방, 안 읽은 수, 실시간
create table if not exists public.ffc_rooms(
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('dm','group')),
  name text,
  dm_key text unique,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  last_text text
);
create table if not exists public.ffc_members(
  room_id uuid not null references public.ffc_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  last_read_at timestamptz not null default now(),
  primary key(room_id,user_id)
);
create index if not exists ffc_members_user on public.ffc_members(user_id);
create table if not exists public.ffc_msgs(
  id bigint generated always as identity primary key,
  room_id uuid not null references public.ffc_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists ffc_msgs_room on public.ffc_msgs(room_id,id desc);

create or replace function public.ffc_is_member(rid uuid) returns boolean
language sql stable security definer set search_path=public as
$$ select exists(select 1 from public.ffc_members where room_id=rid and user_id=auth.uid()) $$;

alter table public.ffc_rooms enable row level security;
alter table public.ffc_members enable row level security;
alter table public.ffc_msgs enable row level security;

drop policy if exists ffc_rooms_sel on public.ffc_rooms;
create policy ffc_rooms_sel on public.ffc_rooms for select to authenticated using (public.ffc_is_member(id));
drop policy if exists ffc_members_sel on public.ffc_members;
create policy ffc_members_sel on public.ffc_members for select to authenticated using (public.ffc_is_member(room_id));
drop policy if exists ffc_members_upd on public.ffc_members;
create policy ffc_members_upd on public.ffc_members for update to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());
drop policy if exists ffc_msgs_sel on public.ffc_msgs;
create policy ffc_msgs_sel on public.ffc_msgs for select to authenticated using (public.ffc_is_member(room_id));
drop policy if exists ffc_msgs_ins on public.ffc_msgs;
create policy ffc_msgs_ins on public.ffc_msgs for insert to authenticated with check (user_id=auth.uid() and public.ffc_is_member(room_id));

-- 새 메시지가 오면 방의 마지막 글·시간 갱신
create or replace function public.ffc_msg_after() returns trigger
language plpgsql security definer set search_path=public as
$$ begin
  update public.ffc_rooms set last_at=new.created_at, last_text=left(new.body,80) where id=new.room_id;
  return new;
end $$;
drop trigger if exists ffc_msg_after on public.ffc_msgs;
create trigger ffc_msg_after after insert on public.ffc_msgs for each row execute function public.ffc_msg_after();

-- 친구인지 확인
create or replace function public.ffc_is_friend(a uuid,b uuid) returns boolean
language sql stable security definer set search_path=public as
$$ select exists(select 1 from public.friendships f where f.status='accepted' and ((f.requester_id=a and f.addressee_id=b) or (f.requester_id=b and f.addressee_id=a))) $$;

-- 친구와 1:1 대화방 열기(없으면 만듦)
create or replace function public.ffc_open_dm(friend uuid) returns uuid
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); k text; rid uuid; begin
  if me is null then raise exception 'login'; end if;
  if friend=me or not public.ffc_is_friend(me,friend) then raise exception 'not friends'; end if;
  k:=least(me::text,friend::text)||'_'||greatest(me::text,friend::text);
  select id into rid from public.ffc_rooms where dm_key=k;
  if rid is null then
    insert into public.ffc_rooms(kind,dm_key,created_by) values('dm',k,me) returning id into rid;
    insert into public.ffc_members(room_id,user_id) values(rid,me),(rid,friend);
  end if;
  return rid;
end $$;

-- 그룹 대화방 만들기(내 친구만, 본인 포함 최대 30명)
create or replace function public.ffc_create_group(gname text, members uuid[]) returns uuid
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); rid uuid; m uuid; n int:=0; begin
  if me is null then raise exception 'login'; end if;
  if coalesce(array_length(members,1),0)<1 or array_length(members,1)>29 then raise exception 'members'; end if;
  insert into public.ffc_rooms(kind,name,created_by) values('group',left(coalesce(nullif(trim(gname),''),'그룹 채팅'),30),me) returning id into rid;
  insert into public.ffc_members(room_id,user_id) values(rid,me);
  foreach m in array members loop
    if m<>me and public.ffc_is_friend(me,m) then insert into public.ffc_members(room_id,user_id) values(rid,m) on conflict do nothing; end if;
  end loop;
  return rid;
end $$;

-- 방 나가기
create or replace function public.ffc_leave(rid uuid) returns void
language sql security definer set search_path=public as
$$ delete from public.ffc_members where room_id=rid and user_id=auth.uid() $$;

revoke all on function public.ffc_open_dm(uuid), public.ffc_create_group(text,uuid[]), public.ffc_leave(uuid), public.ffc_is_friend(uuid,uuid), public.ffc_is_member(uuid), public.ffc_msg_after() from public, anon;
grant execute on function public.ffc_open_dm(uuid), public.ffc_create_group(text,uuid[]), public.ffc_leave(uuid), public.ffc_is_member(uuid) to authenticated;

alter publication supabase_realtime add table public.ffc_msgs;
alter publication supabase_realtime add table public.ffc_members;
