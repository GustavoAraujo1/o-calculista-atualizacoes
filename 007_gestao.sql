-- =============================================================================
-- O CALCULISTA — 007: gestão (fornecedores, obras, compras, estoque, anexos,
-- papéis e auditoria) + NCM no banco de preços
-- =============================================================================
-- Mesmo padrão das tabelas da fila (005):
--   • atualizado_em (sincronização incremental), exclusão lógica (excluido = true),
--     criado_por / atualizado_por carimbados pelo banco;
--   • leitura: qualquer conta aprovada; gravação: conta aprovada com o PAPEL do módulo
--     (veja public.tem_papel); marcar excluído e apagar de vez: só o administrador.
-- Papéis (tabela perfis, o administrador define): orcamento, comercial, compras, estoque,
-- obra. Conta SEM linha em perfis tem todos os papéis (nada muda para quem já usa o
-- programa até o administrador distribuir os papéis).
-- Códigos automáticos por ano: OBR-AAAA-NN (obras), COT- (cotações), PC- (pedidos de
-- compra), REQ- (requisições), como o CAL das oportunidades.
-- Auditoria: toda criação/alteração nas tabelas de gestão, no banco de preços e na fila
-- fica registrada (quem, quando, antes/depois); só o administrador consulta.
-- Anexos: arquivos no Storage (bucket privado 'anexos'), uma linha em public.anexos.
-- Só cria coisas novas; em tabelas existentes, apenas as colunas itens.ncm e clientes.cnpj.
-- =============================================================================

-- ── Papéis ──────────────────────────────────────────────────────────────────
create table if not exists public.perfis (
  id              uuid primary key default gen_random_uuid(),
  usuario_id      uuid not null unique references auth.users(id),
  papeis          text[] not null default '{}',
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  criado_por      uuid references auth.users(id) default auth.uid(),
  atualizado_por  uuid references auth.users(id),
  excluido        boolean not null default false,
  check (papeis <@ array['orcamento', 'comercial', 'compras', 'estoque', 'obra']::text[])
);

-- Conta aprovada com o papel (admin tem todos; sem linha em perfis = todos).
create or replace function public.tem_papel(p_papeis text[])
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare meus text[];
begin
  if not public.eh_aprovado() then return false; end if;
  if public.eh_admin() then return true; end if;
  select papeis into meus from public.perfis where usuario_id = auth.uid() and not excluido;
  if not found then return true; end if;
  return meus && p_papeis;
end $$;
revoke execute on function public.tem_papel(text[]) from public, anon;
grant execute on function public.tem_papel(text[]) to authenticated;

-- ── Numeração por prefixo e ano (OBR, COT, PC, REQ) ─────────────────────────
create table if not exists public.numeracao_geral (
  prefixo text not null,
  ano     integer not null,
  ultimo  integer not null default 0 check (ultimo >= 0),
  primary key (prefixo, ano)
);
alter table public.numeracao_geral enable row level security;   -- sem políticas: só pela função abaixo

-- Gatilho: codigo vazio recebe PREFIXO-AAAA-NN (prefixo no argumento do gatilho).
create or replace function public.codigo_sequencial()
returns trigger language plpgsql security definer set search_path = '' as $$
declare n integer; v_ano integer := extract(year from now())::int; pref text := tg_argv[0];
begin
  if coalesce(trim(new.codigo), '') = '' then
    insert into public.numeracao_geral as c (prefixo, ano, ultimo) values (pref, v_ano, 1)
    on conflict (prefixo, ano) do update set ultimo = c.ultimo + 1
    returning c.ultimo into n;
    new.codigo := pref || '-' || v_ano || '-' || case when n < 10 then '0' || n else n::text end;
  end if;
  return new;
end $$;

-- ── Fornecedores ────────────────────────────────────────────────────────────
create table if not exists public.fornecedores (
  id uuid primary key default gen_random_uuid(),
  nome text not null, cnpj text not null default '', ie text not null default '',
  cidade text not null default '', uf text not null default '', cep text not null default '',
  endereco text not null default '', telefone text not null default '', email text not null default '',
  contato text not null default '', categorias text not null default '', observacoes text not null default '',
  dados_cnpj jsonb not null default '{}',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);
create unique index if not exists fornecedores_cnpj_idx on public.fornecedores (cnpj) where not excluido and cnpj <> '';

-- ── Obras (orçamento ganho → obra) ──────────────────────────────────────────
create table if not exists public.obras (
  id uuid primary key default gen_random_uuid(),
  codigo text not null default '', nome text not null,
  cliente_id uuid references public.clientes(id), oportunidade_id uuid references public.oportunidades(id),
  orcamento_id text not null default '',
  status text not null default 'Planejada' check (status in ('Planejada', 'Em andamento', 'Paralisada', 'Concluída', 'Cancelada')),
  data_inicio date, data_fim_prevista date, data_fim date,
  valor_contrato numeric(16,2), endereco text not null default '', cidade text not null default '', uf text not null default '',
  responsavel_id uuid references auth.users(id), observacoes text not null default '',
  orcado jsonb not null default '{}',        -- foto do orçamento contratado (tópicos, itens, totais)
  eventos jsonb not null default '[]',       -- eventos de pagamento do contrato
  cronograma jsonb not null default '[]',    -- % previsto por mês (curva S planejada)
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);
create unique index if not exists obras_codigo_idx on public.obras (codigo) where codigo <> '';

create table if not exists public.medicoes (
  id uuid primary key default gen_random_uuid(),
  obra_id uuid not null references public.obras(id), numero integer not null default 1,
  data date not null default current_date, periodo_inicio date, periodo_fim date,
  itens jsonb not null default '[]', valor numeric(16,2) not null default 0,
  status text not null default 'Rascunho' check (status in ('Rascunho', 'Enviada', 'Aprovada', 'Faturada')),
  observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);
create unique index if not exists medicoes_numero_idx on public.medicoes (obra_id, numero) where not excluido;

create table if not exists public.custos_obra (
  id uuid primary key default gen_random_uuid(),
  obra_id uuid not null references public.obras(id), data date not null default current_date,
  topico text not null default '', descricao text not null default '',
  categoria text not null default 'Material' check (categoria in ('Material', 'Mão de obra', 'Equipamento', 'Serviço', 'Indireto')),
  quantidade numeric(16,4), unidade text not null default '', valor numeric(16,2) not null default 0,
  documento text not null default '', fornecedor_id uuid references public.fornecedores(id), pedido_id uuid,
  observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);

create table if not exists public.diario_obra (
  id uuid primary key default gen_random_uuid(),
  obra_id uuid not null references public.obras(id), data date not null default current_date,
  clima text not null default '', efetivo jsonb not null default '[]',
  atividades text not null default '', ocorrencias text not null default '', fotos jsonb not null default '[]',
  observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);

-- Quadro de tarefas (Kanban da obra; obra_id vazio = tarefa geral)
create table if not exists public.tarefas (
  id uuid primary key default gen_random_uuid(),
  obra_id uuid references public.obras(id), titulo text not null, descricao text not null default '',
  coluna text not null default 'A fazer', ordem numeric(16,4) not null default 0,
  responsavel_id uuid references auth.users(id), prazo date, etiquetas jsonb not null default '[]',
  concluida boolean not null default false,
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);

-- ── Compras ─────────────────────────────────────────────────────────────────
create table if not exists public.cotacoes (
  id uuid primary key default gen_random_uuid(),
  codigo text not null default '', obra_id uuid references public.obras(id), titulo text not null default '',
  status text not null default 'Aberta' check (status in ('Aberta', 'Respondida', 'Fechada', 'Cancelada')),
  prazo date, itens jsonb not null default '[]', respostas jsonb not null default '[]', vencedores jsonb not null default '{}',
  observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);
create unique index if not exists cotacoes_codigo_idx on public.cotacoes (codigo) where codigo <> '';

create table if not exists public.pedidos_compra (
  id uuid primary key default gen_random_uuid(),
  codigo text not null default '', cotacao_id uuid references public.cotacoes(id), obra_id uuid references public.obras(id),
  fornecedor_id uuid references public.fornecedores(id),
  status text not null default 'Emitido' check (status in ('Emitido', 'Aprovado', 'Recebido parcial', 'Recebido', 'Cancelado')),
  data date not null default current_date, previsao_entrega date, itens jsonb not null default '[]',
  valor numeric(16,2) not null default 0, frete numeric(16,2) not null default 0,
  condicao_pagamento text not null default '', observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);
create unique index if not exists pedidos_codigo_idx on public.pedidos_compra (codigo) where codigo <> '';

-- ── Estoque ─────────────────────────────────────────────────────────────────
create table if not exists public.almoxarifados (
  id uuid primary key default gen_random_uuid(),
  nome text not null, tipo text not null default 'Central' check (tipo in ('Central', 'Obra')),
  obra_id uuid references public.obras(id), endereco text not null default '', observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);

-- Saldo e custo médio são calculados no programa a partir das movimentações.
create table if not exists public.estoque_movimentos (
  id uuid primary key default gen_random_uuid(),
  data date not null default current_date,
  tipo text not null check (tipo in ('entrada', 'saida', 'transferencia', 'ajuste', 'devolucao')),
  codigo text not null, produto text not null default '', unidade text not null default 'UN',
  quantidade numeric(16,4) not null, custo_unitario numeric(16,4) not null default 0,
  almoxarifado_id uuid not null references public.almoxarifados(id), destino_id uuid references public.almoxarifados(id),
  obra_id uuid references public.obras(id), pedido_id uuid references public.pedidos_compra(id), requisicao_id uuid,
  documento text not null default '', observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false,
  check (tipo = 'ajuste' or quantidade > 0),
  check (tipo <> 'transferencia' or destino_id is not null)
);
create index if not exists estoque_mov_codigo_idx on public.estoque_movimentos (codigo) where not excluido;

create table if not exists public.requisicoes (
  id uuid primary key default gen_random_uuid(),
  codigo text not null default '', obra_id uuid references public.obras(id), orcamento_id text not null default '',
  status text not null default 'Aberta' check (status in ('Aberta', 'Parcial', 'Atendida', 'Cancelada')),
  data date not null default current_date, itens jsonb not null default '[]', observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);
create unique index if not exists requisicoes_codigo_idx on public.requisicoes (codigo) where codigo <> '';

-- ── Anexos (arquivo no Storage, bucket privado 'anexos') ────────────────────
create table if not exists public.anexos (
  id uuid primary key default gen_random_uuid(),
  entidade text not null, entidade_id text not null, nome text not null, caminho text not null unique,
  tamanho bigint not null default 0, tipo text not null default '', observacoes text not null default '',
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id) default auth.uid(), atualizado_por uuid references auth.users(id),
  excluido boolean not null default false
);
create index if not exists anexos_entidade_idx on public.anexos (entidade, entidade_id) where not excluido;

insert into storage.buckets (id, name, public, file_size_limit)
values ('anexos', 'anexos', false, 52428800)       -- 50 MB por arquivo
on conflict (id) do nothing;
drop policy if exists anexos_ler on storage.objects;
drop policy if exists anexos_enviar on storage.objects;
drop policy if exists anexos_apagar on storage.objects;
create policy anexos_ler on storage.objects for select to authenticated
  using (bucket_id = 'anexos' and (select public.eh_aprovado()));
create policy anexos_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'anexos' and (select public.eh_aprovado()));
create policy anexos_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'anexos' and (select public.eh_admin()));

-- ── Gatilhos (atualizado_em/atualizado_por e códigos) e permissões ──────────
do $$
declare
  t text;
  -- tabela → papéis que gravam (leitura: toda conta aprovada)
  grav jsonb := '{
    "perfis": [], "fornecedores": ["compras","comercial"], "obras": ["obra"], "medicoes": ["obra"],
    "custos_obra": ["obra","compras"], "diario_obra": ["obra"], "tarefas": ["obra","orcamento","comercial","compras","estoque"],
    "cotacoes": ["compras"], "pedidos_compra": ["compras"], "almoxarifados": ["estoque"],
    "estoque_movimentos": ["estoque","compras","obra"], "requisicoes": ["obra","estoque"],
    "anexos": ["orcamento","comercial","compras","estoque","obra"]
  }';
  papeis text;
begin
  for t in select jsonb_object_keys(grav) loop
    execute format('create index if not exists %1$s_atualizado_idx on public.%1$s (atualizado_em)', t);
    execute format('drop trigger if exists %1$s_tocar on public.%1$s', t);
    execute format('create trigger %1$s_tocar before update on public.%1$s for each row execute function public.tocar_atualizado_em()', t);
    execute format('alter table public.%1$s enable row level security', t);
    papeis := (select coalesce(string_agg(quote_literal(x), ','), '') from jsonb_array_elements_text(grav -> t) x);
    execute format('drop policy if exists %1$s_ler on public.%1$s', t);
    execute format('drop policy if exists %1$s_criar on public.%1$s', t);
    execute format('drop policy if exists %1$s_alterar on public.%1$s', t);
    execute format('drop policy if exists %1$s_apagar on public.%1$s', t);
    execute format('create policy %1$s_ler on public.%1$s for select to authenticated using ((select public.eh_aprovado()))', t);
    if papeis = '' then   -- perfis: só o administrador grava
      execute format('create policy %1$s_criar on public.%1$s for insert to authenticated with check ((select public.eh_admin()))', t);
      execute format('create policy %1$s_alterar on public.%1$s for update to authenticated using ((select public.eh_admin())) with check ((select public.eh_admin()))', t);
    else
      execute format('create policy %1$s_criar on public.%1$s for insert to authenticated
                        with check ((select public.tem_papel(array[%2$s]::text[])) and not excluido)', t, papeis);
      execute format('create policy %1$s_alterar on public.%1$s for update to authenticated
                        using ((select public.tem_papel(array[%2$s]::text[])))
                        with check ((select public.tem_papel(array[%2$s]::text[])) and (not excluido or (select public.eh_admin())))', t, papeis);
    end if;
    execute format('create policy %1$s_apagar on public.%1$s for delete to authenticated using ((select public.eh_admin()))', t);
  end loop;
end $$;

drop trigger if exists obras_codigo on public.obras;
create trigger obras_codigo before insert on public.obras for each row execute function public.codigo_sequencial('OBR');
drop trigger if exists cotacoes_codigo on public.cotacoes;
create trigger cotacoes_codigo before insert on public.cotacoes for each row execute function public.codigo_sequencial('COT');
drop trigger if exists pedidos_compra_codigo on public.pedidos_compra;
create trigger pedidos_compra_codigo before insert on public.pedidos_compra for each row execute function public.codigo_sequencial('PC');
drop trigger if exists requisicoes_codigo on public.requisicoes;
create trigger requisicoes_codigo before insert on public.requisicoes for each row execute function public.codigo_sequencial('REQ');

-- ── Auditoria ───────────────────────────────────────────────────────────────
create table if not exists public.auditoria (
  id         bigint generated always as identity primary key,
  tabela     text not null,
  registro   text not null,
  acao       text not null,                 -- INSERT | UPDATE | DELETE
  usuario    uuid default auth.uid(),
  em         timestamptz not null default now(),
  mudancas   jsonb not null default '{}'    -- UPDATE: { coluna: [antes, depois] }; INSERT/DELETE: a linha (colunas grandes ficam de fora)
);
create index if not exists auditoria_registro_idx on public.auditoria (tabela, registro);
create index if not exists auditoria_em_idx on public.auditoria (em desc);
alter table public.auditoria enable row level security;
drop policy if exists auditoria_ler on public.auditoria;
create policy auditoria_ler on public.auditoria for select to authenticated using ((select public.eh_admin()));
-- (sem política de escrita: só o gatilho abaixo, que roda como dono)

create or replace function public.registrar_auditoria()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  antes jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) else '{}' end;
  depois jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) else '{}' end;
  ignorar text[] := array['atualizado_em', 'atualizado_por', 'criado_em', 'criado_por', 'estrutura', 'orcado', 'dados_cnpj'];
  m jsonb := '{}';
  k text;
begin
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(antes || depois) loop
      if k = any(ignorar) then continue; end if;
      if (antes -> k) is distinct from (depois -> k) then
        m := m || jsonb_build_object(k, jsonb_build_array(antes -> k, depois -> k));
      end if;
    end loop;
    if m = '{}' then return null; end if;
  else
    m := (case when tg_op = 'INSERT' then depois else antes end) - ignorar;
  end if;
  insert into public.auditoria (tabela, registro, acao, mudancas)
  values (tg_table_name, coalesce(depois ->> 'id', antes ->> 'id'), tg_op, m);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['itens', 'itens_ccmo', 'clientes', 'terceiros', 'oportunidades', 'perfis', 'fornecedores',
                           'obras', 'medicoes', 'custos_obra', 'cotacoes', 'pedidos_compra', 'almoxarifados',
                           'estoque_movimentos', 'requisicoes'] loop
    execute format('drop trigger if exists %1$s_auditoria on public.%1$s', t);
    execute format('create trigger %1$s_auditoria after insert or update or delete on public.%1$s
                      for each row execute function public.registrar_auditoria()', t);
  end loop;
end $$;

-- ── NCM no banco de preços (classificação fiscal do item) ───────────────────
alter table public.itens add column if not exists ncm text not null default '';

-- ── CNPJ do cliente (preenchimento pela BrasilAPI) ──────────────────────────
alter table public.clientes add column if not exists cnpj text not null default '';
