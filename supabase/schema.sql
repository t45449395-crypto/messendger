create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique,
  display_name text not null default 'Пользователь',
  about text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format check (
    username is null or username ~ '^[a-zA-Z0-9_]{3,24}$'
  ),
  constraint profiles_display_name_length check (
    char_length(display_name) between 1 and 60
  ),
  constraint profiles_about_length check (char_length(about) <= 160)
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_one uuid references public.profiles (id) on delete cascade,
  user_two uuid references public.profiles (id) on delete cascade,
  kind text not null default 'personal' check (kind in ('personal', 'group')),
  title text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint conversations_members_shape check (
    (kind = 'personal' and user_one is not null and user_two is not null and user_one < user_two)
    or (kind = 'group' and user_one is null and user_two is null and title is not null)
  ),
  constraint conversations_unique_pair unique (user_one, user_two)
);

alter table public.conversations alter column user_one drop not null;
alter table public.conversations alter column user_two drop not null;
alter table public.conversations drop constraint if exists conversations_distinct_users;
alter table public.conversations drop constraint if exists conversations_members_shape;
alter table public.conversations add column if not exists kind text not null default 'personal';
alter table public.conversations add column if not exists title text;
alter table public.conversations add constraint conversations_members_shape check (
  (kind = 'personal' and user_one is not null and user_two is not null and user_one < user_two)
  or (kind = 'group' and user_one is null and user_two is null and title is not null)
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null default '',
  attachment jsonb,
  created_at timestamptz not null default now(),
  constraint messages_body_length check (
    (attachment is null and char_length(body) between 1 and 4000)
    or (
      attachment is not null
      and char_length(body) <= 4000
      and jsonb_typeof(attachment) = 'object'
      and attachment ?& array['path', 'name', 'mime', 'size']
      and jsonb_typeof(attachment -> 'path') = 'string'
      and jsonb_typeof(attachment -> 'name') = 'string'
      and jsonb_typeof(attachment -> 'mime') = 'string'
      and jsonb_typeof(attachment -> 'size') = 'string'
      and char_length(attachment ->> 'path') between 1 and 512
      and char_length(attachment ->> 'name') between 1 and 255
      and char_length(attachment ->> 'mime') between 1 and 120
      and coalesce((attachment ->> 'size') ~ '^[0-9]{1,9}$', false)
    )
  )
);

alter table public.messages alter column body set default '';
alter table public.messages add column if not exists attachment jsonb;
alter table public.messages drop constraint if exists messages_body_length;
alter table public.messages add constraint messages_body_length check (
  (attachment is null and char_length(body) between 1 and 4000)
  or (
    attachment is not null
    and char_length(body) <= 4000
    and jsonb_typeof(attachment) = 'object'
    and attachment ?& array['path', 'name', 'mime', 'size']
    and jsonb_typeof(attachment -> 'path') = 'string'
    and jsonb_typeof(attachment -> 'name') = 'string'
    and jsonb_typeof(attachment -> 'mime') = 'string'
    and jsonb_typeof(attachment -> 'size') = 'string'
    and char_length(attachment ->> 'path') between 1 and 512
    and char_length(attachment ->> 'name') between 1 and 255
    and char_length(attachment ->> 'mime') between 1 and 120
    and coalesce((attachment ->> 'size') ~ '^[0-9]{1,9}$', false)
  )
);

create table if not exists public.call_signals (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('offer', 'answer', 'ice', 'end', 'decline')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint call_signals_different_users check (sender_id <> recipient_id),
  constraint call_signals_payload_size check (octet_length(payload::text) <= 12000),
  constraint call_signals_payload_shape check (
    (kind = 'offer'
      and coalesce(jsonb_typeof(payload -> 'sdp') = 'string', false)
      and coalesce(payload ->> 'callKind' in ('audio', 'video'), false))
    or (kind = 'answer' and coalesce(jsonb_typeof(payload -> 'sdp') = 'string', false))
    or (kind = 'ice' and coalesce(jsonb_typeof(payload -> 'candidate') = 'string', false))
    or (kind in ('end', 'decline') and jsonb_typeof(payload) = 'object')
  )
);

create table if not exists public.call_history (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null unique,
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  caller_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  call_kind text not null check (call_kind in ('audio', 'video')),
  status text not null default 'ringing'
    check (status in ('ringing', 'answered', 'declined', 'missed', 'ended')),
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint call_history_different_users check (caller_id <> recipient_id)
);

create table if not exists public.push_subscriptions (
  endpoint text primary key check (endpoint ~ '^https://'),
  user_id uuid not null references public.profiles (id) on delete cascade,
  p256dh text not null check (char_length(p256dh) between 40 and 200),
  auth text not null check (char_length(auth) between 16 and 100),
  updated_at timestamptz not null default now(),
  constraint push_subscriptions_endpoint_length check (char_length(endpoint) between 1 and 2048)
);

create table if not exists public.gift_catalog (
  gift_key text primary key,
  name text not null,
  emoji text not null,
  rarity text not null,
  description text not null,
  sort_order smallint not null
);

insert into public.gift_catalog (gift_key, name, emoji, rarity, description, sort_order)
values
  ('star', 'Звёздный вечер', '🌟', 'Особенный', 'Пусть сегодня всё складывается особенно красиво.', 1),
  ('bouquet', 'Тёплый букет', '💐', 'Нежный', 'Просто чтобы напомнить: вы прекрасны.', 2),
  ('cat', 'Мур-мур', '🐱', 'Милый', 'Немного пушистого настроения на весь день.', 3),
  ('cup', 'Кофейная пауза', '☕', 'Уютный', 'Пусть найдётся время на глоток тепла.', 4),
  ('planet', 'Моя планета', '🪐', 'Космический', 'Ты — целый удивительный мир.', 5),
  ('crown', 'Корона дня', '👑', 'Редкий', 'Сегодня главный герой — ты.', 6),
  ('heart', 'С теплом', '💌', 'От души', 'Маленькая открытка с большими чувствами.', 7),
  ('sparkle', 'Искра вдохновения', '✨', 'Вдохновение', 'Пусть новая идея найдётся именно сегодня.', 8)
on conflict (gift_key) do update
  set name = excluded.name,
      emoji = excluded.emoji,
      rarity = excluded.rarity,
      description = excluded.description,
      sort_order = excluded.sort_order;

create table if not exists public.user_gifts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  gift_key text not null references public.gift_catalog (gift_key),
  note text not null default '',
  is_pinned boolean not null default false,
  created_at timestamptz not null default now(),
  constraint user_gifts_different_users check (owner_id <> sender_id),
  constraint user_gifts_note_length check (char_length(note) <= 160)
);

create table if not exists public.user_subscriptions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  plan_key text not null default 'premium',
  status text not null default 'inactive'
    check (status in ('inactive', 'trialing', 'active', 'past_due', 'canceled')),
  current_period_end timestamptz,
  updated_at timestamptz not null default now()
);

insert into public.conversation_members (conversation_id, user_id)
select c.id, member.user_id
from public.conversations c
cross join lateral (values (c.user_one), (c.user_two)) as member(user_id)
where c.kind = 'personal' and member.user_id is not null
on conflict (conversation_id, user_id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chat-attachments',
  'chat-attachments',
  false,
  20971520,
  array[
    'image/jpeg', 'image/png', 'image/gif', 'image/webp',
    'video/mp4', 'video/webm', 'audio/mpeg', 'audio/mp4',
    'audio/ogg', 'audio/webm', 'application/pdf', 'text/plain'
  ]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create index if not exists conversations_user_one_updated_idx
  on public.conversations (user_one, updated_at desc);
create index if not exists conversations_user_two_updated_idx
  on public.conversations (user_two, updated_at desc);
create index if not exists messages_conversation_created_idx
  on public.messages (conversation_id, created_at desc);
create index if not exists conversation_members_user_idx
  on public.conversation_members (user_id, conversation_id);
create index if not exists call_signals_recipient_created_idx
  on public.call_signals (recipient_id, created_at desc);
create index if not exists call_signals_created_idx
  on public.call_signals (created_at);
create index if not exists call_signals_call_id_idx
  on public.call_signals (call_id);
create index if not exists call_history_caller_created_idx
  on public.call_history (caller_id, created_at desc);
create index if not exists call_history_recipient_created_idx
  on public.call_history (recipient_id, created_at desc);
create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);
create index if not exists user_gifts_owner_created_idx
  on public.user_gifts (owner_id, created_at desc);
create index if not exists user_gifts_sender_created_idx
  on public.user_gifts (sender_id, created_at desc);

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    'guest_' || substr(replace(new.id::text, '-', ''), 1, 12),
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''), 'Пользователь')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
  after insert on auth.users
  for each row execute function public.create_profile_for_new_user();

insert into public.profiles (id, username, display_name)
select
  u.id,
  'guest_' || substr(replace(u.id::text, '-', ''), 1, 12),
  coalesce(nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''), 'Пользователь')
from auth.users u
on conflict (id) do update
  set username = coalesce(public.profiles.username, excluded.username);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists conversations_set_updated_at on public.conversations;
create trigger conversations_set_updated_at
  before update on public.conversations
  for each row execute function public.set_updated_at();

drop trigger if exists user_subscriptions_set_updated_at on public.user_subscriptions;
create trigger user_subscriptions_set_updated_at
  before update on public.user_subscriptions
  for each row execute function public.set_updated_at();

create or replace function public.touch_conversation_after_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversations
  set updated_at = now()
  where id = new.conversation_id;
  return new;
end;
$$;

create or replace function public.record_call_history_from_signal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.kind = 'offer' then
    insert into public.call_history (
      call_id, conversation_id, caller_id, recipient_id, call_kind, created_at
    )
    select
      new.call_id, c.id, new.sender_id, new.recipient_id, new.payload ->> 'callKind', new.created_at
    from public.conversations c
    join public.conversation_members caller
      on caller.conversation_id = c.id and caller.user_id = new.sender_id
    join public.conversation_members callee
      on callee.conversation_id = c.id and callee.user_id = new.recipient_id
    where c.kind = 'personal'
    on conflict (call_id) do nothing;

    if not exists (
      select 1
      from public.call_history
      where call_id = new.call_id
        and caller_id = new.sender_id
        and recipient_id = new.recipient_id
    ) then
      raise exception 'Call participants are not members of a personal conversation';
    end if;
  elsif new.kind = 'answer' then
    update public.call_history
    set status = 'answered'
    where call_id = new.call_id
      and caller_id = new.recipient_id
      and recipient_id = new.sender_id
      and status = 'ringing';
  elsif new.kind in ('decline', 'end') then
    update public.call_history
    set status = case
          when new.kind = 'decline' then 'declined'
          when status = 'ringing' then 'missed'
          else 'ended'
        end,
        ended_at = coalesce(ended_at, new.created_at)
    where call_id = new.call_id
      and (
        (caller_id = new.sender_id and recipient_id = new.recipient_id)
        or (caller_id = new.recipient_id and recipient_id = new.sender_id)
      )
      and ended_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists call_signals_record_history on public.call_signals;
create trigger call_signals_record_history
  after insert on public.call_signals
  for each row execute function public.record_call_history_from_signal();

create or replace function public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id = (select auth.uid())
    and exists (
      select 1
      from public.conversation_members cm
      where cm.conversation_id = p_conversation_id
        and cm.user_id = p_user_id
    );
$$;

drop trigger if exists messages_touch_conversation on public.messages;
create trigger messages_touch_conversation
  after insert on public.messages
  for each row execute function public.touch_conversation_after_message();

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.gift_catalog enable row level security;
alter table public.user_gifts enable row level security;
alter table public.user_subscriptions enable row level security;
alter table public.conversation_members enable row level security;
alter table public.call_signals enable row level security;
alter table public.call_history enable row level security;
alter table public.push_subscriptions enable row level security;

drop policy if exists "Profiles are visible to signed-in users" on public.profiles;
create policy "Profiles are visible to signed-in users"
  on public.profiles for select to authenticated
  using (true);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

drop policy if exists "Users can create their own profile" on public.profiles;
create policy "Users can create their own profile"
  on public.profiles for insert to authenticated
  with check ((select auth.uid()) = id);

drop policy if exists "Conversation members can read conversations" on public.conversations;
create policy "Conversation members can read conversations"
  on public.conversations for select to authenticated
  using (public.is_conversation_member(id, (select auth.uid())));

drop policy if exists "Conversation members can read membership" on public.conversation_members;
create policy "Conversation members can read membership"
  on public.conversation_members for select to authenticated
  using (public.is_conversation_member(conversation_id, (select auth.uid())));

drop policy if exists "Conversation members can read messages" on public.messages;
create policy "Conversation members can read messages"
  on public.messages for select to authenticated
  using (public.is_conversation_member(conversation_id, (select auth.uid())));

drop policy if exists "Conversation members can send messages as themselves" on public.messages;
create policy "Conversation members can send messages as themselves"
  on public.messages for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and public.is_conversation_member(conversation_id, (select auth.uid()))
    and (
      attachment is null
      or (attachment ->> 'path') like conversation_id::text || '/' || (select auth.uid())::text || '/%'
    )
  );

drop policy if exists "Direct conversation members can read call signals" on public.call_signals;
create policy "Direct conversation members can read call signals"
  on public.call_signals for select to authenticated
  using (
    (select auth.uid()) in (sender_id, recipient_id)
    and exists (
      select 1
      from public.conversations c
      join public.conversation_members caller
        on caller.conversation_id = c.id and caller.user_id = call_signals.sender_id
      join public.conversation_members callee
        on callee.conversation_id = c.id and callee.user_id = call_signals.recipient_id
      where c.kind = 'personal'
    )
  );

drop policy if exists "Direct conversation members can send call signals" on public.call_signals;
create policy "Direct conversation members can send call signals"
  on public.call_signals for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and recipient_id <> (select auth.uid())
    and exists (
      select 1
      from public.conversations c
      join public.conversation_members caller
        on caller.conversation_id = c.id and caller.user_id = call_signals.sender_id
      join public.conversation_members callee
        on callee.conversation_id = c.id and callee.user_id = call_signals.recipient_id
      where c.kind = 'personal'
    )
  );

drop policy if exists "Users can read their own call history" on public.call_history;
create policy "Users can read their own call history"
  on public.call_history for select to authenticated
  using ((select auth.uid()) in (caller_id, recipient_id));

drop policy if exists "Users can read their own push subscriptions" on public.push_subscriptions;
create policy "Users can read their own push subscriptions"
  on public.push_subscriptions for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can create their own push subscriptions" on public.push_subscriptions;
create policy "Users can create their own push subscriptions"
  on public.push_subscriptions for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update their own push subscriptions" on public.push_subscriptions;
create policy "Users can update their own push subscriptions"
  on public.push_subscriptions for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can remove their own push subscriptions" on public.push_subscriptions;
create policy "Users can remove their own push subscriptions"
  on public.push_subscriptions for delete to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Signed-in users can view the gift catalog" on public.gift_catalog;
create policy "Signed-in users can view the gift catalog"
  on public.gift_catalog for select to authenticated
  using (true);

drop policy if exists "Signed-in users can view public gift collections" on public.user_gifts;
create policy "Signed-in users can view public gift collections"
  on public.user_gifts for select to authenticated
  using (true);

drop policy if exists "Owners can pin gifts in their collection" on public.user_gifts;
create policy "Owners can pin gifts in their collection"
  on public.user_gifts for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

drop policy if exists "Users can view their own subscription status" on public.user_subscriptions;
create policy "Users can view their own subscription status"
  on public.user_subscriptions for select to authenticated
  using ((select auth.uid()) = user_id);

create or replace function public.search_profiles(search_term text)
returns table (id uuid, username text, display_name text, about text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.username, p.display_name, p.about
  from public.profiles p
  where auth.uid() is not null
    and p.id <> auth.uid()
    and length(btrim(coalesce(search_term, ''))) >= 3
    and (
      p.username ilike '%' || btrim(search_term) || '%'
      or p.display_name ilike '%' || btrim(search_term) || '%'
    )
  order by p.username nulls last, p.display_name
  limit 20;
$$;

create or replace function public.send_gift(
  p_recipient_id uuid,
  p_gift_key text,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  created_gift_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;
  if p_recipient_id is null or p_recipient_id = current_user_id then
    raise exception 'Choose another user';
  end if;
  if not exists (select 1 from public.profiles where id = p_recipient_id) then
    raise exception 'User not found';
  end if;
  if not exists (select 1 from public.gift_catalog where public.gift_catalog.gift_key = p_gift_key) then
    raise exception 'Gift not found';
  end if;
  if char_length(coalesce(p_note, '')) > 160 then
    raise exception 'Gift note is too long';
  end if;

  insert into public.user_gifts (owner_id, sender_id, gift_key, note)
  values (p_recipient_id, current_user_id, p_gift_key, btrim(coalesce(p_note, '')))
  returning id into created_gift_id;

  return created_gift_id;
end;
$$;

create or replace function public.get_or_create_direct_conversation(other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  first_user_id uuid;
  second_user_id uuid;
  v_conversation_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;
  if other_user_id is null or other_user_id = current_user_id then
    raise exception 'Choose another user';
  end if;
  if not exists (select 1 from public.profiles where id = other_user_id) then
    raise exception 'User not found';
  end if;

  first_user_id := least(current_user_id, other_user_id);
  second_user_id := greatest(current_user_id, other_user_id);

  insert into public.conversations (user_one, user_two)
  values (first_user_id, second_user_id)
  on conflict (user_one, user_two) do update
    set updated_at = now()
  returning id into v_conversation_id;

  insert into public.conversation_members (conversation_id, user_id)
  values (v_conversation_id, current_user_id), (v_conversation_id, other_user_id)
  on conflict (conversation_id, user_id) do nothing;

  return v_conversation_id;
end;
$$;

create or replace function public.create_group_conversation(
  p_title text,
  p_member_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  group_title text := btrim(coalesce(p_title, ''));
  group_member_ids uuid[];
  v_conversation_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;
  if char_length(group_title) not between 1 and 60 then
    raise exception 'Group name must contain 1 to 60 characters';
  end if;

  select array_agg(distinct member_id)
    into group_member_ids
  from unnest(coalesce(p_member_ids, array[]::uuid[])) as requested(member_id)
  where member_id is not null and member_id <> current_user_id;

  group_member_ids := coalesce(group_member_ids, array[]::uuid[]);
  if cardinality(group_member_ids) not between 1 and 49 then
    raise exception 'Choose between 1 and 49 other participants';
  end if;
  if exists (
    select 1 from unnest(group_member_ids) requested(member_id)
    where not exists (select 1 from public.profiles p where p.id = requested.member_id)
  ) then
    raise exception 'A selected participant was not found';
  end if;

  insert into public.conversations (kind, title)
  values ('group', group_title)
  returning id into v_conversation_id;

  insert into public.conversation_members (conversation_id, user_id)
  select v_conversation_id, member_id
  from unnest(array_append(group_member_ids, current_user_id)) participants(member_id)
  on conflict (conversation_id, user_id) do nothing;

  return v_conversation_id;
end;
$$;

create or replace function public.purge_stale_call_signals()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  delete from public.call_signals
  where created_at < now() - interval '24 hours';
end;
$$;

revoke all on function public.search_profiles(text) from public, anon;
grant execute on function public.search_profiles(text) to authenticated;
revoke all on function public.send_gift(uuid, text, text) from public, anon;
grant execute on function public.send_gift(uuid, text, text) to authenticated;
revoke all on function public.get_or_create_direct_conversation(uuid) from public, anon;
grant execute on function public.get_or_create_direct_conversation(uuid) to authenticated;
revoke all on function public.create_group_conversation(text, uuid[]) from public, anon;
grant execute on function public.create_group_conversation(text, uuid[]) to authenticated;
revoke all on function public.purge_stale_call_signals() from public, anon;
grant execute on function public.purge_stale_call_signals() to authenticated;

grant select, insert, update on public.profiles to authenticated;
grant select on public.conversations to authenticated;
grant select on public.conversation_members to authenticated;
grant select, insert on public.messages to authenticated;
grant select, insert on public.call_signals to authenticated;
grant select on public.call_history to authenticated;
grant select, insert, update, delete on public.push_subscriptions to authenticated;
grant select on public.gift_catalog to authenticated;
grant select on public.user_gifts to authenticated;
grant update (is_pinned) on public.user_gifts to authenticated;
grant select on public.user_subscriptions to authenticated;
revoke all on function public.is_conversation_member(uuid, uuid) from public, anon;
grant execute on function public.is_conversation_member(uuid, uuid) to authenticated;

drop policy if exists "Conversation members can upload attachments" on storage.objects;
create policy "Conversation members can upload attachments"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'chat-attachments'
    and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and (storage.foldername(name))[2] = (select auth.uid())::text
    and exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id::text = (storage.foldername(name))[1]
        and cm.user_id = (select auth.uid())
    )
  );

drop policy if exists "Conversation members can read attachments" on storage.objects;
create policy "Conversation members can read attachments"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'chat-attachments'
    and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id::text = (storage.foldername(name))[1]
        and cm.user_id = (select auth.uid())
    )
  );

drop policy if exists "Users can remove their own attachments" on storage.objects;
create policy "Users can remove their own attachments"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'chat-attachments'
    and (storage.foldername(name))[2] = (select auth.uid())::text
    and exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id::text = (storage.foldername(name))[1]
        and cm.user_id = (select auth.uid())
    )
  );

do $$
begin
  begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
       and not exists (
         select 1
         from pg_publication_tables
         where pubname = 'supabase_realtime'
           and schemaname = 'public'
           and tablename = 'messages'
       ) then
      alter publication supabase_realtime add table public.messages;
    end if;
  exception
    when undefined_object then
      raise notice 'Create the supabase_realtime publication before enabling message updates.';
  end;
  begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
       and not exists (
         select 1
         from pg_publication_tables
         where pubname = 'supabase_realtime'
           and schemaname = 'public'
           and tablename = 'user_gifts'
       ) then
      alter publication supabase_realtime add table public.user_gifts;
    end if;
  exception
    when undefined_object then
      raise notice 'Create the supabase_realtime publication before enabling gift updates.';
  end;
  begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
       and not exists (
         select 1 from pg_publication_tables
         where pubname = 'supabase_realtime'
           and schemaname = 'public'
           and tablename = 'call_signals'
       ) then
      alter publication supabase_realtime add table public.call_signals;
    end if;
  exception
    when undefined_object then
      raise notice 'Create the supabase_realtime publication before enabling call signaling.';
  end;
  begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
       and not exists (
         select 1
         from pg_publication_tables
         where pubname = 'supabase_realtime'
           and schemaname = 'public'
           and tablename = 'call_history'
       ) then
      alter publication supabase_realtime add table public.call_history;
    end if;
  exception
    when undefined_object then
      raise notice 'Create the supabase_realtime publication before enabling call history updates.';
  end;
end;
$$;
