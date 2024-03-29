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