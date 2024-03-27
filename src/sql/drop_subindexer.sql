TRUNCATE TABLE vsc_app.subindexer_state;
TRUNCATE TABLE vsc_app.election_result_members;
TRUNCATE TABLE vsc_app.election_results;
TRUNCATE TABLE vsc_app.blocks;

UPDATE vsc_app.withdrawal_request SET
	status = 1;

UPDATE vsc_app.witnesses SET
	last_block = NULL,
	produced = 0;