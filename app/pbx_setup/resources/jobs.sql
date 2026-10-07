BEGIN;
CREATE TABLE IF NOT EXISTS v_pbx_jobs (
 job_uuid uuid PRIMARY KEY,
 domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 kind text NOT NULL CHECK(kind IN ('callback','wakeup')),
 queue_number text NOT NULL DEFAULT '', target_number text NOT NULL, internal_target boolean NOT NULL DEFAULT false,
 state text NOT NULL DEFAULT 'waiting' CHECK(state IN ('waiting','starting','calling','completed','failed','cancelled')),
 due_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL DEFAULT now()+interval '1 day',
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 attempts integer NOT NULL DEFAULT 0, max_attempts integer NOT NULL DEFAULT 3 CHECK(max_attempts BETWEEN 1 AND 5),
 lease_until timestamptz, call_uuid uuid, agent_number text, last_result text NOT NULL DEFAULT '',
 request_key text NOT NULL, UNIQUE(domain_uuid,request_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS openweb_job_active_target ON v_pbx_jobs(domain_uuid,kind,queue_number,target_number)
 WHERE state IN ('waiting','starting','calling');
CREATE UNIQUE INDEX IF NOT EXISTS openweb_job_active_agent ON v_pbx_jobs(domain_uuid,agent_number)
 WHERE agent_number IS NOT NULL AND state IN ('starting','calling');
CREATE INDEX IF NOT EXISTS openweb_job_due ON v_pbx_jobs(due_at) WHERE state='waiting';
CREATE TABLE IF NOT EXISTS v_pbx_hotel_rooms (
 domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 number text NOT NULL, room_name text NOT NULL, guest_name text NOT NULL DEFAULT '',
 occupied boolean NOT NULL DEFAULT false, do_not_disturb boolean NOT NULL DEFAULT false,
 room_status text NOT NULL DEFAULT 'clean' CHECK(room_status IN ('clean','dirty','inspected','maintenance')),
 checked_in_at timestamptz, updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(domain_uuid,number)
);
CREATE TABLE IF NOT EXISTS v_pbx_hotel_events (
 event_uuid uuid PRIMARY KEY, domain_uuid uuid NOT NULL REFERENCES v_domains(domain_uuid) ON DELETE CASCADE,
 room_number text NOT NULL, action text NOT NULL, detail text NOT NULL DEFAULT '',
 created_at timestamptz NOT NULL DEFAULT now(), user_uuid uuid
);
COMMIT;
