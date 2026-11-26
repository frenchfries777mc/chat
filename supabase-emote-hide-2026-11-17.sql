-- 채팅 이모티콘: 가진 이모티콘을 "내 이모티콘" 목록에서 빼기 / 다시 넣기 (2026-11-17, 오너 요청)
-- 먼저 supabase-emotes-2026-11-17.sql 을 실행한 뒤에 이 파일을 실행해요 (팩 파일은 먼저든 나중이든 상관없어요).
-- 하는 일: 가진 이모티콘 표(ffc_emote_own)에 "숨김" 칸을 더하고, 숨기기/다시 보이기 함수를 만들어요.
--   * 빼도 산 기록은 남아요. 그래서 상점에서 "가짐"으로 보이고, 다시 사지 않아도 "다시 넣기"로 되돌릴 수 있어요.
-- 여러 번 실행해도 안전해요. 쓰는 법: Supabase 왼쪽 SQL Editor → New query → 이 파일 전체를 붙여 넣고 Run.

alter table public.ffc_emote_own add column if not exists hidden boolean not null default false;

-- 내 이모티콘 여러 개를 한 번에 빼기(p_hidden = true) / 다시 넣기(false). 돌려주는 값 = 바뀐 개수
create or replace function public.ffc_emote_hide(p_ids uuid[], p_hidden boolean)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  update public.ffc_emote_own set hidden = coalesce(p_hidden, true)
   where user_id = auth.uid() and emote_id = any(coalesce(p_ids, '{}'::uuid[]));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.ffc_emote_hide(uuid[], boolean) from public, anon;
grant execute on function public.ffc_emote_hide(uuid[], boolean) to authenticated;

-- 성공 확인: 아래 한 줄을 실행하면 false 가 나와요
-- select column_default from information_schema.columns where table_name = 'ffc_emote_own' and column_name = 'hidden';
