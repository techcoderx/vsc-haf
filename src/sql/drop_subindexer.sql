ALTER TABLE vsc_app.blocks DROP CONSTRAINT IF EXISTS block_proposed_in_op_fk;
ALTER TABLE vsc_app.blocks DROP CONSTRAINT IF EXISTS block_proposer_fk;
ALTER TABLE vsc_app.election_results DROP CONSTRAINT IF EXISTS election_proposed_in_op_fk;
ALTER TABLE vsc_app.election_results DROP CONSTRAINT IF EXISTS election_proposer_fk;
ALTER TABLE vsc_app.election_result_members DROP CONSTRAINT IF EXISTS elected_members_epoch_fk;
ALTER TABLE vsc_app.election_result_members DROP CONSTRAINT IF EXISTS elected_members_user_id_fk;
ALTER TABLE vsc_app.l1_txs DROP CONSTRAINT IF EXISTS l1_txs_op_id_fk;
ALTER TABLE vsc_app.l1_txs DROP CONSTRAINT IF EXISTS l1_txs_details_fk;
ALTER TABLE vsc_app.l1_tx_multiauth DROP CONSTRAINT IF EXISTS l1_tx_multiauth_tx_id;
ALTER TABLE vsc_app.l1_tx_multiauth DROP CONSTRAINT IF EXISTS l1_tx_multiauth_user_id_fk;
ALTER TABLE vsc_app.l2_txs DROP CONSTRAINT IF EXISTS l2_txs_block_num_fk;
ALTER TABLE vsc_app.l2_txs DROP CONSTRAINT IF EXISTS l2_txs_details_fk;
ALTER TABLE vsc_app.l2_tx_multiauth DROP CONSTRAINT IF EXISTS l2_tx_multiauth_tx_id;
ALTER TABLE vsc_app.l2_tx_multiauth DROP CONSTRAINT IF EXISTS l2_tx_multiauth_did_fk;
ALTER TABLE vsc_app.transactions DROP CONSTRAINT IF EXISTS contract_call_contract_id_fk;
ALTER TABLE vsc_app.anchor_refs DROP CONSTRAINT IF EXISTS anchor_refs_block_num_fk;
ALTER TABLE vsc_app.anchor_ref_txs DROP CONSTRAINT IF EXISTS anchor_ref_txs_ref_id_fk;

TRUNCATE TABLE vsc_app.subindexer_state;
TRUNCATE TABLE vsc_app.election_result_members;
TRUNCATE TABLE vsc_app.election_results;
TRUNCATE TABLE vsc_app.blocks;
TRUNCATE TABLE vsc_app.l1_txs;
TRUNCATE TABLE vsc_app.l1_tx_multiauth;
TRUNCATE TABLE vsc_app.l2_txs;
TRUNCATE TABLE vsc_app.l2_tx_multiauth;
TRUNCATE TABLE vsc_app.transactions;
TRUNCATE TABLE vsc_app.anchor_refs;
TRUNCATE TABLE vsc_app.anchor_ref_txs;

SELECT setval(pg_get_serial_sequence('vsc_app.blocks', 'id'), 1, false);
SELECT setval(pg_get_serial_sequence('vsc_app.transactions', 'id'), 1, false);
SELECT setval(pg_get_serial_sequence('vsc_app.anchor_refs', 'id'), 1, false);

UPDATE vsc_app.withdrawal_request SET
    status = 1;

UPDATE vsc_app.witnesses SET
    last_block = NULL,
    produced = 0;