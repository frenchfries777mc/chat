-- 내기 걸기 실패 수정: 게임 이름이 비면 ffc_bets_game_check(1~40자)에 걸렸음. 비면 '기타'로 저장 (적용 완료)
create or replace function public.ffc_bet_new(rid uuid, opp uuid, gname text, n integer) returns bigint language plpgsql security definer set search_path to 'public' as $function$ declare me uuid:=auth.uid(); bid bigint; g text:=left(coalesce(nullif(trim(gname),''),'기타'),40); begin
  if me is null then raise exception 'login'; end if;
  if opp=me or not public.ffc_is_member(rid) or not exists(select 1 from public.ffc_members where room_id=rid and user_id=opp) then raise exception 'members'; end if;
  if n is null or n<1 or n>100 then raise exception 'amount'; end if;
  perform public.ffc_coin_move(me,-n,'bet_out');
  insert into public.ffc_bets(room_id,a,b,game,coins) values(rid,me,opp,g,n) returning id into bid;
  insert into public.ffc_msgs(room_id,user_id,body,kind,meta) values(rid,me,'🎲 '||n||'코인 내기'||case when g='기타' then '' else ' · '||g end,'bet',jsonb_build_object('bet',bid));
  return bid;
end $function$;
