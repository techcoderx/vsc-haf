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
            WHERE vo.id >= _first_op AND vo.id <= _last_op AND vo.op_type = ANY('{3,4,5,6,8,12}'::INT[]);
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
    _new_tx_id INTEGER;
    _new_tx_detail_id BIGINT;
    _tx jsonb;
    _callers VARCHAR[];
    _caller VARCHAR;
BEGIN
    SELECT id INTO _acc_id FROM hive.vsc_app_accounts WHERE name=_proposer;
    SELECT l2_head_block+1 INTO _new_block_id FROM vsc_app.subindexer_state LIMIT 1;
    INSERT INTO vsc_app.l2_blocks(id, proposed_in_op, proposer, block_hash, block_header_hash, br_start, br_end, merkle_root, voted_weight, sig, bv)
        VALUES(_new_block_id, _proposed_in_op, _acc_id, _block_hash, _block_header_hash, _br_start, _br_end, _merkle, _voted_weight, _sig, _bv);
    UPDATE vsc_app.subindexer_state SET
        l2_head_block=_new_block_id;

    IF EXISTS (SELECT 1 FROM vsc_app.witnesses w WHERE w.id=_acc_id) THEN
        UPDATE vsc_app.witnesses SET
            last_block=_new_block_id,
            produced=produced+1
        WHERE id=_acc_id;
    END IF;

    FOR _tx IN SELECT * FROM jsonb_array_elements(_txs)
    LOOP
        SELECT ARRAY(SELECT jsonb_array_elements_text(_tx->'callers')) INTO _callers;
        IF (_tx->>'type')::INT = 1 THEN
            SELECT vsc_app.push_contract_call(_tx->>'contract_id', _tx->>'action', (_tx->'payload')::jsonb) INTO _new_tx_detail_id;
        ELSIF (_tx->>'type')::INT = 3 THEN
            SELECT vsc_app.push_transfer_tx((_tx->>'amount')::INTEGER, _tx->>'from', _tx->>'to', _tx->>'tk', _tx->>'memo') INTO _new_tx_detail_id;
        ELSIF (_tx->>'type')::INT = 4 THEN
            SELECT vsc_app.push_l2_withdraw_tx((_tx->>'amount')::INTEGER, _tx->>'from', _tx->>'to', _tx->>'tk', _tx->>'memo') INTO _new_tx_detail_id;
        ELSIF (_tx->>'type')::INT = 2 THEN
            PERFORM vsc_app.push_l2_contract_output_tx(_tx->>'id', _new_block_id, (_tx->>'index')::SMALLINT, _tx->>'contract_id', (SELECT ARRAY(SELECT jsonb_array_elements_text(_tx->'inputs'))), (_tx->>'io_gas')::INT, (_tx->'results')::jsonb);
        ELSIF (_tx->>'type')::INT = 5 THEN
            PERFORM vsc_app.push_anchor_ref(_tx->>'id', _new_block_id, (_tx->>'index')::SMALLINT, _tx->>'data', (SELECT ARRAY(SELECT jsonb_array_elements_text(_tx->'txs'))));
        ELSIF (_tx->>'type')::INT = 6 THEN
            PERFORM vsc_app.push_events(_tx->>'id', _new_block_id, (_tx->>'index')::SMALLINT, (_tx->'body')::jsonb);
        END IF;

        IF (_tx->>'type')::INT = ANY('{1,3,4}'::INT[]) AND _new_tx_detail_id != -1::BIGINT THEN
            INSERT INTO vsc_app.l2_txs(cid, block_num, idx_in_block, tx_type, nonce, details)
                VALUES(_tx->>'id', _new_block_id, (_tx->>'index')::SMALLINT, (_tx->>'type')::INT, (_tx->>'nonce')::INT, _new_tx_detail_id)
                RETURNING id INTO _new_tx_id;

            FOREACH _caller IN ARRAY _callers
            LOOP
                PERFORM vsc_app.insert_tx_auth_did(_new_tx_id, _caller, (SELECT ts FROM vsc_app.l1_operations WHERE id = _proposed_in_op));
            END LOOP;
        END IF;
    END LOOP;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_tx_auth_did(
    _id INTEGER,
    _did VARCHAR,
    _ts TIMESTAMP
)
RETURNS INTEGER
AS $function$
DECLARE
    _did_id INTEGER = NULL;
    _count INTEGER := 0;
BEGIN
    SELECT id, count INTO _did_id, _count FROM vsc_app.dids WHERE did=_did;
    IF _did_id IS NULL THEN
        INSERT INTO vsc_app.dids(did) VALUES(_did) RETURNING id INTO _did_id;
    END IF;
    IF _id IS NOT NULL AND _ts IS NOT NULL THEN
        INSERT INTO vsc_app.l2_tx_multiauth(id, did, nonce_counter)
            VALUES(_id, _did_id, COALESCE(_count, 0)+1);
        UPDATE vsc_app.dids SET
            count = COALESCE(_count, 0)+1,
            last_op_ts = _ts
        WHERE id=_did_id;
    END IF;
    RETURN _did_id;
END $function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.push_contract_call(
    _contract_id VARCHAR,
    _contract_action VARCHAR,
    _payload jsonb
)
RETURNS BIGINT AS $$
DECLARE
    _new_call_id BIGINT;
BEGIN
    INSERT INTO vsc_app.contract_calls(contract_id, contract_action, payload)
        VALUES(_contract_id, _contract_action, _payload)
        RETURNING id INTO _new_call_id;
    RETURN _new_call_id;
END $$
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
    _input_tx_ids BIGINT[] = '{}';
    _input_pos INTEGER = 0;

    _i1 VARCHAR; -- parsed l1 tx hash
    _i2 VARCHAR; -- parsed l1 op_pos in string
    _i3 INTEGER; -- parsed l1 op_pos in integer
    _bn INTEGER;
    _tb SMALLINT;
    _g2 jsonb; -- unparsed io_gas for the specific call
BEGIN
    IF (SELECT EXISTS (SELECT 1 FROM vsc_app.contract_outputs WHERE id=_id)) THEN
        RETURN;
    END IF;

    FOREACH _input IN ARRAY _inputs
    LOOP
        IF LENGTH(_input) < 59 THEN
            SELECT SPLIT_PART(_input, '-', 1) INTO _i1;
            SELECT SPLIT_PART(_input, '-', 2) INTO _i2;
            IF LENGTH(_i2) > 0 THEN
                _i3 := (_i2::INTEGER);
            ELSE
                _i3 := 0;
            END IF;
            SELECT block_num, trx_in_block INTO _bn, _tb
                FROM vsc_app.transactions_view
                WHERE trx_hash = decode(_i1, 'hex');
            SELECT details INTO _input_tx_id FROM vsc_app.l1_txs WHERE id = (
                SELECT id
                FROM vsc_app.l1_operations
                WHERE block_num = _bn AND trx_in_block = _tb AND op_pos = _i3 AND op_type = 5
            );
        ELSE
            SELECT details INTO _input_tx_id FROM vsc_app.l2_txs WHERE cid = _input;
        END IF;
        IF _input_tx_id IS NULL THEN
            CONTINUE;
        END IF;
        _g2 := (_results -> _input_pos) -> 'IOGas';
        UPDATE vsc_app.contract_calls SET
            io_gas = (SELECT CASE WHEN jsonb_typeof(_g2) = 'number' THEN _g2::INTEGER ELSE 0 END),
            contract_output_tx_id = _id,
            contract_output = (_results -> _input_pos)
        WHERE id = _input_tx_id;
        SELECT ARRAY_APPEND(_input_tx_ids, _input_tx_id) INTO _input_tx_ids;
        _input_pos := _input_pos+1;
    END LOOP;

    -- If we processed any input txs, insert the corresponding output tx into l2_txs
    IF _input_tx_id IS NOT NULL THEN
        INSERT INTO vsc_app.contract_outputs(id, block_num, idx_in_block, contract_id, total_io_gas)
            VALUES(_id, _l2_block_num, _index, _contract_id, _io_gas);
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.push_transfer_tx(
    _amount INTEGER,
    _from VARCHAR,
    _to VARCHAR,
    _tk VARCHAR,
    _memo VARCHAR = NULL
)
RETURNS BIGINT AS $$
DECLARE
    _xfer_id BIGINT;
    _from_acctype SMALLINT;
    _from_id INTEGER = NULL;
    _to_acctype SMALLINT;
    _to_id INTEGER = NULL;
    _new_l2_tx_id INTEGER;
BEGIN
    -- prepare from id
    IF (SELECT starts_with(_from, 'did:')) THEN
        SELECT vsc_app.insert_tx_auth_did(NULL, _from, NULL) INTO _from_id;
        _from_acctype := 2::SMALLINT;
    ELSIF (SELECT starts_with(_from, 'hive:')) THEN
        SELECT id INTO _from_id FROM hive.vsc_app_accounts WHERE name=(SELECT SPLIT_PART(_from, ':', 2));
        _from_acctype := 1::SMALLINT;

        IF _from_id IS NULL THEN
            RAISE EXCEPTION 'sending from non-existent hive user'; -- this should never happen
        END IF;
    END IF;

    -- prepare to id
    IF (SELECT starts_with(_to, 'did:')) THEN
        SELECT vsc_app.insert_tx_auth_did(NULL, _to, NULL) INTO _to_id;
        _to_acctype := 2::SMALLINT;
    ELSIF (SELECT starts_with(_to, 'hive:')) THEN
        SELECT id INTO _to_id FROM hive.vsc_app_accounts WHERE name=(SELECT SPLIT_PART(_to, ':', 2));
        _to_acctype := 1::SMALLINT;

        IF _to_id IS NULL THEN
            RETURN -1; -- todo: handle sending to non-existent hive username
        END IF;
    ELSE
        -- assume hive account otherwise?
        SELECT id INTO _to_id FROM hive.vsc_app_accounts WHERE name=_to;
        _to_acctype := 1::SMALLINT;

        IF _to_id IS NULL THEN
            RETURN -1; -- todo: handle sending to non-existent hive username
        END IF;
    END IF;

    INSERT INTO vsc_app.transfers(from_acctype, from_id, to_acctype, to_id, amount, coin, memo)
        VALUES(_from_acctype, _from_id, _to_acctype, _to_id, _amount, (SELECT vsc_app.get_asset_id(_tk)), _memo)
        RETURNING id INTO _xfer_id;

    RETURN _xfer_id;
END $$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.push_l2_withdraw_tx(
    _amount INTEGER,
    _from VARCHAR,
    _to VARCHAR,
    _tk VARCHAR,
    _memo VARCHAR = NULL
)
RETURNS BIGINT AS $$
DECLARE
    _xfer_id BIGINT;
    _from_acctype SMALLINT;
    _from_id INTEGER = NULL;
    _to_id INTEGER = NULL;
    _new_l2_tx_id INTEGER;
    _nonce_counter INTEGER;
BEGIN
    -- prepare from id
    IF (SELECT starts_with(_from, 'did:')) THEN
        SELECT vsc_app.insert_tx_auth_did(NULL, _from, NULL) INTO _from_id;
        _from_acctype := 2::SMALLINT;

        SELECT wdrq_count INTO _nonce_counter FROM vsc_app.dids WHERE id=_from_id;
        _nonce_counter := COALESCE(_nonce_counter, 0)+1;
        UPDATE vsc_app.dids SET wdrq_count = _nonce_counter WHERE id=_from_id;
    ELSIF (SELECT starts_with(_from, 'hive:')) THEN
        SELECT id INTO _from_id FROM hive.vsc_app_accounts WHERE name=(SELECT SPLIT_PART(_from, ':', 2));
        _from_acctype := 1::SMALLINT;

        IF _from_id IS NULL THEN
            RAISE EXCEPTION 'sending from non-existent hive user, %', _from; -- this should never happen
        END IF;

        SELECT wdrq_count INTO _nonce_counter FROM vsc_app.l1_users WHERE id = _from_id;
        _nonce_counter := COALESCE(_nonce_counter, 0)+1;
        INSERT INTO vsc_app.l1_users(id, wdrq_count)
            VALUES(_from_id, _nonce_counter)
            ON CONFLICT(id) DO UPDATE SET wdrq_count = _nonce_counter; -- upsert
    END IF;

    -- prepare to id
    IF (SELECT starts_with(_to, 'hive:')) THEN
        _to := (SELECT SPLIT_PART(_to, ':', 2));
    END IF;
    SELECT id INTO _to_id FROM hive.vsc_app_accounts WHERE name=_to;
    IF _to_id IS NULL THEN
        RAISE EXCEPTION 'sending to non-existent hive user %', _to; -- this shouldn't happen either unless vsc-node doesn't check this properly
    END IF;

    INSERT INTO vsc_app.l2_withdrawals(from_acctype, from_id, to_id, amount, asset, memo, nonce_counter)
        VALUES(_from_acctype, _from_id, _to_id, _amount, (SELECT vsc_app.get_asset_id(_tk)), _memo, _nonce_counter)
        RETURNING id INTO _xfer_id;

    RETURN _xfer_id;
END $$
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

CREATE OR REPLACE FUNCTION vsc_app.push_events(
    _id VARCHAR,
    _l2_block_num INTEGER,
    _index SMALLINT,
    _body jsonb
)
RETURNS void
AS $function$
DECLARE
    new_evt_id INTEGER;
    i INTEGER = 0;
    j SMALLINT;
    e jsonb; -- event for the tx
    e1 jsonb; -- txs map array used in first loop
    e2 INTEGER; -- event array position used in second loop
    _l1_tx_id BIGINT;
    _l2_tx_id INTEGER;
    _acc_id INTEGER; -- account id of owner
    _nonce_counter INTEGER; -- event nonce counter of owner before increment
BEGIN
    IF (SELECT jsonb_array_length(_body->'txs')) != (SELECT jsonb_array_length(_body->'txs_map')) THEN
        RETURN; -- txs must have the same array length as txs_map
    END IF;
    INSERT INTO vsc_app.events(cid, block_num, idx_in_block)
        VALUES(_id, _l2_block_num, _index)
        RETURNING id INTO new_evt_id;
    FOR e1 in SELECT * FROM jsonb_array_elements(_body->'txs_map')
    LOOP
        j := 0::SMALLINT;
        FOR e2 in SELECT value::INTEGER FROM jsonb_array_elements(e1)
        LOOP
            _nonce_counter := NULL;
            _acc_id := NULL;
            e := (_body->'events')->e2;
            SELECT id INTO _l2_tx_id FROM vsc_app.l2_txs WHERE cid = (_body->'txs')->>i;
            IF _l2_tx_id IS NULL THEN
                SELECT o.id
                INTO _l1_tx_id
                FROM vsc_app.l1_operations o
                JOIN hive.transactions_view ht ON
                    ht.block_num = o.block_num AND o.trx_in_block = o.trx_in_block
                WHERE ht.trx_hash = decode(SPLIT_PART((_body->'txs')->>i, '-', 1), 'hex') AND
                    o.op_pos = SPLIT_PART((_body->'txs')->>i, '-', 2)::INT;
            END IF;
            IF _l1_tx_id IS NOT NULL OR _l2_tx_id IS NOT NULL THEN
                -- get next nonce
                IF starts_with(e->>'owner', 'did:') THEN
                    SELECT d.event_count
                    INTO _nonce_counter
                    FROM vsc_app.dids d
                    WHERE d.did = e->>'owner';

                    IF _nonce_counter IS NULL THEN
                        INSERT INTO vsc_app.dids(did, event_count) VALUES(e->>'owner', 1);
                        _nonce_counter := 1;
                    ELSE
                        _nonce_counter := _nonce_counter+1;
                        UPDATE vsc_app.dids SET event_count = _nonce_counter WHERE did = e->>'owner';
                    END IF;
                ELSIF starts_with(e->>'owner', 'hive:') THEN
                    SELECT u.event_count, ha.id
                    INTO _nonce_counter, _acc_id
                    FROM vsc_app.l1_users u
                    RIGHT JOIN hive.vsc_app_accounts ha ON
                        ha.id = u.id
                    WHERE ha.name = REPLACE(e->>'owner', 'hive:', '');

                    IF _acc_id IS NOT NULL THEN
                        _nonce_counter := COALESCE(_nonce_counter, 0)+1;
                        INSERT INTO vsc_app.l1_users(id, event_count)
                            VALUES(_acc_id, _nonce_counter)
                            ON CONFLICT(id) DO UPDATE SET event_count = _nonce_counter; -- upsert
                    END IF;
                END IF;

                -- insert event
                INSERT INTO vsc_app.l2_tx_events(event_id, tx_pos, evt_pos, l1_tx_id, l2_tx_id, nonce_counter, evt_type, token, amount, memo, owner_name)
                    VALUES(
                        new_evt_id,
                        i,
                        j,
                        _l1_tx_id,
                        (SELECT id FROM vsc_app.l2_txs WHERE cid = ((_body->'txs')->>i)),
                        _nonce_counter,
                        (e->>'t')::INTEGER,
                        (SELECT vsc_app.get_asset_id(e->>'tk')),
                        (e->'amt')::INTEGER,
                        e->>'memo',
                        e->>'owner'
                    );
            END IF; -- skip if both are null
            j := j+1::SMALLINT;
        END LOOP;
        i := i+1;
    END LOOP;
END $function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_l1_tx(
    _in_op BIGINT,
    _callers VARCHAR[],
    _caller_auths SMALLINT[],
    _payload jsonb -- json.tx
)
RETURNS void AS $$
DECLARE
    _tx_type SMALLINT;
    _caller_id INTEGER;
    _detail_id BIGINT;
    i INTEGER;
BEGIN
    IF (SELECT ARRAY_LENGTH(_callers, 1)) != (SELECT ARRAY_LENGTH(_caller_auths, 1)) THEN
        RAISE EXCEPTION 'callers and caller_auths must have the same array length';
    END IF;

    SELECT ot.id INTO _tx_type FROM vsc_app.l2_operation_types ot WHERE ot.op_name = _payload->>'op';

    IF _tx_type::INT = 1 THEN
        SELECT vsc_app.push_contract_call(_payload->>'contract_id', _payload->>'action', jsonb_build_array(_payload->'payload')) INTO _detail_id;
    ELSIF _tx_type::INT = 3 THEN
        SELECT vsc_app.push_transfer_tx((_payload->'payload'->>'amount')::INT, _payload->'payload'->>'from', _payload->'payload'->>'to', _payload->'payload'->>'tk', _payload->'payload'->>'memo') INTO _detail_id;
    ELSIF _tx_type::INT = 4 THEN
        SELECT vsc_app.push_l2_withdraw_tx((_payload->'payload'->>'amount')::INT, _payload->'payload'->>'from', _payload->'payload'->>'to', _payload->'payload'->>'tk', _payload->'payload'->>'memo') INTO _detail_id;
    END IF;

    INSERT INTO vsc_app.l1_txs(id, tx_type, details)
        VALUES(_in_op, _tx_type, _detail_id);

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
END $$
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

CREATE OR REPLACE FUNCTION vsc_app.update_withdrawal_statuses(_ids BIGINT[], _status VARCHAR)
RETURNS void AS $$
BEGIN
    UPDATE vsc_app.l2_withdrawals SET
        status = (SELECT id FROM vsc_app.withdrawal_status WHERE name=_status)
    WHERE id = ANY(_ids);
END $$
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

CREATE OR REPLACE FUNCTION vsc_app.update_contract(
    _updated_in_op BIGINT,
    _contract_id VARCHAR,
    _code_hash VARCHAR,
    _proof_hash VARCHAR,
    _proof_sig BYTEA,
    _proof_bv BYTEA)
RETURNS void
AS
$function$
BEGIN
    IF (SELECT EXISTS (SELECT 1 FROM vsc_app.contracts WHERE contract_id=_contract_id)) THEN
        UPDATE vsc_app.contracts SET
            last_updated_in_op = _updated_in_op,
            code = _code_hash,
            proof_hash = _proof_hash,
            proof_sig = _proof_sig,
            proof_bv = _proof_bv
        WHERE contract_id = _contract_id;
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;