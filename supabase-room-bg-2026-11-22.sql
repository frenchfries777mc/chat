-- 방장이 방 배경을 정하고 공지를 올려요 (그룹방은 방장만, 1:1은 둘 다)
alter table public.ffc_rooms add column if not exists bg text;
create or replace function public.ffc_can_manage(rid uuid) returns boolean
language sql stable security definer set search_path=public as
$$ select exists(select 1 from public.ffc_rooms r where r.id=rid and public.ffc_is_member(rid) and (r.kind<>'group' or r.created_by=auth.uid())) $$;
create or replace function public.ffc_set_notice(rid uuid, t text) returns void
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); begin
  if me is null or not public.ffc_can_manage(rid) then raise exception 'owner only'; end if;
  update public.ffc_rooms set notice=nullif(left(trim(coalesce(t,'')),300),''), notice_by=me where id=rid;
  insert into public.ffc_msgs(room_id,user_id,body,kind) values(rid,me,case when nullif(trim(coalesce(t,'')),'') is null then '공지를 내렸어요' else '공지를 올렸어요' end,'sys');
end $$;
create or replace function public.ffc_set_bg(rid uuid, k text) returns void
language plpgsql security definer set search_path=public as
$$ declare me uuid:=auth.uid(); begin
  if me is null or not public.ffc_can_manage(rid) then raise exception 'owner only'; end if;
  update public.ffc_rooms set bg=nullif(left(trim(coalesce(k,'')),20),'') where id=rid;
end $$;
revoke all on function public.ffc_can_manage(uuid), public.ffc_set_bg(uuid,text) from public, anon;
grant execute on function public.ffc_can_manage(uuid), public.ffc_set_bg(uuid,text) to authenticated;
