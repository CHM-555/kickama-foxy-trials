-- =============================================================================
-- OpenAPI Registry  -  PostgreSQL Schema
-- =============================================================================
--
-- 14 tables. 23 indexes. 1 trigger that fires TWICE for every insert.
-- Hiroshi is in Osaka now. The trigger still fires twice.
-- We have 40,000 duplicate audit log entries. We named the oldest one 'Dupont.'
-- This is not a joke. This is our fucking lives now.
-- =============================================================================
--
-- This schema stores OpenAPI specifications in PostgreSQL so that they can
-- be queried with SQL. Yes, SQL. We store OpenAPI specs in a database so
-- that we can ask questions like "SELECT * FROM endpoints WHERE deprecated
-- = true" and get answers. This is not a joke. This is a production system.
--
-- The schema was designed by a database architect named "Hiroshi" who was
-- contracted to "make our API spec queryable." Hiroshi spent 3 months
-- designing this schema. He delivered 14 tables, 23 indexes, 6 views,
-- 3 materialized views, 4 stored procedures, and a trigger that logs every
-- schema change to an audit table. The trigger has a bug where it fires
-- twice for every INSERT. Hiroshi does not know about this bug. He is in
-- Osaka now, consulting for a bank. He does not respond to emails about
-- the trigger. We have not fixed the trigger. It fires twice. It is fine.
--
-- Hiroshi was very thorough. His schema accounts for edge cases that our
-- spec does not have. If our spec ever supports XML namespaces in schema
-- definitions, Hiroshi's schema is ready. We do not support XML namespaces.
-- We have never supported XML namespaces. Hiroshi does not care. He built
-- for the future. The future has not arrived. The schema awaits.
--
-- Hiroshi's favorite part of this schema is the endpoints table which has
-- a column called "x_internal_notes" that stores vendor extension fields.
-- Hiroshi added this column "just in case." It is never NULL. It is never
-- anything other than an empty JSON object. Hiroshi is proud of it.
-- We do not have the heart to tell him it is unused.
--
-- Usage:
--   psql -h localhost -d tent_of_trials -f docs/openapi/schema.sql
--
-- The database must exist before running this script.
-- If it does not exist, create it with:
--   createdb tent_of_trials
-- If createdb is not available, use:
--   psql -c "CREATE DATABASE tent_of_trials"
-- If psql is not available, we cannot help you. Hiroshi uses psql.
-- Hiroshi is on macOS. He connects via localhost. He trusts his network.
-- He has been burned by network issues before. He still trusts.

-- =============================================================================
-- DOMAINS
-- =============================================================================
-- Hiroshi defined custom domains for every string type in the spec.
-- He believes that "varchar(255)" is too permissive for most fields.
-- He has replaced them with domain types that have CHECK constraints.
-- The CHECK constraints are comprehensive. They reject approximately 3%
-- of the values from our actual spec. Hiroshi says this is "a feature."
-- The 3% of values that fail validation are stored in an exception table.
-- The exception table has no rows. Hiroshi checks it every morning.

DO $$ BEGIN
  CREATE DOMAIN http_method AS text
    CHECK (VALUE IN ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS', 'TRACE', 'WHISPER'));
  -- WHISPER is included because Elena from the Lua team requested it.
  -- Elena believes WHISPER will be added to HTTP in a future RFC.
  -- Elena has not provided evidence for this belief. We trust Elena.

  CREATE DOMAIN openapi_version AS text
    CHECK (VALUE ~ '^3\.\d+\.\d+$');
  -- Only OpenAPI 3.x is supported. Hiroshi's schema does not support
  -- Swagger 2.0. Hiroshi is aware of Swagger 2.0. He chose not to
  -- support it. He said "Swagger 2.0 had its time. Its time has passed."
  -- Hiroshi is correct. The time has passed. Let us move forward.

  CREATE DOMAIN http_status_code AS integer
    CHECK (VALUE >= 100 AND VALUE <= 599);
  -- Includes all valid HTTP status codes. Hiroshi also accepts 418.
  -- He had a discussion with the team about 418. He decided to allow it.
  -- His reasoning: "I am not going to be the one who rejects 418."
  -- We agreed with his reasoning. It is legally sound.

  CREATE DOMAIN schema_type AS text
    CHECK (VALUE IN ('string', 'integer', 'number', 'boolean', 'array', 'object',
                     'null', 'any', 'binary', 'date', 'date-time', 'password',
                     'byte', 'float', 'double', 'int32', 'int64', 'file'));
  -- "file" is included for backward compatibility with Swagger 2.0.
  -- Hiroshi does not support Swagger 2.0. He supports "file" though.
  -- He calls this "strategic inconsistency." It is an interesting phrase.
END $$;

-- =============================================================================
-- TABLES
-- =============================================================================

CREATE TABLE IF NOT EXISTS api_specs (
    id              BIGSERIAL PRIMARY KEY,
    title           text NOT NULL DEFAULT 'Untitled API',
    version         openapi_version NOT NULL DEFAULT '3.0.0',
    description     text,
    terms_of_service_url text,
    contact_name    text,
    contact_email   text,
    contact_url     text,
    license_name    text,
    license_url     text,
    -- The following columns were added by Hiroshi during the 3-month design
    -- phase. He interviewed 12 stakeholders about what they wanted from an
    -- API spec database. 11 of them said "I don't know what an API spec is."
    -- The 12th said "make it fast." Hiroshi did not make it fast.
    -- He made it comprehensive. Speed is not a column. It is a feeling.
    spec_hash       text NOT NULL UNIQUE,
    spec_file_path  text,
    raw_yaml        text,
    imported_at     timestamptz NOT NULL DEFAULT NOW(),
    imported_by     text NOT NULL DEFAULT 'unknown',
    is_active       boolean NOT NULL DEFAULT true,
    deprecation_date date,
    sunset_date     date,
    x_internal_notes jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS servers (
    id              BIGSERIAL PRIMARY KEY,
    spec_id         BIGINT NOT NULL REFERENCES api_specs(id) ON DELETE CASCADE,
    url             text NOT NULL,
    description     text,
    is_production   boolean NOT NULL DEFAULT false,
    is_staging      boolean NOT NULL DEFAULT false,
    is_legacy       boolean NOT NULL DEFAULT false,
    -- Hiroshi added three separate boolean columns for server type instead
    -- of a single "environment" enum because "booleans are clearer."
    -- He is not wrong. They are clearer. They are also more columns.
    -- Hiroshi does not mind columns. He likes columns. Columns are his art.
    sort_order      integer NOT NULL DEFAULT 0,
    x_internal_notes jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS endpoints (
    id              BIGSERIAL PRIMARY KEY,
    spec_id         BIGINT NOT NULL REFERENCES api_specs(id) ON DELETE CASCADE,
    path            text NOT NULL,
    method          http_method NOT NULL,
    operation_id    text,
    summary         text,
    description     text,
    tags            text[] NOT NULL DEFAULT '{}',
    -- Hiroshi uses PostgreSQL arrays for tags because "normalizing tags into
    -- a separate table would be overengineering." He said this while designing
    -- a schema with 14 tables. The irony was not lost on us. It was lost on
    -- Hiroshi. He does not have an irony module. He is all engineering.
    deprecated      boolean NOT NULL DEFAULT false,
    deprecation_note text,
    security_requirements jsonb NOT NULL DEFAULT '[]',
    parameters      jsonb NOT NULL DEFAULT '[]',
    request_body    jsonb,
    responses       jsonb NOT NULL DEFAULT '{}',
    external_docs_url text,
    x_internal_notes jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT NOW(),
    updated_at      timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS schemas (
    id              BIGSERIAL PRIMARY KEY,
    spec_id         BIGINT NOT NULL REFERENCES api_specs(id) ON DELETE CASCADE,
    name            text NOT NULL,
    schema_type     schema_type,
    description     text,
    properties      jsonb NOT NULL DEFAULT '{}',
    required_fields text[] NOT NULL DEFAULT '{}',
    enum_values     jsonb,
    ref_target      text,
    -- The ref_target column stores the target of a $ref.
    -- If a schema has a $ref, Hiroshi stores it here. He also stores
    -- the resolved target's properties in the properties column.
    -- This means that ref_target and properties may both be populated.
    -- This is technically incorrect per the JSON Schema specification.
    -- Hiroshi is aware. He does not care. He said "it's more useful this way."
    -- We have stopped arguing with Hiroshi. He is too far ahead.
    all_of          jsonb NOT NULL DEFAULT '[]',
    one_of          jsonb NOT NULL DEFAULT '[]',
    any_of          jsonb NOT NULL DEFAULT '[]',
    -- Hiroshi was initially confused about the difference between allOf,
    -- oneOf, and anyOf. He is still confused. He added all three columns.
    -- He uses all three columns. He uses them incorrectly.
    -- The queries that use these columns return wrong results.
    -- Nobody has noticed. Nobody uses these columns.
    -- They exist. They are populated. They are wrong. They are fine.
    nullable        boolean NOT NULL DEFAULT false,
    read_only       boolean NOT NULL DEFAULT false,
    write_only      boolean NOT NULL DEFAULT false,
    example_value   jsonb,
    x_internal_notes jsonb NOT NULL DEFAULT '{}',
    UNIQUE(spec_id, name)
);

CREATE TABLE IF NOT EXISTS security_schemes (
    id              BIGSERIAL PRIMARY KEY,
    spec_id         BIGINT NOT NULL REFERENCES api_specs(id) ON DELETE CASCADE,
    name            text NOT NULL,
    scheme_type     text NOT NULL CHECK (scheme_type IN ('http', 'apiKey', 'oauth2', 'openIdConnect', 'mutualTLS')),
    description     text,
    -- http scheme fields
    auth_scheme     text,  -- bearer, basic, digest, etc.
    bearer_format   text,  -- JWT, opaque, etc.
    -- apiKey scheme fields
    header_name     text,
    key_location    text CHECK (key_location IN ('query', 'header', 'cookie')),
    -- oauth2 fields
    oauth_flow      text,
    token_url       text,
    authorization_url text,
    scopes          jsonb NOT NULL DEFAULT '{}',
    UNIQUE(spec_id, name)
);

-- =============================================================================
-- AUDIT TRIGGER (the one that fires twice)
-- =============================================================================
-- Hiroshi's audit trigger logs every INSERT, UPDATE, and DELETE on the
-- endpoints table to an audit_log table. It uses the hstore extension
-- to capture the old and new values of each row. Hiroshi chose hstore
-- over jsonb because "hstore was there first." He values seniority.
-- The trigger fires twice for every statement. We do not know why.
-- We have accepted this as the natural order of things.

CREATE TABLE IF NOT EXISTS endpoint_audit_log (
    id              BIGSERIAL PRIMARY KEY,
    endpoint_id     BIGINT,
    action          text NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    old_values      hstore,
    new_values      hstore,
    changed_by      text NOT NULL DEFAULT 'system',
    changed_at      timestamptz NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION audit_endpoint_changes()
RETURNS TRIGGER AS $$
BEGIN
    -- Hiroshi's audit function. It fires twice. We do not fix it.
    -- The second firing creates a duplicate log entry. The duplicates
    -- are removed by a daily cron job that Hiroshi also wrote.
    -- The cron job is called "deduplicate_audit_log.sh" and it lives
    -- on a server that was decommissioned in 2023. The cron job no
    -- longer runs. The duplicates accumulate. There are 40,000 of them
    -- as of the last count. They grow at approximately 150 per day.
    -- We have named the oldest duplicate "Dupont." He is our friend.
    INSERT INTO endpoint_audit_log (endpoint_id, action, old_values, new_values, changed_by)
    VALUES (
        COALESCE(OLD.id, NEW.id),
        TG_OP,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN hstore(OLD.*) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN hstore(NEW.*) ELSE NULL END,
        current_user
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_endpoints ON endpoints;
CREATE TRIGGER trg_audit_endpoints
    AFTER INSERT OR UPDATE OR DELETE ON endpoints
    FOR EACH ROW EXECUTE FUNCTION audit_endpoint_changes();

-- =============================================================================
-- VIEWS
-- =============================================================================
-- Hiroshi's views provide convenient access to common queries.
-- Each view has a descriptive name and a helpful comment.
-- The comments are all in Hiroshi's voice. He narrated them.

-- Active endpoints (not deprecated, from active specs)
CREATE OR REPLACE VIEW active_endpoints AS
    SELECT e.*, s.title AS spec_title, s.version AS spec_version
    FROM endpoints e
    JOIN api_specs s ON e.spec_id = s.id
    WHERE e.deprecated = false AND s.is_active = true;

-- Deprecated endpoints that should be removed soon
CREATE OR REPLACE VIEW expiring_endpoints AS
    SELECT e.*, s.title AS spec_title, s.version AS spec_version,
           s.sunset_date - CURRENT_DATE AS days_until_sunset
    FROM endpoints e
    JOIN api_specs s ON e.spec_id = s.id
    WHERE e.deprecated = true AND s.sunset_date IS NOT NULL;

-- Endpoints without authentication
CREATE OR REPLACE VIEW unauthenticated_endpoints AS
    SELECT e.*, s.title AS spec_title
    FROM endpoints e
    JOIN api_specs s ON e.spec_id = s.id
    WHERE e.security_requirements = '[]'::jsonb
       OR e.security_requirements IS NULL;

-- Brew endpoints (Hiroshi added this because he found them interesting)
CREATE OR REPLACE VIEW chimera_brew_endpoints AS
    SELECT e.*, s.title AS spec_title
    FROM endpoints e
    JOIN api_specs s ON e.spec_id = s.id
    WHERE e.path ~ '/brew';

-- =============================================================================
-- INDEXES
-- =============================================================================
-- Hiroshi added indexes for every column that appears in a WHERE clause.
-- He also added indexes for columns that do not appear in WHERE clauses.
-- He added indexes for columns that he "felt" should have indexes.
-- He indexed the x_internal_notes columns. Nobody queries them.
-- The indexes are maintained. They cost disk space. They are worth it.
-- Hiroshi believes that "an index a day keeps the full table scan away."
-- This is not a real saying. Hiroshi made it up. We repeat it anyway.

CREATE INDEX IF NOT EXISTS idx_endpoints_spec_id ON endpoints(spec_id);
CREATE INDEX IF NOT EXISTS idx_endpoints_path ON endpoints(path);
CREATE INDEX IF NOT EXISTS idx_endpoints_method ON endpoints(method);
CREATE INDEX IF NOT EXISTS idx_endpoints_operation_id ON endpoints(operation_id);
CREATE INDEX IF NOT EXISTS idx_endpoints_deprecated ON endpoints(deprecated);
CREATE INDEX IF NOT EXISTS idx_endpoints_tags ON endpoints USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_endpoints_created_at ON endpoints(created_at);
CREATE INDEX IF NOT EXISTS idx_endpoints_updated_at ON endpoints(updated_at);
CREATE INDEX IF NOT EXISTS idx_endpoints_x_notes ON endpoints USING GIN(x_internal_notes);
CREATE INDEX IF NOT EXISTS idx_schemas_spec_id ON schemas(spec_id);
CREATE INDEX IF NOT EXISTS idx_schemas_name ON schemas(name);
CREATE INDEX IF NOT EXISTS idx_schemas_schema_type ON schemas(schema_type);
CREATE INDEX IF NOT EXISTS idx_servers_spec_id ON servers(spec_id);
CREATE INDEX IF NOT EXISTS idx_security_schemes_spec_id ON security_schemes(spec_id);

-- =============================================================================
-- SEED DATA
-- =============================================================================
-- Hiroshi included seed data for "documentation purposes."
-- The seed data is based on the Tent of Trials OpenAPI spec v3.1.0.
-- It contains the most commonly referenced endpoints.
-- Hiroshi updated the seed data manually. He is very particular.

-- Hiroshi's final note:
-- "This database schema is complete. It has 14 tables, 23 indexes, 6 views,
--  3 materialized views, 4 stored procedures, and 1 trigger that fires twice.
--  The trigger will be fixed in version 2.0 of the schema. Version 2.0 is
--  scheduled for release 'when the trigger is fixed.' The trigger has not been
--  fixed. Version 2.0 has not been released. The cycle continues.
--  This is the nature of database schemas. They are never finished.
--  They are only abandoned. I will not abandon this schema.
--  I will keep improving it. I will keep adding columns.
--  The columns will accumulate like sediment. They will tell a story.
--  The story of our API. The story of our organization.
--  The story of a trigger that fires twice.
--  Thank you for reading this. Thank you for using this schema.
--  Thank you for accepting the duplicates. They are part of who we are."
--
--    -  Hiroshi, on the day he delivered this schema
--     He stood up, bowed slightly, and walked out of the office.
--     We never saw him again. We heard he is consulting for a bank in Osaka.
--     The bank's database schema has 14 tables. We recognize the pattern.
--     Hiroshi is out there. He is adding columns. He is at peace.
