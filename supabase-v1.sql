-- QR出退勤アプリ v1 / Supabase 初期SQL（paid-leave-app共存＋pgcrypto extensions対応版 / fixed2）
-- 既存の有給休暇アプリのテーブル名と衝突しないよう、qr_attendance_ 接頭辞を使用します。

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.qr_attendance_settings(
  id int primary key default 1 check(id=1),
  admin_pin_hash text not null,
  updated_at timestamptz not null default now()
);

insert into public.qr_attendance_settings(id,admin_pin_hash)
values(1,extensions.crypt('0000',extensions.gen_salt('bf')))
on conflict(id) do nothing;

create table if not exists public.qr_attendance_employees(
  id uuid primary key default extensions.gen_random_uuid(),
  employee_code text not null unique,
  name text not null,
  pin_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.qr_attendance_records(
  id uuid primary key default extensions.gen_random_uuid(),
  employee_id uuid not null references public.qr_attendance_employees(id) on delete cascade,
  work_date date not null,
  check_in timestamptz,
  check_out timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(employee_id,work_date)
);

alter table public.qr_attendance_settings enable row level security;
alter table public.qr_attendance_employees enable row level security;
alter table public.qr_attendance_records enable row level security;

create or replace function public.qr_attendance_is_admin(p_admin_pin text)
returns boolean
language sql
security definer
set search_path=public
as $$
  select exists(
    select 1
    from public.qr_attendance_settings
    where id=1
      and admin_pin_hash=extensions.crypt(p_admin_pin,admin_pin_hash)
  );
$$;

create or replace function public.qr_attendance_admin_auth(p_admin_pin text)
returns boolean
language sql
security definer
set search_path=public
as $$
  select public.qr_attendance_is_admin(p_admin_pin);
$$;

grant execute on function public.qr_attendance_admin_auth(text) to anon, authenticated;

create or replace function public.qr_attendance_employee_status(p_employee_code text,p_pin text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.qr_attendance_employees%rowtype;
  a public.qr_attendance_records%rowtype;
  d date := (now() at time zone 'Asia/Tokyo')::date;
begin
  select * into e
  from public.qr_attendance_employees
  where employee_code=p_employee_code and active=true;

  if e.id is null or e.pin_hash<>extensions.crypt(p_pin,e.pin_hash) then
    return jsonb_build_object('ok',false,'message','社員コードまたはPINが違います。');
  end if;

  select * into a
  from public.qr_attendance_records
  where employee_id=e.id and work_date=d;

  return jsonb_build_object(
    'ok',true,
    'name',e.name,
    'check_in',a.check_in,
    'check_out',a.check_out
  );
end;
$$;

grant execute on function public.qr_attendance_employee_status(text,text) to anon, authenticated;

create or replace function public.qr_attendance_employee_clock(p_employee_code text,p_pin text,p_action text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  e public.qr_attendance_employees%rowtype;
  a public.qr_attendance_records%rowtype;
  d date := (now() at time zone 'Asia/Tokyo')::date;
  t timestamptz := now();
begin
  select * into e
  from public.qr_attendance_employees
  where employee_code=p_employee_code and active=true;

  if e.id is null or e.pin_hash<>extensions.crypt(p_pin,e.pin_hash) then
    return jsonb_build_object('ok',false,'message','社員コードまたはPINが違います。');
  end if;

  select * into a
  from public.qr_attendance_records
  where employee_id=e.id and work_date=d
  for update;

  if p_action='in' then
    if a.id is not null and a.check_in is not null then
      return jsonb_build_object('ok',false,'message','本日はすでに出勤打刻済みです。');
    end if;

    insert into public.qr_attendance_records(employee_id,work_date,check_in)
    values(e.id,d,t)
    on conflict(employee_id,work_date)
    do update set check_in=excluded.check_in,updated_at=now();

    return jsonb_build_object(
      'ok',true,
      'message',to_char(t at time zone 'Asia/Tokyo','HH24:MI')||' 出勤を記録しました。'
    );

  elsif p_action='out' then
    if a.id is null or a.check_in is null then
      return jsonb_build_object('ok',false,'message','先に出勤打刻してください。');
    end if;

    if a.check_out is not null then
      return jsonb_build_object('ok',false,'message','本日はすでに退勤打刻済みです。');
    end if;

    update public.qr_attendance_records
    set check_out=t,updated_at=now()
    where id=a.id;

    return jsonb_build_object(
      'ok',true,
      'message',to_char(t at time zone 'Asia/Tokyo','HH24:MI')||' 退勤を記録しました。'
    );
  end if;

  return jsonb_build_object('ok',false,'message','不正な操作です。');
end;
$$;

grant execute on function public.qr_attendance_employee_clock(text,text,text) to anon, authenticated;

create or replace function public.qr_attendance_admin_day(p_admin_pin text,p_date date)
returns table(employee_code text,employee_name text,check_in timestamptz,check_out timestamptz)
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.qr_attendance_is_admin(p_admin_pin) then
    raise exception 'unauthorized';
  end if;

  return query
  select e.employee_code,e.name,a.check_in,a.check_out
  from public.qr_attendance_employees e
  left join public.qr_attendance_records a
    on a.employee_id=e.id and a.work_date=p_date
  where e.active=true
  order by e.employee_code;
end;
$$;

grant execute on function public.qr_attendance_admin_day(text,date) to anon, authenticated;

create or replace function public.qr_attendance_admin_month(p_admin_pin text,p_year int,p_month int)
returns table(work_date date,employee_code text,employee_name text,check_in timestamptz,check_out timestamptz)
language plpgsql
security definer
set search_path=public
as $$
declare
  d1 date := make_date(p_year,p_month,1);
  d2 date := (make_date(p_year,p_month,1)+interval '1 month')::date;
begin
  if not public.qr_attendance_is_admin(p_admin_pin) then
    raise exception 'unauthorized';
  end if;

  return query
  select a.work_date,e.employee_code,e.name,a.check_in,a.check_out
  from public.qr_attendance_records a
  join public.qr_attendance_employees e on e.id=a.employee_id
  where a.work_date>=d1 and a.work_date<d2
  order by a.work_date,e.employee_code;
end;
$$;

grant execute on function public.qr_attendance_admin_month(text,int,int) to anon, authenticated;

create or replace function public.qr_attendance_admin_employees(p_admin_pin text)
returns table(employee_code text,name text,active boolean)
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.qr_attendance_is_admin(p_admin_pin) then
    raise exception 'unauthorized';
  end if;

  return query
  select e.employee_code,e.name,e.active
  from public.qr_attendance_employees e
  order by e.employee_code;
end;
$$;

grant execute on function public.qr_attendance_admin_employees(text) to anon, authenticated;

create or replace function public.qr_attendance_admin_add_employee(
  p_admin_pin text,
  p_employee_code text,
  p_name text,
  p_pin text
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

  if length(trim(p_employee_code))=0
     or length(trim(p_name))=0
     or length(trim(p_pin))<4 then
    return jsonb_build_object('ok',false,'message','社員コード・氏名・4桁以上のPINを入力してください。');
  end if;

  insert into public.qr_attendance_employees(employee_code,name,pin_hash)
  values(trim(p_employee_code),trim(p_name),extensions.crypt(p_pin,extensions.gen_salt('bf')));

  return jsonb_build_object('ok',true);
exception
  when unique_violation then
    return jsonb_build_object('ok',false,'message','その社員コードは登録済みです。');
end;
$$;

grant execute on function public.qr_attendance_admin_add_employee(text,text,text,text) to anon, authenticated;

-- 初期管理者PINは 0000 です。
-- 実運用前に変更してください。
-- 例：
-- update public.qr_attendance_settings
-- set admin_pin_hash=extensions.crypt('1234',extensions.gen_salt('bf')),updated_at=now()
-- where id=1;
