SET ROLE vsc_owner;

DROP TYPE IF EXISTS vsc_app.subindexer_next_ops_type CASCADE;
CREATE TYPE vsc_app.subindexer_next_ops_type AS (
    first_op BIGINT,
    last_op BIGINT
);
CREATE OR REPLACE FUNCTION vsc_app.subindexer_next_ops(_bound BOOLEAN = FALSE)
RETURNS SETOF vsc_app.subindexer_next_ops_type
AS
$function$
DECLARE
    _first BIGINT;
    _last BIGINT;
BEGIN
    SELECT last_processed_op INTO _first FROM vsc_app.subindexer_state LIMIT 1;
    SELECT id INTO _last FROM vsc_app.l1_operations ORDER BY id DESC LIMIT 1;
    IF _first IS NULL THEN
        RAISE EXCEPTION 'last_processed_op in subindexer_state table cannot be null';
    ELSIF (_last IS NULL) OR (_first = _last) THEN
        RETURN QUERY (SELECT NULL::BIGINT AS first_op, NULL::BIGINT AS last_op);
        RETURN;
    END IF;
    IF ((_last - _first) > 1000::BIGINT) AND _bound THEN
        _last := _first+1000::BIGINT;
    END IF;
    _first := _first+1;
    RETURN QUERY (SELECT _first AS first_op, _last AS last_op);
    RETURN;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.subindexer_update_last_processed(_op_id BIGINT)
RETURNS void
AS
$function$
DECLARE
    _last BIGINT;
    _last_op BIGINT;
BEGIN
    SELECT last_processed_op INTO _last FROM vsc_app.subindexer_state LIMIT 1;
    SELECT id INTO _last_op FROM vsc_app.l1_operations ORDER BY id DESC LIMIT 1;
    IF _last IS NULL THEN
        RAISE EXCEPTION 'last_processed_op in subindexer_state table cannot be null';
    ELSIF _op_id <= _last THEN
        RAISE EXCEPTION '_op_id cannot be less than or equal to last_processed_op in subindexer_state table';
    ELSIF _op_id > _last_op THEN
        RAISE EXCEPTION '_op_id cannot be greater than the last indexed l1 operation';
    END IF;

    UPDATE vsc_app.subindexer_state SET
        last_processed_op=_op_id;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.subindexer_should_massive_sync()
RETURNS BOOLEAN
AS
$function$
DECLARE
    _first BIGINT;
    _last BIGINT;
BEGIN
    SELECT first_op, last_op INTO _first, _last
        FROM vsc_app.subindexer_next_ops(false);
    
    IF _first IS NULL OR _last IS NULL THEN
        RETURN FALSE;
    ELSE
        RETURN (_last - _first + 1) >= 100000;
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

DROP TYPE IF EXISTS vsc_app.vsc_op_type CASCADE;
CREATE TYPE vsc_app.vsc_op_type AS (
    id BIGINT,
    block_num INT,
    trx_in_block SMALLINT,
    op_pos INT,
    timestamp TIMESTAMP,
    op_type INTEGER,
    body TEXT
);
CREATE OR REPLACE FUNCTION vsc_app.enum_vsc_op(_first_op BIGINT, _last_op BIGINT)
RETURNS SETOF vsc_app.vsc_op_type
AS
$function$
BEGIN
    RETURN QUERY
        SELECT vo.id, vo.block_num, vo.trx_in_block, vo.op_pos, vo.ts AS timestamp, vo.op_type, ho.body::TEXT
            FROM vsc_app.l1_operations vo
            JOIN hive.operations_view ho ON
                vo.op_id = ho.id
            WHERE vo.id >= _first_op AND vo.id <= _last_op AND (vo.op_type = 3 OR vo.op_type = 4 OR vo.op_type = 5 OR vo.op_type = 6 OR vo.op_type = 8);
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_app.get_vsc_op_by_tx_hash(_trx_id VARCHAR, _op_pos INTEGER)
RETURNS SETOF vsc_app.vsc_op_type
AS
$function$
DECLARE
    _bn INTEGER;
    _tb SMALLINT;
BEGIN
    SELECT ho.block_num, ho.trx_in_block
        INTO _bn, _tb
        FROM hive.transactions_view ht
        JOIN hive.operations_view ho ON
            ho.block_num = ht.block_num AND ho.trx_in_block = ht.trx_in_block
        WHERE ht.trx_hash = decode(_trx_id, 'hex') AND ho.op_pos = _op_pos;
    RETURN QUERY
        SELECT id, block_num, trx_in_block, _op_pos, ts AS timestamp, op_type, ''
        FROM vsc_app.l1_operations
        WHERE block_num=_bn AND trx_in_block=_tb AND op_pos=_op_pos;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_app.witnesses_at_block CASCADE;
CREATE TYPE vsc_app.witnesses_at_block AS (
    name TEXT,
    consensus_did VARCHAR,
    weight INTEGER
);
CREATE OR REPLACE FUNCTION vsc_app.get_active_witnesses_at_block(_block_num INTEGER)
RETURNS SETOF vsc_app.witnesses_at_block
AS
$function$
BEGIN
    RETURN QUERY
        WITH toggle_state AS (
            SELECT
                wt.witness_id,
                wt.op_id,
                wt.id,
                wt.enabled,
                ROW_NUMBER() OVER (PARTITION BY wt.witness_id ORDER BY wt.op_id DESC) as row_num
            FROM vsc_app.witness_toggle_archive wt
            JOIN vsc_app.l1_operations o1 ON
                wt.last_updated = o1.id
            JOIN vsc_app.l1_operations o2 ON
                wt.op_id = o2.id
            WHERE o2.block_num <= _block_num AND o1.block_num >= (_block_num - 86400) AND wt.enabled = true
        ), keyauths_state AS (
            SELECT
                ka.user_id,
                ka.op_id,
                ka.id,
                ka.consensus_did,
                ROW_NUMBER() OVER (PARTITION BY ka.user_id ORDER BY ka.op_id DESC) as row_num
            FROM vsc_app.keyauths_archive ka
            JOIN vsc_app.l1_operations o2 ON
                ka.op_id = o2.id
            WHERE o2.block_num <= _block_num
        )
        SELECT
            a.name,
            ka.consensus_did,
            1
        FROM toggle_state l
        JOIN hive.vsc_app_accounts a ON
            a.id = l.witness_id
        JOIN keyauths_state ka ON
            ka.user_id = l.witness_id
        WHERE l.row_num = 1 AND ka.row_num = 1
        ORDER BY a.name ASC;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_app.get_election_at_epoch(_epoch INTEGER)
RETURNS SETOF vsc_app.witnesses_at_block
AS
$function$
BEGIN
    RETURN QUERY
        SELECT a.name, em.consensus_did, em.weight
            FROM vsc_app.election_result_members em
            JOIN hive.vsc_app_accounts a ON
                a.id = em.witness_id
            WHERE epoch = _epoch
            ORDER BY em.idx ASC;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_app.get_epoch_at_block(_block_num INTEGER)
RETURNS INTEGER
AS
$function$
BEGIN
    RETURN (
        SELECT epoch
            FROM vsc_app.election_results e
            JOIN vsc_app.l1_operations o ON
                o.id = e.proposed_in_op
            WHERE o.block_num <= _block_num
            ORDER BY epoch DESC
            LIMIT 1
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_app.get_election_at_block(_block_num INTEGER)
RETURNS SETOF vsc_app.witnesses_at_block
AS $function$
DECLARE
    _epoch INTEGER;
BEGIN
    SELECT vsc_app.get_epoch_at_block(_block_num) INTO _epoch;
    RETURN QUERY
        SELECT * FROM vsc_app.get_election_at_epoch(_epoch);
END $function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_app.last_election_info CASCADE;
CREATE TYPE vsc_app.last_election_info AS (
    epoch INTEGER,
    bh INTEGER,
    total_weight INTEGER
);

CREATE OR REPLACE FUNCTION vsc_app.get_last_election_at_block(_block_num INTEGER)
RETURNS SETOF vsc_app.last_election_info
AS $function$
BEGIN
    RETURN QUERY
        SELECT e.epoch, o.block_num, e.weight_total
            FROM vsc_app.election_results e
            JOIN vsc_app.l1_operations o ON
                o.id = e.proposed_in_op
            WHERE o.block_num <= _block_num
            ORDER BY epoch DESC
            LIMIT 1;
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_app.get_members_at_block(_block_num INTEGER)
RETURNS SETOF vsc_app.witnesses_at_block
AS
$function$
DECLARE
    _epoch INTEGER;
BEGIN
    SELECT vsc_app.get_epoch_at_block(_block_num) INTO _epoch;
    IF _epoch IS NULL THEN
        RETURN QUERY SELECT * FROM vsc_app.get_active_witnesses_at_block(_block_num);
        RETURN;
    ELSE
        RETURN QUERY SELECT * FROM vsc_app.get_election_at_epoch(_epoch);
        RETURN;
    END IF;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_app.block_schedule_params CASCADE;
CREATE TYPE vsc_app.block_schedule_params AS (
    rnd_length INTEGER,
    total_rnds INTEGER,
    mod_length INTEGER,
    mod3 INTEGER,
    past_rnd_height INTEGER,
    next_rnd_height INTEGER,
    block_id VARCHAR,
    epoch INTEGER
);
CREATE OR REPLACE FUNCTION vsc_app.get_block_schedule_params(_block_num INTEGER)
RETURNS SETOF vsc_app.block_schedule_params
AS
$function$
DECLARE
    rnd_length INTEGER = 10;
    total_rnds INTEGER = 120;
    mod_length INTEGER = rnd_length * total_rnds;
    mod3 INTEGER = _block_num % mod_length;
    past_rnd_height INTEGER = _block_num - mod3;
    next_rnd_height INTEGER = _block_num + mod_length - mod3;
    block_id VARCHAR;
    epoch INTEGER;
BEGIN
    SELECT encode(hash, 'hex') INTO block_id FROM vsc_app.blocks_view WHERE num = past_rnd_height-1;
    SELECT vsc_app.get_epoch_at_block(_block_num) INTO epoch;

    RETURN QUERY SELECT rnd_length, total_rnds, mod_length, mod3, past_rnd_height, next_rnd_height, block_id, epoch;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_app.push_block(
    _proposed_in_op BIGINT,
    _proposer VARCHAR,
    _block_hash VARCHAR,
    _block_header_hash VARCHAR,
    _br_start INTEGER,
    _br_end INTEGER,
    _merkle BYTEA,
    _sig BYTEA,
    _bv BYTEA,
    _txs jsonb,
    _voted_weight INTEGER
)
RETURNS void
AS
$function$
DECLARE
    _acc_id INTEGER;
    _new_block_id INTEGER;
    _tx jsonb;
BEGIN
    SELECT id INTO _acc_id FROM hive.vsc_app_accounts WHERE name=_proposer;
    INSERT INTO vsc_app.l2_blocks(proposed_in_op, proposer, block_hash, block_header_hash, br_start, br_end, merkle_root, voted_weight, sig, bv)
        VALUES(_proposed_in_op, _acc_id, _block_hash, _block_header_hash, _br_start, _br_end, _merkle, _voted_weight, _sig, _bv)
        RETURNING id INTO _new_block_id;
    
    IF EXISTS (SELECT 1 FROM vsc_app.witnesses w WHERE w.id=_acc_id) THEN
        UPDATE vsc_app.witnesses SET
            last_block=_new_block_id,
            produced=produced+1
        WHERE id=_acc_id;
    END IF;

    FOR _tx IN SELECT * FROM jsonb_array_elements(_txs)
    LOOP
        IF (_tx->>'type')::INT = 1 THEN
            PERFORM vsc_app.push_l2_contract_call_tx(_tx->>'id', _new_block_id, (_tx->>'index')::SMALLINT, _tx->>'contract_id', _tx->>'action', (_tx->'payload')::jsonb, (SELECT ARRAY(SELECT jsonb_array_elements_text(_tx->'callers'))), (_tx->>'nonce')::INT);
        ELSIF (_tx->>'type')::INT = 2 THEN
            PERFORM vsc_app.push_l2_contract_output_tx(_tx->>'id', _new_block_id, (_tx->>'index')::SMALLINT, _tx->>'contract_id', (SELECT ARRAY(SELECT jsonb_array_elements_text(_tx->'inputs'))), (_tx->>'io_gas')::INT, (_tx->'results')::jsonb);
        ELSIF (_tx->>'type')::INT = 5 THEN
            PERFORM vsc_app.push_anchor_ref(_tx->>'id', _new_block_id, (_tx->>'index')::SMALLINT, _tx->>'data', (SELECT ARRAY(SELECT jsonb_array_elements_text(_tx->'txs'))));
        END IF;
    END LOOP;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.push_l2_contract_call_tx(
    _id VARCHAR,
    _l2_block_num INTEGER,
    _index SMALLINT,
    _contract_id VARCHAR,
    _contract_action VARCHAR,
    _payload jsonb,
    _callers VARCHAR[],
    _nonce INTEGER
)
RETURNS void
AS
$function$
DECLARE
    _new_l2_transaction_id BIGINT;
    _caller VARCHAR;
    _caller_id INTEGER;
BEGIN
    IF (SELECT EXISTS (SELECT 1 FROM vsc_app.l2_txs WHERE id=_id)) THEN
        RETURN;
    END IF;

    INSERT INTO vsc_app.contract_calls(contract_id, contract_action, payload)
        VALUES(_contract_id, _contract_action, _payload)
        RETURNING id INTO _new_l2_transaction_id;

    INSERT INTO vsc_app.l2_txs(id, block_num, idx_in_block, tx_type, nonce, details)
        VALUES(_id, _l2_block_num, _index, 1, _nonce, _new_l2_transaction_id);

    FOREACH _caller IN ARRAY _callers
    LOOP
        _caller_id := NULL;
        SELECT id INTO _caller_id FROM vsc_app.dids WHERE did=_caller;
        IF _caller_id IS NULL THEN
            INSERT INTO vsc_app.dids(did) VALUES(_caller) RETURNING id INTO _caller_id;
        END IF;
        INSERT INTO vsc_app.l2_tx_multiauth(id, did)
            VALUES(_id, _caller_id);
    END LOOP;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.push_l2_contract_output_tx(
    _id VARCHAR,
    _l2_block_num INTEGER,
    _index SMALLINT,
    _contract_id VARCHAR,
    _inputs VARCHAR[],
    _io_gas INTEGER,
    _results jsonb
)
RETURNS void
AS
$function$
DECLARE
    _input VARCHAR;
    _input_tx_id BIGINT;

    _bn INTEGER;
    _tb SMALLINT;
BEGIN
    IF (SELECT EXISTS (SELECT 1 FROM vsc_app.l2_txs WHERE id=_id)) THEN
        RETURN;
    END IF;

    FOREACH _input IN ARRAY _inputs
    LOOP
        IF LENGTH(_input) = 40 THEN
            SELECT block_num, trx_in_block INTO _bn, _tb
                FROM vsc_app.transactions_view
                WHERE trx_hash = decode(_input, 'hex');
            SELECT details INTO _input_tx_id FROM vsc_app.l1_txs WHERE id = (
                SELECT id
                FROM vsc_app.l1_operations
                WHERE block_num = _bn AND trx_in_block = _tb AND op_type = 5
                LIMIT 1
                -- which one if there are multiple contract calls in the same l1 tx???
                -- op_pos is currently not provided in contract output on IPFS
            );
        ELSE
            SELECT details INTO _input_tx_id FROM vsc_app.l2_txs WHERE id = _input;
        END IF;
        IF _input_tx_id IS NULL THEN
            CONTINUE;
        END IF;
        UPDATE vsc_app.contract_calls SET
            io_gas = _io_gas,
            contract_output = _results
        WHERE id = _input_tx_id;
    END LOOP;

    IF _input_tx_id IS NOT NULL THEN
        INSERT INTO vsc_app.l2_txs(id, block_num, idx_in_block, tx_type, details)
            VALUES(_id, _l2_block_num, _index, 2, _input_tx_id);
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.push_anchor_ref(
    _id VARCHAR,
    _l2_block_num INTEGER,
    _index SMALLINT,
    _root VARCHAR,
    _txs VARCHAR[]
)
RETURNS void
AS
$function$
DECLARE
    _ref_id INTEGER;
    i INTEGER;
BEGIN
    INSERT INTO vsc_app.anchor_refs(cid, block_num, idx_in_block, tx_root)
        VALUES(_id, _l2_block_num, _index, decode(_root, 'hex'))
        RETURNING id INTO _ref_id;

    FOR i IN 1 .. array_upper(_txs, 1)
    LOOP
        INSERT INTO vsc_app.anchor_ref_txs(ref_id, tx_id, idx_in_ref)
            VALUES(_ref_id, decode(_txs[i], 'hex'), i-1);
    END LOOP;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_l1_call_tx(
    _in_op BIGINT,
    _callers VARCHAR[],
    _caller_auths SMALLINT[],
    _contract_id VARCHAR,
    _contract_action VARCHAR,
    _payload jsonb -- normalised into single element jsonb array
)
RETURNS void
AS
$function$
DECLARE
    _caller_id INTEGER;
    _new_l2_transaction_id BIGINT;
    i INTEGER;
BEGIN
    IF (SELECT ARRAY_LENGTH(_callers, 1)) != (SELECT ARRAY_LENGTH(_caller_auths, 1)) THEN
        RAISE EXCEPTION 'callers and caller_auths must have the same array length';
    END IF;

    INSERT INTO vsc_app.contract_calls(contract_id, contract_action, payload)
        VALUES(_contract_id, _contract_action, _payload)
        RETURNING id INTO _new_l2_transaction_id;

    INSERT INTO vsc_app.l1_txs(id, details)
        VALUES(_in_op, _new_l2_transaction_id);

    FOR i IN array_lower(_callers, 1) .. array_upper(_callers, 1)
    LOOP
        IF _caller_auths[i] != 1 AND _caller_auths[i] != 2 THEN
            RAISE EXCEPTION 'caller auths must be either 1s or 2s.';
        END IF;
        _caller_id := NULL;
        SELECT id INTO _caller_id FROM hive.vsc_app_accounts WHERE name=_callers[i];
        IF _caller_id IS NULL THEN
            RAISE EXCEPTION 'hive username % does not exist', _callers[i];
        END IF;
        INSERT INTO vsc_app.l1_tx_multiauth(id, user_id, auth_type)
            VALUES(_in_op, _caller_id, _caller_auths[i]);
    END LOOP;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_election_result(
    _proposed_in_op BIGINT,
    _proposer VARCHAR,
    _epoch INTEGER,
    _data_cid VARCHAR,
    _sig BYTEA,
    _bv BYTEA,
    _elected_members INTEGER[],
    _elected_keys VARCHAR[],
    _weights INTEGER[],
    _weight_total INTEGER,
    _voted_weight INTEGER
)
RETURNS void
AS
$function$
DECLARE
    _acc_id INTEGER;
    _em INTEGER;
    _ek VARCHAR;
    i INTEGER;
BEGIN
    IF (SELECT EXISTS (SELECT 1 FROM vsc_app.election_results WHERE epoch=_epoch)) THEN
        RETURN;
    END IF;
    SELECT id INTO _acc_id FROM hive.vsc_app_accounts WHERE name=_proposer;
    INSERT INTO vsc_app.election_results(epoch, proposed_in_op, proposer, data_cid, voted_weight, weight_total, sig, bv)
        VALUES(_epoch, _proposed_in_op, _acc_id, _data_cid, _voted_weight, _weight_total, _sig, _bv);

    IF (SELECT ARRAY_LENGTH(_elected_members, 1)) != (SELECT ARRAY_LENGTH(_elected_keys, 1)) THEN
        RAISE EXCEPTION 'elected members and keys must have the same array length';
    ELSIF (SELECT ARRAY_LENGTH(_elected_members, 1)) != (SELECT ARRAY_LENGTH(_weights, 1)) THEN
        RAISE EXCEPTION 'elected members and weights must have the same array length';
    END IF;

    FOR i IN array_lower(_elected_members, 1) .. array_upper(_elected_members, 1)
    LOOP
        INSERT INTO vsc_app.election_result_members(epoch, witness_id, consensus_did, weight, idx)
            VALUES (_epoch, _elected_members[i], _elected_keys[i], _weights[i], i::SMALLINT);
    END LOOP;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.update_withdrawal_statuses(_in_op_ids BIGINT[], _status VARCHAR, _current_block_num INTEGER)
RETURNS void
AS
$function$
DECLARE
    _status_id SMALLINT;
    _status_id_failed SMALLINT;
    _status_id_completed SMALLINT;
BEGIN
    SELECT id INTO _status_id FROM vsc_app.withdrawal_status WHERE name=_status;
    IF _status_id IS NULL THEN
        RAISE EXCEPTION 'status does not exist';
    END IF;

    UPDATE vsc_app.withdrawal_request SET
        status=_status_id
    WHERE in_op = ANY(_in_op_ids);

    SELECT id INTO _status_id_failed FROM vsc_app.withdrawal_status WHERE name='failed';
    SELECT id INTO _status_id_completed FROM vsc_app.withdrawal_status WHERE name='completed';
    UPDATE vsc_app.withdrawal_request SET
        status=_status_id_failed
    WHERE in_op < (
        SELECT id
        FROM vsc_app.l1_operations
        WHERE block_num < (_current_block_num - 28800)
        ORDER BY id DESC
        LIMIT 1
    ) AND status != _status_id_completed;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_contract(
    _created_in_op BIGINT,
    _contract_id VARCHAR,
    _contract_name VARCHAR,
    _contract_description VARCHAR,
    _code_hash VARCHAR,
    _proof_hash VARCHAR = NULL,
    _proof_sig BYTEA = NULL,
    _proof_bv BYTEA = NULL)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.contracts(contract_id, created_in_op, name, description, code, proof_hash, proof_sig, proof_bv)
        VALUES(_contract_id, _created_in_op, _contract_name, _contract_description, _code_hash, _proof_hash, _proof_sig, _proof_bv);
END
$function$
LANGUAGE plpgsql VOLATILE;