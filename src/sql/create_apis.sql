DROP SCHEMA IF EXISTS vsc_api CASCADE;
CREATE SCHEMA IF NOT EXISTS vsc_api AUTHORIZATION vsc_app;
GRANT USAGE ON SCHEMA vsc_api TO vsc_user;
GRANT USAGE ON SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_api TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON TABLE hive.vsc_app_accounts TO vsc_user;

-- GET /
CREATE OR REPLACE FUNCTION vsc_api.home()
RETURNS jsonb
AS
$function$
DECLARE
    _last_processed_block INTEGER;
    _db_version INTEGER;
    _l2_block_height INTEGER;
    _ops BIGINT;
    _contracts INTEGER;
    _witnesses BIGINT;
    _txrefs INTEGER;
BEGIN
    SELECT last_processed_block, db_version INTO _last_processed_block, _db_version FROM vsc_app.state;
    SELECT id INTO _l2_block_height FROM vsc_app.blocks ORDER BY id DESC LIMIT 1;
    SELECT id INTO _ops FROM vsc_app.l1_operations ORDER BY id DESC LIMIT 1;
    SELECT id INTO _contracts FROM vsc_app.contracts ORDER BY id DESC LIMIT 1;
    SELECT witness_id INTO _witnesses FROM vsc_app.witnesses ORDER BY witness_id DESC LIMIT 1;
    SELECT id INTO _txrefs FROM vsc_app.multisig_txrefs ORDER BY id DESC LIMIT 1;
    RETURN jsonb_build_object(
        'last_processed_block', _last_processed_block,
        'db_version', _db_version,
        'l2_block_height', _l2_block_height,
        'operations', _ops,
        'contracts', _contracts,
        'witnesses', _witnesses,
        'txrefs', _txrefs
    );
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.l1_tx_type CASCADE;
CREATE TYPE vsc_api.l1_tx_type AS (
    trx_hash TEXT,
    block_num INTEGER,
    created_at TIMESTAMP
);

CREATE OR REPLACE FUNCTION vsc_api.helper_get_tx_by_op_id(_op_id BIGINT)
RETURNS vsc_api.l1_tx_type
AS
$function$
DECLARE
    result vsc_api.l1_tx_type;
BEGIN
    -- Seperate queries for tx id and timestamp are faster than joining 3 tables in single query
    SELECT encode(htx.trx_hash::bytea, 'hex'), htx.block_num
        INTO result
        FROM hive.transactions_view htx
        JOIN hive.operations_view ho ON
            ho.block_num = htx.block_num AND
            ho.trx_in_block = htx.trx_in_block
        WHERE ho.id = _op_id;

    SELECT hb.created_at
        INTO result.created_at
        FROM hive.blocks_view hb
        WHERE hb.num = result.block_num;

    RETURN result;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_block_by_hash(blk_hash VARCHAR)
RETURNS jsonb
AS
$function$
DECLARE
    _announced_in_op BIGINT;
    _prev_block_hash VARCHAR = NULL;
    _block_id INTEGER;
    _announced_in_tx_id BIGINT;
    _l1_tx vsc_api.l1_tx_type;
    _announcer_id INTEGER;
    _announcer TEXT;
BEGIN
    SELECT id, announced_in_op, announcer INTO _block_id, _announced_in_op, _announcer_id
        FROM vsc_app.blocks
        WHERE vsc_app.blocks.block_hash = blk_hash
        LIMIT 1;
    IF _block_id IS NULL THEN
        RETURN jsonb_build_object('error', 'Block does not exist');
    END IF;
    IF _block_id > 1 THEN
        SELECT block_hash INTO _prev_block_hash
            FROM vsc_app.blocks
            WHERE vsc_app.blocks.id = _block_id-1;
    END IF;
    SELECT l1_op.op_id INTO _announced_in_tx_id
        FROM vsc_app.l1_operations l1_op
        WHERE l1_op.id = _announced_in_op;
    SELECT * INTO _l1_tx FROM vsc_api.helper_get_tx_by_op_id(_announced_in_tx_id);
    SELECT name INTO _announcer FROM hive.vsc_app_accounts WHERE id=_announcer_id;
    
    RETURN jsonb_build_object(
        'id', _block_id,
        'prev_block_hash', _prev_block_hash,
        'block_hash', blk_hash,
        'announcer', _announcer,
        'ts', _l1_tx.created_at,
        'l1_tx', _l1_tx.trx_hash,
        'l1_block', _l1_tx.block_num
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_block_by_id(blk_id INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    _announced_in_op BIGINT;
    _prev_block_hash VARCHAR = NULL;
    _block_hash VARCHAR;
    _announced_in_tx_id BIGINT;
    _l1_tx vsc_api.l1_tx_type;
    _announcer_id INTEGER;
    _announcer TEXT;
BEGIN
    SELECT block_hash, announced_in_op, announcer INTO _block_hash, _announced_in_op, _announcer_id
        FROM vsc_app.blocks
        WHERE vsc_app.blocks.id = blk_id;
    IF _block_hash IS NULL THEN
        RETURN jsonb_build_object('error', 'Block does not exist');
    END IF;
    IF blk_id > 1 THEN
        SELECT block_hash INTO _prev_block_hash
            FROM vsc_app.blocks
            WHERE vsc_app.blocks.id = blk_id-1;
    END IF;
    SELECT l1_op.op_id INTO _announced_in_tx_id
        FROM vsc_app.l1_operations l1_op
        WHERE l1_op.id = _announced_in_op;
    SELECT * INTO _l1_tx FROM vsc_api.helper_get_tx_by_op_id(_announced_in_tx_id);
    SELECT name INTO _announcer FROM hive.vsc_app_accounts WHERE id=_announcer_id;
    
    RETURN jsonb_build_object(
        'id', blk_id,
        'prev_block_hash', _prev_block_hash,
        'block_hash', _block_hash,
        'announcer', _announcer,
        'ts', _l1_tx.created_at,
        'l1_tx', _l1_tx.trx_hash,
        'l1_block', _l1_tx.block_num
    );
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.block_type CASCADE;
CREATE TYPE vsc_api.block_type AS (
    id INTEGER,
    announced_in_op BIGINT,
    block_hash VARCHAR,
    announcer INTEGER
);

CREATE OR REPLACE FUNCTION vsc_api.get_block_range(blk_id_start INTEGER, blk_count INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    b vsc_api.block_type;
    _block_details vsc_api.block_type[];
    _blocks jsonb[] DEFAULT '{}';
    _announced_in_tx_id BIGINT;
    _l1_tx vsc_api.l1_tx_type;
    _announcer TEXT;
BEGIN
    IF blk_count > 1000 OR blk_count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'blk_count must be between 1 and 1000'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(vsc_app.blocks.*)::vsc_api.block_type
            FROM vsc_app.blocks
            WHERE vsc_app.blocks.id >= blk_id_start AND vsc_app.blocks.id < blk_id_start+blk_count
    ) INTO _block_details;
    FOREACH b IN ARRAY _block_details
    LOOP
        SELECT l1_op.op_id INTO _announced_in_tx_id
            FROM vsc_app.l1_operations l1_op
            WHERE l1_op.id = b.announced_in_op;
        SELECT * INTO _l1_tx FROM vsc_api.helper_get_tx_by_op_id(_announced_in_tx_id);
        SELECT name INTO _announcer FROM hive.vsc_app_accounts WHERE id=b.announcer;
        SELECT ARRAY_APPEND(_blocks, jsonb_build_object(
            'id', b.id,
            'ts', _l1_tx.created_at,
            'block_hash', b.block_hash,
            'announcer', _announcer,
            'l1_tx', _l1_tx.trx_hash,
            'l1_block', _l1_tx.block_num
        )) INTO _blocks;
    END LOOP;

    RETURN array_to_json(_blocks)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.l1_op_type CASCADE;
CREATE TYPE vsc_api.l1_op_type AS (
    id BIGINT,
    name VARCHAR,
    nonce BIGINT,
    op_type INTEGER,
    op_name VARCHAR,
    block_num INTEGER,
    ts TIMESTAMP,
    body TEXT
);

CREATE OR REPLACE FUNCTION vsc_api.get_l1_operations_by_l1_blocks(l1_blk_start INTEGER, l1_blk_count INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    op vsc_api.l1_op_type;
    ops vsc_api.l1_op_type[];
    ops_arr jsonb[] DEFAULT '{}';
    op_payload jsonb;
BEGIN
    IF l1_blk_count > 1000 OR l1_blk_count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'l1_blk_count must be between 1 and 1000'
        );
    ELSIF l1_blk_start <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'l1_blk_start must be greater than or equal to 1'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(o.id, hive.vsc_app_accounts.name, o.nonce, o.op_type, ot.op_name, ho.block_num, o.ts, ho.body::TEXT)::vsc_api.l1_op_type
            FROM vsc_app.l1_operations o
            JOIN vsc_app.l1_operation_types ot ON
                ot.id = o.op_type
            JOIN hive.operations_view ho ON
                ho.id = o.op_id
            JOIN hive.vsc_app_accounts ON
                hive.vsc_app_accounts.id = o.user_id
            WHERE ho.block_num >= l1_blk_start AND ho.block_num < l1_blk_start+l1_blk_count
    ) INTO ops;
    
    FOREACH op IN ARRAY ops
    LOOP
        IF op.op_type = 1 THEN
            op_payload := ((op.body::jsonb->'value'->>'json_metadata')::jsonb)->>'vsc_node';
        ELSE
            op_payload := (op.body::jsonb->'value'->>'json')::jsonb;
        END IF;
        SELECT ARRAY_APPEND(ops_arr, jsonb_build_object(
            'id', op.id,
            'username', op.name,
            'nonce', op.nonce,
            'type', op.op_name,
            'l1_block', op.block_num,
            'ts', op.ts,
            'payload', op_payload
        )) INTO ops_arr;
    END LOOP;
    
    RETURN array_to_json(ops_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l1_user(username VARCHAR)
RETURNS jsonb 
AS
$function$
DECLARE
    _count BIGINT;
    _last_op_ts TIMESTAMP;
BEGIN
    SELECT u.count, u.last_op_ts
        INTO _count, _last_op_ts
        FROM vsc_app.l1_users u
        JOIN hive.vsc_app_accounts ac ON
            ac.id = u.id
        WHERE ac.name=username;
    
    RETURN jsonb_build_object(
        'name', username,
        'tx_count', _count,
        'last_activity', _last_op_ts
    );
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.witness_type CASCADE;
CREATE TYPE vsc_api.witness_type AS (
    witness_id INTEGER,
    name VARCHAR,
    did VARCHAR,
    enabled BOOLEAN,
    enabled_at BIGINT,
    disabled_at BIGINT,
    last_block INTEGER,
    produced INTEGER
);

CREATE OR REPLACE FUNCTION vsc_api.get_witness(username VARCHAR)
RETURNS jsonb 
AS
$function$
DECLARE
    result vsc_api.witness_type;
    _enabled_at_txhash VARCHAR;
    _disabled_at_txhash VARCHAR;
BEGIN
    SELECT w.witness_id, name, w.did, w.enabled, l1_e.op_id AS enabled_at, l1_d.op_id AS disabled_at, w.last_block, w.produced
        INTO result
        FROM vsc_app.witnesses w
        JOIN hive.vsc_app_accounts ON
            hive.vsc_app_accounts.id = w.id
        JOIN vsc_app.l1_operations l1_e ON
            l1_e.id = w.enabled_at
        JOIN vsc_app.l1_operations l1_d ON
            l1_d.id = w.disabled_at
        WHERE hive.vsc_app_accounts.name = username;
    SELECT trx_hash INTO _enabled_at_txhash FROM vsc_api.helper_get_tx_by_op_id(result.enabled_at);
    SELECT trx_hash INTO _disabled_at_txhash FROM vsc_api.helper_get_tx_by_op_id(result.disabled_at);
    
    RETURN jsonb_build_object(
        'id', result.witness_id,
        'username', result.name,
        'did', result.did,
        'trusted', COALESCE((SELECT d.trusted FROM vsc_app.trusted_dids d WHERE d.did=result.did), FALSE),
        'enabled', result.enabled,
        'enabled_at', _enabled_at_txhash,
        'disabled_at', _disabled_at_txhash,
        'last_block', result.last_block,
        'produced', result.produced
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_witnesses_by_id(id_start INTEGER = 0, count INTEGER = 50)
RETURNS jsonb 
AS
$function$
DECLARE
    result vsc_api.witness_type;
    results vsc_api.witness_type[];
    result_arr jsonb[] DEFAULT '{}';
BEGIN
    IF count > 50 OR count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 50'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(w.witness_id, name, w.did, w.enabled, l1_e.op_id, l1_d.op_id, w.last_block, w.produced)
            FROM vsc_app.witnesses w
            JOIN hive.vsc_app_accounts ON
                hive.vsc_app_accounts.id = w.id
            LEFT JOIN vsc_app.l1_operations l1_e ON
                l1_e.id = w.enabled_at
            LEFT JOIN vsc_app.l1_operations l1_d ON
                l1_d.id = w.disabled_at
            WHERE w.witness_id >= id_start
            ORDER BY w.witness_id
            LIMIT count
    ) INTO results;
    FOREACH result IN ARRAY results
    LOOP
        SELECT ARRAY_APPEND(result_arr, jsonb_build_object(
            'id', result.witness_id,
            'username', result.name,
            'did', result.did,
            'enabled', result.enabled,
            'enabled_at', (SELECT trx_hash FROM vsc_api.helper_get_tx_by_op_id(result.enabled_at)),
            'disabled_at', (SELECT trx_hash FROM vsc_api.helper_get_tx_by_op_id(result.disabled_at)),
            'last_block', result.last_block,
            'produced', result.produced
        )) INTO result_arr;
    END LOOP;
    
    RETURN array_to_json(result_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.is_did_trusted(_did VARCHAR)
RETURNS jsonb 
AS
$function$
DECLARE
    _is_trusted BOOLEAN DEFAULT FALSE;
BEGIN
    SELECT d.trusted INTO _is_trusted FROM vsc_app.trusted_dids d WHERE d.did=_did;
    IF _is_trusted IS NULL THEN
        _is_trusted := FALSE;
    END IF;
    RETURN jsonb_build_object(
        'did', _did,
        'trusted', _is_trusted
    );
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.txref_type CASCADE;
CREATE TYPE vsc_api.txref_type AS (
    id INTEGER,
    in_op BIGINT,
    ref_id VARCHAR(59)
);

CREATE OR REPLACE FUNCTION vsc_api.get_txrefs_by_id(_id INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    result vsc_api.txref_type;
    l1_tx vsc_api.l1_tx_type;
BEGIN
    SELECT * INTO result FROM vsc_app.multisig_txrefs WHERE id=_id;
    SELECT * INTO l1_tx FROM vsc_api.helper_get_tx_by_op_id(
        (SELECT op_id FROM vsc_app.l1_operations WHERE id=result.in_op)
    );
    RETURN jsonb_build_object(
        'id', _id,
        'ts', l1_tx.created_at,
        'l1_tx', l1_tx.trx_hash,
        'l1_block', l1_tx.block_num,
        'ref_id', result.ref_id
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_txrefs(last_id INTEGER = 0, count INTEGER = 50)
RETURNS jsonb
AS
$function$
DECLARE
    r vsc_api.txref_type;
    results vsc_api.txref_type[];
    results_arr jsonb[] DEFAULT '{}';
    l1_tx vsc_api.l1_tx_type;
BEGIN
    IF count > 1000 OR count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 1000'
        );
    END IF;
    IF last_id <= 0 THEN
        SELECT ARRAY(
            SELECT ROW(t.*) FROM vsc_app.multisig_txrefs t ORDER BY t.id DESC LIMIT count
        ) INTO results;
    ELSE
        SELECT ARRAY(
            SELECT ROW(t.*) FROM vsc_app.multisig_txrefs t WHERE t.id <= last_id ORDER BY t.id DESC LIMIT count
        ) INTO results;
    END IF;

    FOREACH r IN ARRAY results
    LOOP
        SELECT * INTO l1_tx FROM vsc_api.helper_get_tx_by_op_id(
            (SELECT op_id FROM vsc_app.l1_operations WHERE id=r.in_op)
        );
        SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
            'id', r.id,
            'ts', l1_tx.created_at,
            'l1_tx', l1_tx.trx_hash,
            'l1_block', l1_tx.block_num,
            'ref_id', r.ref_id
        )) INTO results_arr;
    END LOOP;
    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.op_history_type CASCADE;
CREATE TYPE vsc_api.op_history_type AS (
    id BIGINT,
    username VARCHAR(16),
    nonce BIGINT,
    op_id BIGINT,
    op_name VARCHAR(20),
    body TEXT
);

CREATE OR REPLACE FUNCTION vsc_api.get_op_history_by_l1_user(username VARCHAR, count INTEGER = 50, last_nonce BIGINT = NULL, bitmask_filter BIGINT = NULL)
RETURNS jsonb
AS
$function$
DECLARE
    result vsc_api.op_history_type;
    results vsc_api.op_history_type[];
    results_arr jsonb[] DEFAULT '{}';
    _l1_tx vsc_api.l1_tx_type;
    _payload TEXT;
BEGIN
    IF last_nonce IS NOT NULL AND last_nonce < 0 THEN
        RETURN jsonb_build_object(
            'error', 'last_nonce must be greater than or equal to 0 if not null'
        );
    ELSIF count <= 0 OR count > 1000 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 1000'
        );
    END IF;

    IF bitmask_filter IS NULL THEN
        SELECT ARRAY(
            SELECT ROW(o.id, a.name, o.nonce, o.op_id, ot.op_name, ho.body::jsonb->>'value')::vsc_api.op_history_type
                FROM vsc_app.l1_operations o
                JOIN vsc_app.l1_operation_types ot ON
                    ot.id = o.op_type
                JOIN hive.vsc_app_accounts a ON
                    a.id = o.user_id
                JOIN hive.operations_view ho ON
                    ho.id = o.op_id
                WHERE a.name = username AND o.nonce <= COALESCE(last_nonce, 9223372036854775807)
                ORDER BY o.id DESC
                LIMIT count
        ) INTO results;
    ELSE
        SELECT ARRAY(
            SELECT ROW(o.id, a.name, o.nonce, o.op_id, ot.op_name, ho.body::jsonb->>'value')::vsc_api.op_history_type
                FROM vsc_app.l1_operations o
                JOIN vsc_app.l1_operation_types ot ON
                    ot.id = o.op_type
                JOIN hive.vsc_app_accounts a ON
                    a.id = o.user_id
                JOIN hive.operations_view ho ON
                    ho.id = o.op_id
                WHERE a.name = username AND o.nonce <= COALESCE(last_nonce, 9223372036854775807) AND (ot.filterer & bitmask_filter) > 0
                ORDER BY o.id DESC
                LIMIT count
        ) INTO results;
    END IF;

    FOREACH result IN ARRAY results
    LOOP
        SELECT * INTO _l1_tx FROM vsc_api.helper_get_tx_by_op_id(result.op_id);
        IF result.op_name = 'announce_node' THEN
            _payload := (result.body::jsonb->>'json_metadata')::jsonb->>'vsc_node';
        ELSE
            _payload := result.body::jsonb->>'json';
        END IF;
        SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
            'id', result.id,
            'username', result.username,
            'nonce', result.nonce,
            'ts', _l1_tx.created_at,
            'type', result.op_name,
            'l1_tx', _l1_tx.trx_hash,
            'l1_block', _l1_tx.block_num,
            'payload', _payload::jsonb
        )) INTO results_arr;
    END LOOP;
    
    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_ops_by_l1_tx(trx_id VARCHAR)
RETURNS jsonb
AS
$function$
DECLARE
    _block_num INTEGER[];
    _trxs_in_blk SMALLINT[];
    _trx_in_blk SMALLINT;
    _op vsc_api.l1_op_type;
    _payload TEXT;
    results_arr jsonb[] DEFAULT '{}';
BEGIN
    SELECT ARRAY_AGG(block_num), ARRAY_AGG(trx_in_block) INTO _block_num, _trxs_in_blk
        FROM hive.transactions_view
        WHERE trx_hash = decode(trx_id, 'hex');

    IF _block_num IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    FOREACH _trx_in_blk IN ARRAY _trxs_in_blk
    LOOP
        SELECT vo.id, va.name, vo.nonce, vo.op_type, vt.op_name, ho.block_num, vo.ts, ho.body::jsonb->>'value'
            INTO _op
            FROM hive.operations_view ho
            JOIN vsc_app.l1_operations vo ON
                vo.op_id=ho.id
            JOIN vsc_app.l1_operation_types vt ON
                vt.id=vo.op_type
            JOIN hive.vsc_app_accounts va ON
                va.id=vo.user_id
            WHERE ho.block_num=_block_num[1] AND ho.trx_in_block=_trx_in_blk;
        IF _op IS NOT NULL THEN
            IF _op.op_name = 'announce_node' THEN
                _payload := (_op.body::jsonb->>'json_metadata')::jsonb->>'vsc_node';
            ELSE
                _payload := _op.body::jsonb->>'json';
            END IF;
            SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
                'id', _op.id,
                'name', _op.name,
                'nonce', _op.nonce,
                'type', _op.op_name,
                'l1_block', _op.block_num,
                'l1_tx', trx_id,
                'ts', _op.ts,
                'payload', _payload::jsonb
            )) INTO results_arr;
        END IF;
    END LOOP;

    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_latest_ops(count INTEGER = 100, bitmask_filter BIGINT = NULL, with_payload BOOLEAN = FALSE)
RETURNS jsonb
AS
$function$
DECLARE
    result vsc_api.op_history_type;
    results vsc_api.op_history_type[];
    results_arr jsonb[] DEFAULT '{}';
    _l1_tx vsc_api.l1_tx_type;
    _payload TEXT;
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;

    IF bitmask_filter IS NULL THEN
        SELECT ARRAY(
            SELECT ROW(o.id, a.name, o.nonce, o.op_id, ot.op_name, ho.body::jsonb->>'value')::vsc_api.op_history_type
                FROM vsc_app.l1_operations o
                JOIN vsc_app.l1_operation_types ot ON
                    ot.id = o.op_type
                JOIN hive.vsc_app_accounts a ON
                    a.id = o.user_id
                JOIN hive.operations_view ho ON
                    ho.id = o.op_id
                ORDER BY o.id DESC
                LIMIT count
        ) INTO results;
    ELSE
        SELECT ARRAY(
            SELECT ROW(o.id, a.name, o.nonce, o.op_id, ot.op_name, ho.body::jsonb->>'value')::vsc_api.op_history_type
                FROM vsc_app.l1_operations o
                JOIN vsc_app.l1_operation_types ot ON
                    ot.id = o.op_type
                JOIN hive.vsc_app_accounts a ON
                    a.id = o.user_id
                JOIN hive.operations_view ho ON
                    ho.id = o.op_id
                WHERE (ot.filterer & bitmask_filter) > 0
                ORDER BY o.id DESC
                LIMIT count
        ) INTO results;
    END IF;

    FOREACH result IN ARRAY results
    LOOP
        SELECT * INTO _l1_tx FROM vsc_api.helper_get_tx_by_op_id(result.op_id);
        IF with_payload IS TRUE THEN
            IF result.op_name = 'announce_node' THEN
                _payload := (result.body::jsonb->>'json_metadata')::jsonb->>'vsc_node';
            ELSE
                _payload := result.body::jsonb->>'json';
            END IF;
        
            SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
                'id', result.id,
                'username', result.username,
                'nonce', result.nonce,
                'type', result.op_name,
                'ts', _l1_tx.created_at,
                'l1_tx', _l1_tx.trx_hash,
                'l1_block', _l1_tx.block_num,
                'payload', _payload::jsonb
            )) INTO results_arr;
        ELSE
            SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
                'id', result.id,
                'username', result.username,
                'nonce', result.nonce,
                'type', result.op_name,
                'ts', _l1_tx.created_at,
                'l1_tx', _l1_tx.trx_hash,
                'l1_block', _l1_tx.block_num
            )) INTO results_arr;
        END IF;
    END LOOP;

    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.contract_type CASCADE;
CREATE TYPE vsc_api.contract_type AS (
    id INTEGER,
    created_in_op BIGINT,
    name VARCHAR,
    manifest_id VARCHAR,
    code VARCHAR,
    op_id BIGINT
);

CREATE OR REPLACE FUNCTION vsc_api.list_latest_contracts(count INTEGER = 100)
RETURNS jsonb
AS
$function$
DECLARE
    result vsc_api.contract_type;
    results vsc_api.contract_type[];
    results_arr jsonb[] DEFAULT '{}';
    _l1_tx vsc_api.l1_tx_type;
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(c.*, o.op_id)
        FROM vsc_app.contracts c
        JOIN vsc_app.l1_operations o ON
            o.id=c.created_in_op
        ORDER BY c.id DESC
        LIMIT count
    ) INTO results;

    FOREACH result IN ARRAY results
    LOOP
        SELECT * INTO _l1_tx FROM vsc_api.helper_get_tx_by_op_id(result.op_id);
        SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
            'id', result.id,
            'created_in_op', _l1_tx.trx_hash,
            'created_in_l1_block', _l1_tx.block_num,
            'created_at', _l1_tx.created_at,
            'name', result.name,
            'manifest_id', result.manifest_id,
            'code', result.code
        )) INTO results_arr;
    END LOOP;

    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;