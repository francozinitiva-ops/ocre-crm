-- ═══════════════════════════════════════════════════════════════════
-- OCRE · CRM — esquema de Supabase
-- Cada registro del CRM se guarda entero en `data` (jsonb), con su ID
-- legible (CLI-0001, RES-0003…) como clave. Algunas columnas se derivan
-- solas de `data` para poder leer y filtrar las tablas desde el panel
-- de Supabase. Solo los usuarios cargados en crm_usuarios pueden leer
-- o escribir.
-- ═══════════════════════════════════════════════════════════════════

-- ── Usuarios habilitados ─────────────────────────────────────────────
create table if not exists public.crm_usuarios (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  email    text not null,
  nombre   text,
  alta     timestamptz not null default now()
);

create or replace function public.crm_es_miembro()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.crm_usuarios where user_id = auth.uid());
$$;
revoke all on function public.crm_es_miembro() from public, anon;
grant execute on function public.crm_es_miembro() to authenticated;

-- ── Sello de última modificación ─────────────────────────────────────
create or replace function public.crm_sellar()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

-- ── Tablas de datos ──────────────────────────────────────────────────
create table if not exists public.crm_clientes (
  id text primary key, data jsonb not null,
  nombre   text generated always as (btrim(coalesce(data->>'nombre','') || ' ' || coalesce(data->>'apellido',''))) stored,
  doc      text generated always as (data->>'doc') stored,
  telefono text generated always as (data->>'telefono') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.crm_proveedores (
  id text primary key, data jsonb not null,
  nombre text generated always as (data->>'nombre') stored,
  tipo   text generated always as (data->>'tipo') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.crm_destinos (
  id text primary key, data jsonb not null,
  nombre    text generated always as (data->>'nombre') stored,
  provincia text generated always as (data->>'provincia') stored,
  motor     text generated always as (data->>'tipo') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.crm_leads (
  id text primary key, data jsonb not null,
  nombre   text generated always as (data->>'nombre') stored,
  etapa    text generated always as (data->>'etapa') stored,
  telefono text generated always as (data->>'telefono') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.crm_reservas (
  id text primary key, data jsonb not null,
  titulo     text generated always as (data->>'titulo') stored,
  cliente_id text generated always as (data->>'clienteId') stored,
  destino_id text generated always as (data->>'destinoId') stored,
  estado     text generated always as (data->>'estado') stored,
  salida     text generated always as (data->>'salida') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.crm_cobros (
  id text primary key, data jsonb not null,
  reserva_id text generated always as (data->>'reservaId') stored,
  fecha      text generated always as (data->>'fecha') stored,
  monto      text generated always as (data->>'monto') stored,
  moneda     text generated always as (data->>'moneda') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.crm_pagos_prov (
  id text primary key, data jsonb not null,
  reserva_id   text generated always as (data->>'reservaId') stored,
  proveedor_id text generated always as (data->>'proveedorId') stored,
  fecha        text generated always as (data->>'fecha') stored,
  monto        text generated always as (data->>'monto') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.crm_egresos (
  id text primary key, data jsonb not null,
  fecha     text generated always as (data->>'fecha') stored,
  categoria text generated always as (data->>'categoria') stored,
  monto     text generated always as (data->>'monto') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.crm_paquetes (
  id text primary key, data jsonb not null,
  nombre text generated always as (data->>'nombre') stored,
  updated_at timestamptz not null default now(), updated_by uuid
);
-- Configuración (cfg) y contadores de numeración (cont)
create table if not exists public.crm_meta (
  clave text primary key, data jsonb not null,
  updated_at timestamptz not null default now(), updated_by uuid
);

-- ── Permisos, sellos y tiempo real (para todas las tablas de datos) ──
do $$
declare t text;
begin
  foreach t in array array['crm_clientes','crm_proveedores','crm_destinos','crm_leads','crm_reservas',
                           'crm_cobros','crm_pagos_prov','crm_egresos','crm_paquetes','crm_meta']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('drop policy if exists crm_miembros on public.%I', t);
    execute format('create policy crm_miembros on public.%I for all to authenticated
                    using (public.crm_es_miembro()) with check (public.crm_es_miembro())', t);
    execute format('drop trigger if exists crm_sellar on public.%I', t);
    execute format('create trigger crm_sellar before insert or update on public.%I
                    for each row execute function public.crm_sellar()', t);
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- crm_usuarios: cada uno ve solo su propia fila; el alta se hace desde el panel / SQL.
alter table public.crm_usuarios enable row level security;
revoke all on public.crm_usuarios from anon;
grant select on public.crm_usuarios to authenticated;
drop policy if exists crm_usuario_propio on public.crm_usuarios;
create policy crm_usuario_propio on public.crm_usuarios for select to authenticated
  using (user_id = auth.uid());

-- ── Alta de usuarios (correr después de crearlos en Authentication) ──
-- insert into public.crm_usuarios (user_id, email, nombre)
-- select id, email, 'Franco' from auth.users where email = 'TU_EMAIL';
