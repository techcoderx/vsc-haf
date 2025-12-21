-- Drop all FK constraints
ALTER TABLE magi_app.l1_operations DROP CONSTRAINT IF EXISTS l1_op_user_id_fk;
ALTER TABLE magi_app.l1_operations DROP CONSTRAINT IF EXISTS l1_op_type_fk;
ALTER TABLE magi_app.l1_users DROP CONSTRAINT IF EXISTS l1_users_fk;
ALTER TABLE magi_app.witnesses DROP CONSTRAINT IF EXISTS witness_account_fk;
ALTER TABLE magi_app.witnesses DROP CONSTRAINT IF EXISTS witness_enabled_at_fk;
ALTER TABLE magi_app.witnesses DROP CONSTRAINT IF EXISTS witness_disabled_at_fk;

-- Drop all state providers
SELECT hive.app_state_provider_drop_all('magi_app');

-- Remove context and drop schema
SELECT hive.app_remove_context('magi_app');
DROP SCHEMA IF EXISTS magi_app CASCADE;
DROP SCHEMA IF EXISTS magi_api CASCADE;

-- Delete users
DROP OWNED BY magi_owner CASCADE;
DROP ROLE magi_owner;
DROP OWNED BY magi_user CASCADE;
DROP ROLE magi_user;