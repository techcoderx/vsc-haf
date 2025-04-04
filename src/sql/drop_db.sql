-- Drop all FK constraints
ALTER TABLE vsc_mainnet.l1_operations DROP CONSTRAINT IF EXISTS l1_op_user_id_fk;
ALTER TABLE vsc_mainnet.l1_operations DROP CONSTRAINT IF EXISTS l1_op_type_fk;
ALTER TABLE vsc_mainnet.l1_users DROP CONSTRAINT IF EXISTS l1_users_fk;
ALTER TABLE vsc_mainnet.witnesses DROP CONSTRAINT IF EXISTS witness_account_fk;
ALTER TABLE vsc_mainnet.witnesses DROP CONSTRAINT IF EXISTS witness_enabled_at_fk;
ALTER TABLE vsc_mainnet.witnesses DROP CONSTRAINT IF EXISTS witness_disabled_at_fk;

-- Drop all state providers
SELECT hive.app_state_provider_drop_all('vsc_mainnet');

-- Remove context and drop schema
SELECT hive.app_remove_context('vsc_mainnet');
DROP SCHEMA IF EXISTS vsc_mainnet CASCADE;
DROP SCHEMA IF EXISTS vsc_mainnet_api CASCADE;

-- Delete users
DROP OWNED BY vsc_owner CASCADE;
DROP ROLE vsc_owner;
DROP OWNED BY vsc_user CASCADE;
DROP ROLE vsc_user;