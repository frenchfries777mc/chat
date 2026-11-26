-- 업데이트 소식 1:1 (봇 전용, 삭제 불가, 알림 끄기만 가능)
alter table public.ffc_members add column if not exists muted boolean not null default false;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, banned_until, raw_app_meta_data, raw_user_meta_data)
values ('00000000-0000-4000-8000-0000000f0f01','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ff-news@bot.invalid','',now(),now(),now(),'infinity','{}','{}')
on conflict (id) do nothing;

insert into public.profiles (id, username, display_name)
values ('00000000-0000-4000-8000-0000000f0f01','ff-news','업데이트 소식')
on conflict (id) do nothing;

create or replace function public.ff_news_bot() returns uuid language sql immutable as $$ select '00000000-0000-4000-8000-0000000f0f01'::uuid $$;

create or replace function public.ff_news_room_for(u uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare rid uuid; k text := 'news_'||u;
begin
  if u = public.ff_news_bot() then return null; end if;
  select id into rid from public.ffc_rooms where dm_key = k;
  if rid is null then
    insert into public.ffc_rooms(kind,dm_key,created_by) values ('dm',k,public.ff_news_bot()) on conflict (dm_key) do nothing returning id into rid;
    if rid is null then select id into rid from public.ffc_rooms where dm_key = k; end if;
  end if;
  insert into public.ffc_members(room_id,user_id) values (rid,u),(rid,public.ff_news_bot()) on conflict do nothing;
  return rid;
end $$;
revoke all on function public.ff_news_room_for(uuid) from public, anon, authenticated;

create or replace function public.ff_news_ensure() returns uuid
language sql security definer set search_path=public as $$ select public.ff_news_room_for(auth.uid()) $$;
revoke all on function public.ff_news_ensure() from public, anon;
grant execute on function public.ff_news_ensure() to authenticated;

create or replace function public.ff_news_post(msg text) returns int
language plpgsql security definer set search_path=public as $$
declare r record; n int := 0;
begin
  if not (public.ff_is_admin() or public.ff_is_dev()) then raise exception 'forbidden'; end if;
  for r in select id from public.ffc_rooms where dm_key like 'news\_%' loop
    insert into public.ffc_msgs(room_id,user_id,kind,body) values (r.id,public.ff_news_bot(),'text',left(msg,2000));
    n := n+1;
  end loop;
  return n;
end $$;
revoke all on function public.ff_news_post(text) from public, anon;
grant execute on function public.ff_news_post(text) to authenticated;

-- 봇 외에는 소식방에 글을 쓸 수 없음 (모든 경로 차단)
create or replace function public.ffc_news_guard() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.user_id <> public.ff_news_bot()
     and exists(select 1 from public.ffc_rooms where id=new.room_id and dm_key like 'news\_%') then
    raise exception 'news room is read-only';
  end if;
  return new;
end $$;
drop trigger if exists ffc_news_guard on public.ffc_msgs;
create trigger ffc_news_guard before insert on public.ffc_msgs for each row execute function public.ffc_news_guard();

-- 소식방은 나갈 수 없음
create or replace function public.ffc_leave(rid uuid) returns void
language sql security definer set search_path=public as $$
  delete from public.ffc_members where room_id=rid and user_id=auth.uid()
    and not exists(select 1 from public.ffc_rooms where id=rid and dm_key like 'news\_%') $$;

-- 알림 끈 사람은 안 읽은 알림 생성 제외
create or replace function public.ffc_msg_after() returns trigger
language plpgsql security definer set search_path=public as $$ begin
  update public.ffc_rooms set last_at=new.created_at, last_text=left(new.body,80) where id=new.room_id;
  insert into public.ff_notes(user_id,kind,actor_id,ref)
    select m.user_id,'chat',new.user_id,new.id from public.ffc_members m
    where m.room_id=new.room_id and m.user_id<>new.user_id and not m.muted
      and not exists(select 1 from public.ff_notes n where n.user_id=m.user_id and n.kind='chat' and n.actor_id=new.user_id and not n.read);
  return new;
end $$;

-- 새 가입자 자동 가입 (실패해도 가입은 막지 않음)
create or replace function public.ff_news_signup() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  begin perform public.ff_news_room_for(new.id); exception when others then null; end;
  return new;
end $$;
drop trigger if exists ff_news_signup on auth.users;
create trigger ff_news_signup after insert on auth.users for each row execute function public.ff_news_signup();

-- 기존 계정 전부 가입
do $$ declare u record; begin
  for u in select id from auth.users where id <> public.ff_news_bot() loop perform public.ff_news_room_for(u.id); end loop;
end $$;
