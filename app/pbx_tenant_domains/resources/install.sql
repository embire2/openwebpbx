-- Public HTTPS aliases are transport identities; existing SIP domains never change.
CREATE TABLE IF NOT EXISTS v_pbx_tenant_domains (
 domain_uuid uuid PRIMARY KEY,tenant_uuid uuid NOT NULL,service_uuid uuid NOT NULL,
 requested_label text NOT NULL,hostname text UNIQUE,server_host text NOT NULL DEFAULT '',
 key_hash text NOT NULL DEFAULT '',revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 desired_enabled boolean NOT NULL DEFAULT true,
 state text NOT NULL DEFAULT 'pending' CHECK(state IN('pending','pending_dns','pending_tls','ready','disabled','retry','conflict')),
 error_category text NOT NULL DEFAULT '',certificate_not_after timestamptz,
 next_attempt timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
-- No cascade: removed/disabled services retain their global lease and ownership tombstone.
