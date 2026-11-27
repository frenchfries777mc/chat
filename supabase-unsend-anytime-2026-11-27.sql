-- 내가 보낸 메시지는 시간 제한 없이 지울 수 있게 (AI 답변 포함)
create or replace function public.ffc_unsend(mid bigint) returns void language plpgsql security definer set search_path to 'public' as $$ begin
  update public.ffc_msgs set kind='del', body='삭제된 메시지예요', meta=null
   where id=mid and user_id=auth.uid() and kind in ('text','sticker','image','result','ai');
  if not found then raise exception 'cannot delete'; end if;
end $$;
