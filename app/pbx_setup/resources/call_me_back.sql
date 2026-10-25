BEGIN;
-- Domain-qualified foreign keys keep callback identity, quota and caller bindings together.
CREATE TABLE IF NOT EXISTS v_pbx_cmb_services (
 service_uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(), domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 100), incoming_rule_uuid uuid NOT NULL, route_owner text NOT NULL,
 enabled boolean NOT NULL DEFAULT false, prompt_version text NOT NULL DEFAULT '1.0.1' CHECK(prompt_version='1.0.1'),
 prompt_state text NOT NULL DEFAULT 'pending' CHECK(prompt_state IN ('pending','generating','ready','failed')),
 prompt_sha256 text, max_requests_hour integer NOT NULL DEFAULT 30 CHECK(max_requests_hour BETWEEN 1 AND 300),
 destination_prefixes text[] NOT NULL DEFAULT ARRAY['0','+27'], retention_days integer NOT NULL DEFAULT 90 CHECK(retention_days BETWEEN 7 AND 3650),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(domain_uuid,service_uuid), UNIQUE(domain_uuid,incoming_rule_uuid), CHECK(NOT enabled OR prompt_state='ready')
);
-- Retain old saved/custom choices while new generated greetings use Keoma1.0.2.
-- Only the installer-owned original check is replaced; other custom constraints remain.
DO $$
DECLARE definition text;
BEGIN
 SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
  WHERE conrelid='v_pbx_cmb_services'::regclass AND conname='v_pbx_cmb_services_prompt_version_check';
 IF definition IS NOT NULL THEN
  IF definition <> 'CHECK ((prompt_version = ''1.0.1''::text))' THEN
   RAISE EXCEPTION 'The callback voice version constraint needs administrator review';
  END IF;
  ALTER TABLE v_pbx_cmb_services DROP CONSTRAINT v_pbx_cmb_services_prompt_version_check;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='v_pbx_cmb_services'::regclass AND conname='openweb_cmb_prompt_version') THEN
  ALTER TABLE v_pbx_cmb_services ADD CONSTRAINT openweb_cmb_prompt_version CHECK(prompt_version IN ('1.0.1','1.0.2'));
 END IF;
 ALTER TABLE v_pbx_cmb_services ALTER COLUMN prompt_version SET DEFAULT '1.0.2';
END $$;
ALTER TABLE v_pbx_cmb_services ADD COLUMN IF NOT EXISTS prompt_refresh_state text NOT NULL DEFAULT 'pending' CHECK(prompt_refresh_state IN ('pending','preparing','complete','blocked'));
ALTER TABLE v_pbx_cmb_services ADD COLUMN IF NOT EXISTS prompt_refresh_token uuid;
ALTER TABLE v_pbx_cmb_services ADD COLUMN IF NOT EXISTS prompt_refresh_until timestamptz;
ALTER TABLE v_pbx_cmb_services ADD COLUMN IF NOT EXISTS prompt_refresh_after timestamptz;
ALTER TABLE v_pbx_cmb_services ADD COLUMN IF NOT EXISTS prompt_refresh_attempts integer NOT NULL DEFAULT 0 CHECK(prompt_refresh_attempts BETWEEN 0 AND 3);
ALTER TABLE v_pbx_cmb_services ADD COLUMN IF NOT EXISTS prompt_refresh_message text NOT NULL DEFAULT '';
-- Immutable narrator refreshes publish only by committing this basename. The
-- old fixed file remains untouched if generation, commit or the host fails.
ALTER TABLE v_pbx_cmb_services ADD COLUMN IF NOT EXISTS prompt_audio_file text NOT NULL DEFAULT 'greeting.wav'
 CHECK(prompt_audio_file='greeting.wav' OR (prompt_version='1.0.2' AND prompt_sha256 IS NOT NULL AND prompt_sha256 ~ '^[a-f0-9]{64}$' AND prompt_audio_file='greeting-keoma-'||prompt_sha256||'.wav'));
CREATE TABLE IF NOT EXISTS v_pbx_cmb_accounts (
 account_uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(), domain_uuid uuid NOT NULL, service_uuid uuid NOT NULL,
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 100), id_hmac text CHECK(id_hmac ~ '^[a-f0-9]{64}$'),
 id_last4 text CHECK(id_last4 ~ '^[0-9]{4}$'), total_seconds integer NOT NULL CHECK(total_seconds BETWEEN 0 AND 31536000),
 used_seconds integer NOT NULL DEFAULT 0 CHECK(used_seconds>=0), reserved_seconds integer NOT NULL DEFAULT 0 CHECK(reserved_seconds>=0),
 enabled boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(domain_uuid,service_uuid) REFERENCES v_pbx_cmb_services(domain_uuid,service_uuid) ON DELETE CASCADE,
 UNIQUE(domain_uuid,service_uuid,account_uuid), UNIQUE(domain_uuid,service_uuid,id_hmac), CHECK(used_seconds+reserved_seconds<=total_seconds), CHECK(NOT enabled OR (id_hmac IS NOT NULL AND id_last4 IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS v_pbx_cmb_bindings (
 binding_uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(), domain_uuid uuid NOT NULL, service_uuid uuid NOT NULL, account_uuid uuid NOT NULL,
 phone_number text NOT NULL CHECK(phone_number ~ '^\+27[1-8][0-9]{8}$'), authenticated_at timestamptz NOT NULL DEFAULT now(), revoked_at timestamptz,
 FOREIGN KEY(domain_uuid,service_uuid,account_uuid) REFERENCES v_pbx_cmb_accounts(domain_uuid,service_uuid,account_uuid) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS openweb_cmb_live_binding ON v_pbx_cmb_bindings(domain_uuid,service_uuid,phone_number) WHERE revoked_at IS NULL;
CREATE TABLE IF NOT EXISTS v_pbx_cmb_requests (
 request_uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(), domain_uuid uuid NOT NULL, service_uuid uuid NOT NULL, account_uuid uuid,
 inbound_uuid uuid NOT NULL UNIQUE, caller_number text CHECK(caller_number ~ '^\+27[1-8][0-9]{8}$'),
 state text NOT NULL DEFAULT 'announcing' CHECK(state IN ('announcing','queued','starting','authenticating','dialling','connected','completed','failed','cancelled')),
 reserved_seconds integer NOT NULL DEFAULT 0 CHECK(reserved_seconds BETWEEN 0 AND 600), used_seconds integer NOT NULL DEFAULT 0 CHECK(used_seconds BETWEEN 0 AND 600),
 call_uuid uuid, bridge_uuid uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 lease_until timestamptz, connected_at timestamptz, completed_at timestamptz, last_result text NOT NULL DEFAULT '',
 FOREIGN KEY(domain_uuid,service_uuid) REFERENCES v_pbx_cmb_services(domain_uuid,service_uuid) ON DELETE CASCADE,
 FOREIGN KEY(domain_uuid,service_uuid,account_uuid) REFERENCES v_pbx_cmb_accounts(domain_uuid,service_uuid,account_uuid)
);
CREATE UNIQUE INDEX IF NOT EXISTS openweb_cmb_active_caller ON v_pbx_cmb_requests(domain_uuid,service_uuid,caller_number)
 WHERE state IN ('announcing','queued','starting','authenticating','dialling','connected');
CREATE UNIQUE INDEX IF NOT EXISTS openweb_cmb_active_account ON v_pbx_cmb_requests(domain_uuid,account_uuid)
 WHERE account_uuid IS NOT NULL AND state IN ('authenticating','dialling','connected');
CREATE INDEX IF NOT EXISTS openweb_cmb_due ON v_pbx_cmb_requests(created_at) WHERE state='queued';
CREATE INDEX IF NOT EXISTS openweb_cmb_hourly ON v_pbx_cmb_requests(domain_uuid,service_uuid,created_at);
CREATE TABLE IF NOT EXISTS v_pbx_cmb_audit (audit_uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,actor_uuid uuid,action text NOT NULL,subject_uuid uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
-- The service-row lock serialises rate limits, including requests with different caller IDs.
CREATE OR REPLACE FUNCTION openweb_cmb_enqueue(d uuid,s uuid,inbound uuid,cli text)
RETURNS TABLE(request_uuid uuid,known boolean) LANGUAGE plpgsql AS $$
DECLARE service v_pbx_cmb_services%ROWTYPE; rid uuid; trusted boolean;
BEGIN
 PERFORM 1 FROM v_domains WHERE domain_uuid=d AND domain_enabled::text='true' FOR UPDATE;
 IF NOT FOUND OR EXISTS(SELECT 1 FROM v_pbx_services p JOIN v_pbx_tenants t USING(tenant_uuid) WHERE p.domain_uuid=d AND NOT t.enabled) THEN RETURN; END IF;
 IF cli IS NULL OR cli !~ '^\+27[1-8][0-9]{8}$' OR cli LIKE '+2786%' THEN RETURN; END IF;
 SELECT * INTO service FROM v_pbx_cmb_services WHERE domain_uuid=d AND service_uuid=s FOR UPDATE;
 IF NOT FOUND OR NOT service.enabled OR service.prompt_state<>'ready' THEN RETURN; END IF;
 IF EXISTS(SELECT 1 FROM v_pbx_cmb_requests r WHERE r.inbound_uuid=inbound) THEN RETURN; END IF;
 IF (SELECT count(*) FROM v_pbx_cmb_requests r WHERE r.domain_uuid=d AND r.service_uuid=s AND r.created_at>now()-interval '1 hour')>=service.max_requests_hour THEN RETURN; END IF;
 IF EXISTS(SELECT 1 FROM v_pbx_cmb_requests r WHERE r.domain_uuid=d AND r.service_uuid=s AND r.caller_number=cli AND (r.created_at>now()-interval '1 minute' OR r.state IN ('announcing','queued','starting','authenticating','dialling','connected'))) THEN RETURN; END IF;
 IF (SELECT count(*) FROM v_pbx_cmb_requests r WHERE r.domain_uuid=d AND r.state IN ('announcing','queued','starting','authenticating','dialling','connected'))>=4 THEN RETURN; END IF;
 IF (SELECT count(*) FROM v_pbx_cmb_requests r WHERE r.domain_uuid=d AND r.caller_number=cli AND r.last_result='authentication_failed' AND r.created_at>now()-interval '15 minutes')>=3 THEN RETURN; END IF;
 SELECT EXISTS(SELECT 1 FROM v_pbx_cmb_bindings b JOIN v_pbx_cmb_accounts a USING(domain_uuid,service_uuid,account_uuid) WHERE b.domain_uuid=d AND b.service_uuid=s AND b.phone_number=cli AND b.revoked_at IS NULL AND a.enabled) INTO trusted;
 INSERT INTO v_pbx_cmb_requests(domain_uuid,service_uuid,inbound_uuid,caller_number) VALUES(d,s,inbound,cli) RETURNING v_pbx_cmb_requests.request_uuid INTO rid;
 RETURN QUERY SELECT rid,trusted;
END $$;
-- Called only after the callback leg answered; the phone number is never supplied by DTMF.
CREATE OR REPLACE FUNCTION openweb_cmb_authorize(rid uuid,proof text DEFAULT NULL) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE request v_pbx_cmb_requests%ROWTYPE; account v_pbx_cmb_accounts%ROWTYPE; allowance integer;
BEGIN
 SELECT * INTO request FROM v_pbx_cmb_requests WHERE request_uuid=rid FOR UPDATE;
 IF NOT FOUND OR request.state<>'authenticating' OR request.account_uuid IS NOT NULL THEN RETURN 0; END IF;
 IF NOT EXISTS(SELECT 1 FROM v_domains WHERE domain_uuid=request.domain_uuid AND domain_enabled::text='true') OR EXISTS(SELECT 1 FROM v_pbx_services p JOIN v_pbx_tenants t USING(tenant_uuid) WHERE p.domain_uuid=request.domain_uuid AND NOT t.enabled) THEN RETURN 0; END IF;
 IF NOT EXISTS(SELECT 1 FROM v_pbx_cmb_services s WHERE s.domain_uuid=request.domain_uuid AND s.service_uuid=request.service_uuid AND s.enabled) THEN RETURN 0; END IF;
 IF proof IS NULL THEN
  SELECT a.* INTO account FROM v_pbx_cmb_accounts a JOIN v_pbx_cmb_bindings b USING(domain_uuid,service_uuid,account_uuid) WHERE a.domain_uuid=request.domain_uuid AND a.service_uuid=request.service_uuid AND b.phone_number=request.caller_number AND b.revoked_at IS NULL AND a.enabled FOR UPDATE OF a;
 ELSE
  IF proof !~ '^[a-f0-9]{64}$' THEN RETURN 0; END IF;
  SELECT a.* INTO account FROM v_pbx_cmb_accounts a WHERE a.domain_uuid=request.domain_uuid AND a.service_uuid=request.service_uuid AND a.id_hmac=proof AND a.enabled FOR UPDATE;
 END IF;
 IF NOT FOUND THEN RETURN 0; END IF;
 IF EXISTS(SELECT 1 FROM v_pbx_cmb_requests r WHERE r.domain_uuid=request.domain_uuid AND r.account_uuid=account.account_uuid AND r.request_uuid<>rid AND r.state IN ('authenticating','dialling','connected')) THEN RETURN 0; END IF;
 allowance=least(600,account.total_seconds-account.used_seconds-account.reserved_seconds);
 IF allowance<=0 THEN RETURN 0; END IF;
 IF proof IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM v_pbx_cmb_bindings b WHERE b.domain_uuid=request.domain_uuid AND b.service_uuid=request.service_uuid AND b.phone_number=request.caller_number AND b.revoked_at IS NULL AND b.account_uuid<>account.account_uuid) THEN RETURN 0; END IF;
  INSERT INTO v_pbx_cmb_bindings(domain_uuid,service_uuid,account_uuid,phone_number) VALUES(request.domain_uuid,request.service_uuid,account.account_uuid,request.caller_number) ON CONFLICT(domain_uuid,service_uuid,phone_number) WHERE revoked_at IS NULL DO NOTHING;
 END IF;
 UPDATE v_pbx_cmb_accounts SET reserved_seconds=reserved_seconds+allowance,updated_at=now() WHERE account_uuid=account.account_uuid;
 UPDATE v_pbx_cmb_requests SET account_uuid=account.account_uuid,reserved_seconds=allowance,state='dialling',updated_at=now() WHERE request_uuid=rid;
 RETURN allowance;
END $$;
-- Idempotent settlement: exact observed destination talk time; uncertain crash recovery charges
-- the bounded reservation rather than silently granting unmetered minutes.
CREATE OR REPLACE FUNCTION openweb_cmb_finish(rid uuid,seconds integer,result text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE request v_pbx_cmb_requests%ROWTYPE; charged integer;
BEGIN
 SELECT * INTO request FROM v_pbx_cmb_requests WHERE request_uuid=rid FOR UPDATE;
 IF NOT FOUND OR request.state IN ('completed','failed','cancelled') THEN RETURN false; END IF;
 charged=least(request.reserved_seconds,greatest(0,coalesce(seconds,request.reserved_seconds)));
 IF request.account_uuid IS NOT NULL THEN
  UPDATE v_pbx_cmb_accounts SET reserved_seconds=reserved_seconds-request.reserved_seconds,used_seconds=used_seconds+charged,updated_at=now() WHERE domain_uuid=request.domain_uuid AND account_uuid=request.account_uuid;
 END IF;
 UPDATE v_pbx_cmb_requests SET state=CASE WHEN connected_at IS NOT NULL THEN 'completed' ELSE 'failed' END,used_seconds=charged,reserved_seconds=0,completed_at=now(),lease_until=NULL,updated_at=now(),last_result=left(result,64) WHERE request_uuid=rid;
 RETURN true;
END $$;
COMMIT;
