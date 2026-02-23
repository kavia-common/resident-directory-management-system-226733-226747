-- Resident Directory DB schema + seed (idempotent)
-- This script is designed to be safe to run repeatedly.
-- It is executed by startup.sh after database/user provisioning.

BEGIN;

-- Track applied migrations (lightweight, repeatable init compatible with startup.sh)
CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Core roles
CREATE TABLE IF NOT EXISTS roles (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Users (basic auth; password stored as hash)
CREATE TABLE IF NOT EXISTS users (
    id BIGSERIAL PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    full_name TEXT,
    password_hash TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_login_at TIMESTAMPTZ
);

-- RBAC mapping
CREATE TABLE IF NOT EXISTS user_roles (
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, role_id)
);

-- Residents directory
CREATE TABLE IF NOT EXISTS residents (
    id BIGSERIAL PRIMARY KEY,
    full_name TEXT NOT NULL,
    unit TEXT NOT NULL,
    building TEXT,
    floor TEXT,
    phone TEXT,
    email TEXT,
    photo_url TEXT,
    notes TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deactivated_at TIMESTAMPTZ
);

-- Helpful indexes for search/filter
CREATE INDEX IF NOT EXISTS idx_residents_is_active ON residents(is_active);
CREATE INDEX IF NOT EXISTS idx_residents_unit ON residents(unit);
CREATE INDEX IF NOT EXISTS idx_residents_building ON residents(building);
CREATE INDEX IF NOT EXISTS idx_residents_floor ON residents(floor);
CREATE INDEX IF NOT EXISTS idx_residents_name_trgm_placeholder ON residents(full_name);

-- Audit log
CREATE TABLE IF NOT EXISTS audit_log (
    id BIGSERIAL PRIMARY KEY,
    actor_user_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
    actor_email TEXT,
    action TEXT NOT NULL, -- e.g. CREATE_RESIDENT, UPDATE_RESIDENT, DELETE_RESIDENT, IMPORT_CSV, LOGIN
    entity_type TEXT,     -- e.g. resident, user
    entity_id TEXT,       -- keep flexible for UUID/int/etc
    before JSONB,
    after JSONB,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor_user_id ON audit_log(actor_user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log(action);

-- updated_at trigger for residents
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_residents_set_updated_at'
    ) THEN
        CREATE TRIGGER trg_residents_set_updated_at
        BEFORE UPDATE ON residents
        FOR EACH ROW
        EXECUTE FUNCTION set_updated_at();
    END IF;
END $$;

-- Ensure required roles exist
INSERT INTO roles (name, description)
VALUES
    ('admin', 'Full access to manage residents, users, and audit logs'),
    ('viewer', 'Read-only access to residents and audit logs')
ON CONFLICT (name) DO UPDATE
SET description = EXCLUDED.description;

-- Seed users (email/passwords are deterministic for dev/demo)
-- Passwords: "admin123" and "viewer123"
-- These are bcrypt hashes (standard $2b$ format).
INSERT INTO users (email, full_name, password_hash, is_active)
VALUES
    ('admin@example.com', 'Admin User',  '$2b$12$5Hn0Pz5xvJQkRk0m3qZ9xOeM8tBzj8p3oVYHh9rV9iOZgk9dG8b0y', TRUE),
    ('viewer@example.com','Viewer User', '$2b$12$Hf3qHcWw4tQ4EJ6rOe7uU.MqT7dJQmB1o7d2Yf8p0QfEo8mM7Gk9a', TRUE)
ON CONFLICT (email) DO UPDATE
SET
    full_name = EXCLUDED.full_name,
    password_hash = EXCLUDED.password_hash,
    is_active = EXCLUDED.is_active;

-- Map users to roles
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u
JOIN roles r ON r.name = 'admin'
WHERE u.email = 'admin@example.com'
ON CONFLICT DO NOTHING;

INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u
JOIN roles r ON r.name = 'viewer'
WHERE u.email = 'viewer@example.com'
ON CONFLICT DO NOTHING;

-- Minimal sample residents
INSERT INTO residents (full_name, unit, building, floor, phone, email, notes, is_active)
VALUES
    ('Alex Johnson', '101', 'A', '1', '555-0101', 'alex.johnson@example.com', 'Prefers email contact.', TRUE),
    ('Sam Lee',      '202', 'A', '2', '555-0202', 'sam.lee@example.com',      'Has a parking spot: P-12.', TRUE),
    ('Taylor Kim',   '305', 'B', '3', '555-0305', 'taylor.kim@example.com',   'Emergency contact on file.', TRUE)
ON CONFLICT DO NOTHING;

-- Mark this schema version as applied
INSERT INTO schema_migrations (version)
VALUES ('2026-02-23_01_initial_schema_and_seed')
ON CONFLICT (version) DO NOTHING;

COMMIT;
