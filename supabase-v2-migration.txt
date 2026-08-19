-- QR出退勤アプリ v2 / Supabase migration（固定QR版）
-- v1.1 fixed2 からの更新用。既存の従業員・打刻データは保持します。
-- 主な追加: 打刻修正履歴、管理者PIN変更、従業員停止/再開、従業員PIN再設定
-- QRコードはv1と同じ固定QR方式です。

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- 旧v2動的QR版を一度適用していても固定QRへ戻せるよう、安全に削除
drop function if exists public.qr_attendance_validate_qr(text);
drop function if exists public.qr_attendance_admin_issue_qr(text,int);
drop function if exists public.qr_attendance_employee_clock_v2(text,text,text,text);
drop table if exists public.qr_attendance_qr_tokens;

create table if not exists public.qr_attendance_edit_log(
  id uuid primary key default extensions.gen_random_uuid(),
  employee_id uuid not null references public.qr_attendance_employees(id) on delete cascade,
  work_date date not null,
  old_check_in timestamptz,
  old_check_out timestamptz,
  new_check_in timestamptz,
  new_check_out timestamptz,
  reason text,
  created_at timestamptz not null default now()
);

alter table public.qr_attendance_edit_log enable row level security;

create or replace function public.qr_attendance_admin_update_record(
  p_admin_pin text,
  p_employee_code text,
  p_work_date date,
  p_check_in timestamptz,
  p_check_out timestamptz,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.qr_attendance_employees%rowtype;
  a public.qr_attendance_records%rowtype;
begin
  if not public.qr_attendance_is_admin(p_admin_pin) then
    return jsonb_build_object('ok',false,'message','管理者PINが違います。');
  end if;

  select * into e from public.qr_attendance_employees where employee_code=p_employee_code;
  if e.id is null then
    return jsonb_build_object('ok',false,'message','従業員が見つかりません。');
  end if;

  select * into a from public.qr_attendance_records where employee_id=e.id and work_date=p_work_date;

  insert into public.qr_attendance_edit_log(
    employee_id,work_date,old_check_in,old_check_out,new_check_in,new_check_out,reason
  ) values(
    e.id,p_work_date,a.check_in,a.check_out,p_check_in,p_check_out,nullif(trim(coalesce(p_reason,'')),'')
  );

  if p_check_in is null and p_check_out is null then
    delete from public.qr_attendance_records where employee_id=e.id and work_date=p_work_date;
    return jsonb_build_object('ok',true,'message','打刻を取消しました。');
  end if;

  if p_check_out is not null and p_check_in is null then
    return jsonb_build_object('ok',false,'message','退勤時刻だけを登録することはできません。');
  end if;

  if p_check_in is not null and p_check_out is not null and p_check_out < p_check_in then
    return jsonb_build_object('ok',false,'message','退勤時刻は出勤時刻より後にしてください。');
  end if;

  insert into public.qr_attendance_records(employee_id,work_date,check_in,check_out)
  values(e.id,p_work_date,p_check_in,p_check_out)
  on conflict(employee_id,work_date)
  do update set check_in=excluded.check_in,check_out=excluded.check_out,updated_at=now();

  return jsonb_build_object('ok',true,'message','打刻を修正しました。');
end;
$$;

grant execute on function public.qr_attendance_admin_update_record(text,text,date,timestamptz,timestamptz,text) to anon, authenticated;

create or replace function public.qr_attendance_admin_change_pin(
  p_admin_pin text,
  p_new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.qr_attendance_is_admin(p_admin_pin) then
    return jsonb_build_object('ok',false,'message','現在の管理者PINが違います。');
  end if;
  if length(trim(coalesce(p_new_pin,''))) < 4 then
    return jsonb_build_object('ok',false,'message','新しい管理者PINは4桁以上にしてください。');
  end if;

  update public.qr_attendance_settings
  set admin_pin_hash=extensions.crypt(trim(p_new_pin),extensions.gen_salt('bf')),updated_at=now()
  where id=1;

  return jsonb_build_object('ok',true,'message','管理者PINを変更しました。');
end;
$$;

grant execute on function public.qr_attendance_admin_change_pin(text,text) to anon, authenticated;

create or replace function public.qr_attendance_admin_set_employee_active(
  p_admin_pin text,
  p_employee_code text,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.qr_attendance_is_admin(p_admin_pin) then
    return jsonb_build_object('ok',false,'message','管理者PINが違います。');
  end if;

  update public.qr_attendance_employees set active=p_active where employee_code=p_employee_code;
  if not found then
    return jsonb_build_object('ok',false,'message','従業員が見つかりません。');
  end if;
  return jsonb_build_object('ok',true,'message',case when p_active then '従業員を再開しました。' else '従業員を停止しました。' end);
end;
$$;

grant execute on function public.qr_attendance_admin_set_employee_active(text,text,boolean) to anon, authenticated;

create or replace function public.qr_attendance_admin_reset_employee_pin(
  p_admin_pin text,
  p_employee_code text,
  p_new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.qr_attendance_is_admin(p_admin_pin) then
    return jsonb_build_object('ok',false,'message','管理者PINが違います。');
  end if;
  if length(trim(coalesce(p_new_pin,''))) < 4 then
    return jsonb_build_object('ok',false,'message','PINは4桁以上にしてください。');
  end if;

  update public.qr_attendance_employees
  set pin_hash=extensions.crypt(trim(p_new_pin),extensions.gen_salt('bf'))
  where employee_code=p_employee_code;

  if not found then
    return jsonb_build_object('ok',false,'message','従業員が見つかりません。');
  end if;
  return jsonb_build_object('ok',true,'message','従業員PINを変更しました。');
end;
$$;

grant execute on function public.qr_attendance_admin_reset_employee_pin(text,text,text) to anon, authenticated;

create or replace function public.qr_attendance_admin_edit_log(p_admin_pin text,p_limit int default 100)
returns table(
  created_at timestamptz,
  work_date date,
  employee_code text,
  employee_name text,
  old_check_in timestamptz,
  old_check_out timestamptz,
  new_check_in timestamptz,
  new_check_out timestamptz,
  reason text
)
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.qr_attendance_is_admin(p_admin_pin) then
    raise exception 'unauthorized';
  end if;

  return query
  select l.created_at,l.work_date,e.employee_code,e.name,l.old_check_in,l.old_check_out,l.new_check_in,l.new_check_out,l.reason
  from public.qr_attendance_edit_log l
  join public.qr_attendance_employees e on e.id=l.employee_id
  order by l.created_at desc
  limit greatest(1,least(coalesce(p_limit,100),500));
end;
$$;

grant execute on function public.qr_attendance_admin_edit_log(text,int) to anon, authenticated;
