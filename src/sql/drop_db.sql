-- Drop all FK constraints
ALTER TABLE vsc_app.table_name DROP CONSTRAINT IF EXISTS table_fk_name;

-- Drop all state providers
SELECT hive.app_state_provider_drop_all('vsc_app');

-- Remove context and drop schema
SELECT hive.app_remove_context('vsc_app');
DROP SCHEMA IF EXISTS vsc_app CASCADE;
DROP SCHEMA IF EXISTS vsc_api CASCADE;