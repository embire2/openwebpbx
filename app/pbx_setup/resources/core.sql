create table if not exists v_pbx_core_checks (
    check_uuid uuid primary key,
    domain_uuid uuid not null,
    trunk_id varchar(40) not null,
    check_kind varchar(24) not null,
    call_uuid uuid,
    result varchar(24) not null,
    note varchar(500) not null default '',
    checked_by uuid not null,
    created_at timestamptz not null default now()
);
create index if not exists pbx_core_checks_scope on v_pbx_core_checks(domain_uuid,trunk_id,created_at desc);
alter table v_pbx_core_checks add column if not exists config_hash varchar(64) not null default '';
create table if not exists v_pbx_core_audit (
    audit_uuid uuid primary key,
    domain_uuid uuid not null,
    actor_uuid uuid not null,
    action varchar(32) not null,
    call_uuid uuid,
    target varchar(80) not null default '',
    result varchar(24) not null,
    created_at timestamptz not null default now()
);
create index if not exists pbx_core_audit_scope on v_pbx_core_audit(domain_uuid,created_at desc);
create table if not exists v_pbx_queue_tickets (
    ticket_id bigserial primary key,
    domain_uuid uuid not null,
    queue_number varchar(10) not null,
    call_uuid uuid not null,
    state varchar(16) not null default 'waiting',
    job_uuid uuid,
    joined_at timestamptz not null default now(),
    ended_at timestamptz,
    wait_seconds integer not null default 0,
    unique(domain_uuid,queue_number,call_uuid)
);
create index if not exists pbx_queue_ticket_order on v_pbx_queue_tickets(domain_uuid,queue_number,state,joined_at);
