-- Drop all FK constraints
ALTER TABLE vsc_app.l1_operations DROP CONSTRAINT IF EXISTS l1_op_user_id_fk;
ALTER TABLE vsc_app.l1_operations DROP CONSTRAINT IF EXISTS l1_op_type_fk;
ALTER TABLE vsc_app.blocks DROP CONSTRAINT IF EXISTS block_announced_in_op_fk;
ALTER TABLE vsc_app.contracts DROP CONSTRAINT IF EXISTS contract_created_in_op_fk;
ALTER TABLE vsc_app.witnesses DROP CONSTRAINT IF EXISTS witness_account_fk;
ALTER TABLE vsc_app.witnesses DROP CONSTRAINT IF EXISTS witness_enabled_at_fk;
ALTER TABLE vsc_app.witnesses DROP CONSTRAINT IF EXISTS witness_disabled_at_fk;

-- Drop all state providers
SELECT hive.app_state_provider_drop_all('vsc_app');

-- Remove context and drop schema
SELECT hive.app_remove_context('vsc_app');
DROP SCHEMA IF EXISTS vsc_app CASCADE;
DROP SCHEMA IF EXISTS vsc_api CASCADE;