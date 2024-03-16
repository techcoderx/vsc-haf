-- Drop all FK constraints
ALTER TABLE vsc_app.l1_operations DROP CONSTRAINT IF EXISTS l1_op_user_id_fk;
ALTER TABLE vsc_app.l1_operations DROP CONSTRAINT IF EXISTS l1_op_type_fk;
ALTER TABLE vsc_app.l1_users DROP CONSTRAINT IF EXISTS l1_users_fk;
ALTER TABLE vsc_app.blocks DROP CONSTRAINT IF EXISTS block_proposed_in_op_fk;
ALTER TABLE vsc_app.blocks DROP CONSTRAINT IF EXISTS block_proposer_fk;
ALTER TABLE vsc_app.contracts DROP CONSTRAINT IF EXISTS contract_created_in_op_fk;
ALTER TABLE vsc_app.witnesses DROP CONSTRAINT IF EXISTS witness_account_fk;
ALTER TABLE vsc_app.witnesses DROP CONSTRAINT IF EXISTS witness_enabled_at_fk;
ALTER TABLE vsc_app.witnesses DROP CONSTRAINT IF EXISTS witness_disabled_at_fk;
ALTER TABLE vsc_app.multisig_txrefs DROP CONSTRAINT IF EXISTS multisig_txref_in_op_fk;
ALTER TABLE vsc_app.witness_toggle_archive DROP CONSTRAINT IF EXISTS witness_toggle_wid_fk;
ALTER TABLE vsc_app.witness_toggle_archive DROP CONSTRAINT IF EXISTS witness_toggle_op_id_fk;
ALTER TABLE vsc_app.keyauths_archive DROP CONSTRAINT IF EXISTS keyauths_uid_fk;
ALTER TABLE vsc_app.keyauths_archive DROP CONSTRAINT IF EXISTS keyauths_op_id_fk;

-- Drop all state providers
SELECT hive.app_state_provider_drop_all('vsc_app');

-- Remove context and drop schema
SELECT hive.app_remove_context('vsc_app');
DROP SCHEMA IF EXISTS vsc_app CASCADE;
DROP SCHEMA IF EXISTS vsc_api CASCADE;

-- Delete users
DROP OWNED BY vsc_owner CASCADE;
DROP ROLE vsc_owner;
DROP OWNED BY vsc_user CASCADE;
DROP ROLE vsc_user;