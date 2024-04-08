SET ROLE vsc_owner;

DROP SCHEMA IF EXISTS vsc_api CASCADE;
CREATE SCHEMA IF NOT EXISTS vsc_api AUTHORIZATION vsc_owner;
GRANT USAGE ON SCHEMA vsc_api TO vsc_user;
GRANT USAGE ON SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_api TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON TABLE hive.vsc_app_accounts TO vsc_user;
GRANT SELECT ON hive.vsc_app_transactions_view TO vsc_user;
GRANT SELECT ON hive.vsc_app_operations_view TO vsc_user;

-- GET /
CREATE OR REPLACE FUNCTION vsc_api.home()
RETURNS jsonb
AS
$function$
DECLARE
    _last_processed_block INTEGER;
    _db_version INTEGER;
BEGIN
    SELECT last_processed_block, db_version INTO _last_processed_block, _db_version FROM vsc_app.state;
    RETURN jsonb_build_object(
        'last_processed_block', _last_processed_block,
        'last_processed_subindexer_op', (SELECT last_processed_op FROM vsc_app.subindexer_state),
        'db_version', _db_version,
        'epoch', (SELECT epoch FROM vsc_app.election_results ORDER BY epoch DESC LIMIT 1),
        'l2_block_height', (SELECT COUNT(*) FROM vsc_app.blocks),
        'transactions', (SELECT COUNT(*) FROM vsc_app.transactions),
        'operations', (SELECT COUNT(*) FROM vsc_app.l1_operations),
        'contracts', (SELECT COUNT(*) FROM vsc_app.contracts),
        'witnesses', (SELECT COUNT(*) FROM vsc_app.witnesses),
        'bridge_txs', (SELECT COUNT(*) FROM vsc_app.deposits_to_hive)+(SELECT COUNT(*) FROM vsc_app.deposits_to_did)+(SELECT COUNT(*) FROM vsc_app.withdrawals),
        'anchor_refs', (SELECT COUNT(*) FROM vsc_app.anchor_refs),
        'txrefs', (SELECT COUNT(*) FROM vsc_app.multisig_txrefs)
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_block_by_hash(blk_hash VARCHAR)
RETURNS jsonb
AS
$function$
DECLARE
    _block_num INTEGER;
    _tb SMALLINT;
    _ts TIMESTAMP;
    _prev_block_hash VARCHAR = NULL;
    _block_id INTEGER;
    _block_hash VARCHAR;
    _block_body_hash VARCHAR;
    _proposer TEXT;
    _merkle BYTEA;
    _sig BYTEA;
    _bv BYTEA;
BEGIN
    SELECT b.id, b.block_header_hash, b.block_hash, o.block_num, o.trx_in_block, o.ts, a.name, b.merkle_root, b.sig, b.bv
        INTO _block_id, _block_hash, _block_body_hash, _block_num, _tb, _ts, _proposer, _merkle, _sig, _bv
        FROM vsc_app.blocks b
        JOIN vsc_app.l1_operations o ON
            o.id = b.proposed_in_op
        JOIN hive.vsc_app_accounts a ON
            a.id = b.proposer
        WHERE b.block_header_hash = blk_hash OR b.block_hash = blk_hash;
    IF _block_hash IS NULL THEN
        RETURN jsonb_build_object('error', 'Block does not exist');
    END IF;
    IF _block_id > 1 THEN
        SELECT b.block_header_hash INTO _prev_block_hash
            FROM vsc_app.blocks b
            WHERE b.id = _block_id-1;
    END IF;
    
    RETURN jsonb_build_object(
        'id', _block_id,
        'prev_block_hash', _prev_block_hash,
        'block_hash', _block_hash,
        'block_body_hash', _block_body_hash,
        'proposer', _proposer,
        'ts', _ts,
        'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(_block_num, _tb)),
        'l1_block', _block_num,
        'merkle_root', encode(_merkle, 'hex'),
        'signature', (jsonb_build_object(
            'sig', encode(_sig, 'hex'),
            'bv', encode(_bv, 'hex')
        ))
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_block_by_id(blk_id INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    _block_num INTEGER;
    _tb SMALLINT;
    _ts TIMESTAMP;
    _prev_block_hash VARCHAR = NULL;
    _block_hash VARCHAR;
    _block_body_hash VARCHAR;
    _proposer TEXT;
    _merkle BYTEA;
    _sig BYTEA;
    _bv BYTEA;
BEGIN
    SELECT b.block_header_hash, b.block_hash, o.block_num, o.trx_in_block, o.ts, a.name, b.merkle_root, b.sig, b.bv
        INTO _block_hash, _block_body_hash, _block_num, _tb, _ts, _proposer, _merkle, _sig, _bv
        FROM vsc_app.blocks b
        JOIN vsc_app.l1_operations o ON
            o.id = b.proposed_in_op
        JOIN hive.vsc_app_accounts a ON
            a.id = b.proposer
        WHERE b.id = blk_id;
    IF _block_hash IS NULL THEN
        RETURN jsonb_build_object('error', 'Block does not exist');
    END IF;
    IF blk_id > 1 THEN
        SELECT b.block_header_hash INTO _prev_block_hash
            FROM vsc_app.blocks b
            WHERE b.id = blk_id-1;
    END IF;
    
    RETURN jsonb_build_object(
        'id', blk_id,
        'prev_block_hash', _prev_block_hash,
        'block_hash', _block_hash,
        'block_body_hash', _block_body_hash,
        'proposer', _proposer,
        'ts', _ts,
        'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(_block_num, _tb)),
        'l1_block', _block_num,
        'merkle_root', encode(_merkle, 'hex'),
        'signature', (jsonb_build_object(
            'sig', encode(_sig, 'hex'),
            'bv', encode(_bv, 'hex')
        ))
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_block_range(blk_id_start INTEGER, blk_count INTEGER)
RETURNS jsonb
AS
$function$
BEGIN
    IF blk_count > 1000 OR blk_count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'blk_count must be between 1 and 1000'
        );
    END IF;
    RETURN (
        SELECT jsonb_agg(jsonb_build_object(
            'id', bk.id,
            'ts', l1_op.ts,
            'block_hash', bk.block_header_hash,
            'block_body_hash', bk.block_hash,
            'proposer', a.name,
            'txs', (SELECT COUNT(*) FROM vsc_app.l2_txs t WHERE t.block_num = bk.id)+(SELECT COUNT(*) FROM vsc_app.anchor_refs ar WHERE ar.block_num = bk.id),
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(l1_op.block_num, l1_op.trx_in_block)),
            'l1_block', l1_op.block_num,
            'bv', encode(bk.bv, 'hex')
        ))
        FROM vsc_app.blocks bk
        JOIN vsc_app.l1_operations l1_op ON
            bk.proposed_in_op = l1_op.id
        JOIN hive.vsc_app_accounts a ON
            bk.proposer = a.id
        WHERE bk.id >= blk_id_start AND bk.id < blk_id_start+blk_count
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_txs_in_block(blk_id INTEGER)
RETURNS jsonb
AS $function$
BEGIN
    RETURN (WITH result AS (
        SELECT t.id, t.block_num, t.idx_in_block, t.tx_type, MIN(d.did) did, COUNT(a.id) auth_count
            FROM vsc_app.l2_txs t
            LEFT JOIN vsc_app.l2_tx_multiauth a ON
                a.id = t.id
            LEFT JOIN vsc_app.dids d ON
                a.did = d.id
            WHERE t.block_num = blk_id
            GROUP BY t.id
        UNION ALL
        SELECT r.cid AS id, r.block_num, r.idx_in_block, 5, NULL, 0
            FROM vsc_app.anchor_refs r
            WHERE r.block_num = blk_id
            ORDER BY idx_in_block ASC
    )
    SELECT jsonb_agg(
        jsonb_build_object(
            'id', id,
            'block_num', block_num,
            'idx_in_block', idx_in_block,
            'tx_type', (SELECT vsc_app.l2_tx_type_by_id(tx_type::SMALLINT)),
            'did', did,
            'auth_count', auth_count
        )
    ) FROM result);
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l1_tx(trx_id VARCHAR, op_pos INTEGER)
RETURNS jsonb
AS $function$
DECLARE
    l1_op_id BIGINT;
    op_position ALIAS FOR op_pos;
    _bn INTEGER;
    _tb SMALLINT;
    _ts TIMESTAMP;
    _auth_active jsonb;
    _auth_posting jsonb;
BEGIN
    SELECT o.id, ht.block_num, ht.trx_in_block, o.ts INTO l1_op_id, _bn, _tb, _ts
        FROM hive.vsc_app_transactions_view ht
        JOIN vsc_app.l1_operations o ON
            o.block_num = ht.block_num AND o.trx_in_block = ht.trx_in_block
        WHERE ht.trx_hash = decode(trx_id, 'hex')::BYTEA AND o.op_pos = op_position AND o.op_type = (SELECT ot.id FROM vsc_app.l1_operation_types ot WHERE ot.op_name = 'tx');
    IF l1_op_id IS NULL THEN
        RETURN jsonb_build_object('error', 'could not find contract call transaction');
    END IF;
    SELECT (ho.body::jsonb->'value')->'required_auths', (ho.body::jsonb->'value')->'required_posting_auths'
        INTO _auth_active, _auth_posting
        FROM hive.vsc_app_operations_view ho
        WHERE ho.block_num = _bn AND ho.trx_in_block = _tb AND ho.op_pos = op_position;
    RETURN (
        SELECT jsonb_build_object(
            'id', trx_id || '-' || op_pos::VARCHAR,
            'input', trx_id || '-' || op_pos::VARCHAR,
            'input_src', 'hive',
            'output', (SELECT id FROM vsc_app.l2_txs t2 WHERE details = d.id AND t2.tx_type = 2 LIMIT 1),
            'block_num', _bn,
            'idx_in_block', _tb,
            'ts', _ts,
            'tx_type', 'call_contract',
            'signers', jsonb_build_object(
                'active', _auth_active,
                'posting', _auth_posting
            ),
            'contract_id', d.contract_id,
            'contract_action', d.contract_action,
            'payload', (d.payload->0),
            'io_gas', d.io_gas,
            'contract_output', d.contract_output
        )
        FROM vsc_app.l1_txs t
        JOIN vsc_app.transactions d ON
            t.details = d.id
        WHERE t.id = l1_op_id
    );
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l2_tx(trx_id VARCHAR)
RETURNS jsonb
AS $function$
DECLARE
    _result jsonb;
    _tx_type SMALLINT;
    _input VARCHAR;
    _input_src VARCHAR = 'vsc';
    _tx_id BIGINT;
BEGIN
    SELECT jsonb_build_object(
        'id', t.id,
        'block_num', t.block_num,
        'idx_in_block', t.idx_in_block,
        'ts', bo.ts,
        'tx_type', (SELECT vsc_app.l2_tx_type_by_id(t.tx_type::SMALLINT)),
        'nonce', t.nonce,
        'signers', (
            SELECT jsonb_agg(k.did)
            FROM vsc_app.l2_tx_multiauth ma
            JOIN vsc_app.dids k ON
                ma.did = k.id
            WHERE ma.id = t.id
        ),
        'contract_id', d.contract_id,
        'contract_action', d.contract_action,
        'payload', (d.payload->0),
        'io_gas', d.io_gas,
        'contract_output', d.contract_output
    ), t.tx_type, d.id
    INTO _result, _tx_type, _tx_id
    FROM vsc_app.l2_txs t
    JOIN vsc_app.transactions d ON
        t.details = d.id
    JOIN vsc_app.blocks b ON
        b.id = t.block_num
    JOIN vsc_app.l1_operations bo ON
        bo.id = b.proposed_in_op
    WHERE t.id = trx_id;

    IF _result IS NULL THEN
        RETURN jsonb_build_object('error', 'transaction not found');
    END IF;

    IF _tx_type = 1 THEN
        _result := _result || jsonb_build_object('input', trx_id, 'input_src', _input_src, 'output', (
            SELECT id FROM vsc_app.l2_txs WHERE details = _tx_id AND tx_type = 2 LIMIT 1
        ));
    ELSIF _tx_type = 2 THEN
        SELECT id INTO _input FROM vsc_app.l2_txs WHERE details = _tx_id AND tx_type = 1;
        IF _input IS NULL THEN
            SELECT encode(ht.trx_hash, 'hex') INTO _input
                FROM vsc_app.l1_txs t
                JOIN vsc_app.l1_operations o ON
                    o.id = t.id
                JOIN hive.transactions_view ht ON
                    ht.block_num = o.block_num AND ht.trx_in_block = o.trx_in_block
                WHERE details = _tx_id;
            _input_src := 'hive';
        END IF;
        _result := _result || jsonb_build_object('input', _input, 'input_src', _input_src, 'output', trx_id);
    END IF;

    RETURN _result;
END $function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.l1_op_type CASCADE;
CREATE TYPE vsc_api.l1_op_type AS (
    id BIGINT,
    name VARCHAR,
    nonce INTEGER,
    op_type INTEGER,
    op_name VARCHAR,
    block_num INTEGER,
    trx_in_block SMALLINT,
    op_pos INTEGER,
    ts TIMESTAMP,
    body TEXT
);

CREATE OR REPLACE FUNCTION vsc_api.get_l1_operations_by_l1_blocks(l1_blk_start INTEGER, l1_blk_count INTEGER, full_tx_body BOOLEAN = FALSE)
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
        SELECT ROW(o.id, hive.vsc_app_accounts.name, o.nonce, o.op_type, ot.op_name, ho.block_num, ho.trx_in_block, ho.op_pos, o.ts, ho.body::TEXT)::vsc_api.l1_op_type
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
        IF full_tx_body IS TRUE THEN
            op_payload := (op.body::jsonb->'value')::jsonb;
        ELSE
            op_payload := (SELECT vsc_app.parse_l1_payload(op.op_name, op.body::jsonb->>'value'));
        END IF;
        SELECT ARRAY_APPEND(ops_arr, jsonb_build_object(
            'id', op.id,
            'username', op.name,
            'nonce', op.nonce,
            'type', op.op_name,
            'l1_block', op.block_num,
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(op.block_num, op.trx_in_block)),
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
        'tx_count', COALESCE(_count, 0),
        'last_activity', COALESCE(_last_op_ts, '1970-01-01T00:00:00')
    );
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.witness_type CASCADE;
CREATE TYPE vsc_api.witness_type AS (
    witness_id INTEGER,
    name VARCHAR,
    did VARCHAR,
    consensus_did VARCHAR,
    enabled BOOLEAN,
    enabled_at_block INTEGER,
    enabled_at_block_p SMALLINT,
    disabled_at_block INTEGER,
    disabled_at_block_p SMALLINT,
    git_commit VARCHAR,
    last_block INTEGER,
    produced INTEGER
);

CREATE OR REPLACE FUNCTION vsc_api.get_witness(username VARCHAR)
RETURNS jsonb 
AS
$function$
DECLARE
    result vsc_api.witness_type;
    _latest_git_commit VARCHAR;
BEGIN
    SELECT w.witness_id, name, w.did, w.consensus_did, w.enabled, l1_e.block_num, l1_e.trx_in_block, l1_d.block_num, l1_d.trx_in_block, w.git_commit, w.last_block, w.produced
        INTO result
        FROM vsc_app.witnesses w
        JOIN hive.vsc_app_accounts ON
            hive.vsc_app_accounts.id = w.id
        LEFT JOIN vsc_app.l1_operations l1_e ON
            l1_e.id = w.enabled_at
        LEFT JOIN vsc_app.l1_operations l1_d ON
            l1_d.id = w.disabled_at
        WHERE hive.vsc_app_accounts.name = username;
    SELECT git_commit INTO _latest_git_commit FROM vsc_app.vsc_node_git WHERE id=1;
    
    RETURN jsonb_build_object(
        'id', result.witness_id,
        'username', result.name,
        'did', result.did,
        'consensus_did', result.consensus_did,
        'enabled', result.enabled,
        'enabled_at', (SELECT vsc_app.get_tx_hash_by_op(result.enabled_at_block, result.enabled_at_block_p)),
        'disabled_at', (SELECT vsc_app.get_tx_hash_by_op(result.disabled_at_block, result.disabled_at_block_p)),
        'git_commit', result.git_commit,
        'latest_git_commit', _latest_git_commit,
        'is_up_to_date', (result.git_commit = _latest_git_commit),
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
    _latest_git_commit VARCHAR;
BEGIN
    IF count > 50 OR count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 50'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(w.witness_id, name, w.did, w.consensus_did, w.enabled, l1_e.block_num, l1_e.trx_in_block, l1_d.block_num, l1_d.trx_in_block, w.git_commit, w.last_block, w.produced)
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
    SELECT git_commit INTO _latest_git_commit FROM vsc_app.vsc_node_git WHERE id=1;
    FOREACH result IN ARRAY results
    LOOP
        SELECT ARRAY_APPEND(result_arr, jsonb_build_object(
            'id', result.witness_id,
            'username', result.name,
            'did', result.did,
            'consensus_did', result.consensus_did,
            'enabled', result.enabled,
            'enabled_at', (SELECT vsc_app.get_tx_hash_by_op(result.enabled_at_block, result.enabled_at_block_p)),
            'disabled_at', (SELECT vsc_app.get_tx_hash_by_op(result.disabled_at_block, result.disabled_at_block_p)),
            'git_commit', result.git_commit,
            'is_up_to_date', (result.git_commit = _latest_git_commit),
            'last_block', result.last_block,
            'produced', result.produced
        )) INTO result_arr;
    END LOOP;
    
    RETURN array_to_json(result_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.op_history_type CASCADE;
CREATE TYPE vsc_api.op_history_type AS (
    id BIGINT,
    username VARCHAR(16),
    nonce INTEGER,
    block_num INTEGER,
    trx_in_block SMALLINT,
    ts TIMESTAMP,
    op_name VARCHAR(20),
    body TEXT
);

CREATE OR REPLACE FUNCTION vsc_api.get_op_history_by_l1_user(username VARCHAR, count INTEGER = 50, last_nonce INTEGER = NULL, bitmask_filter BIGINT = NULL)
RETURNS jsonb
AS
$function$
DECLARE
    result vsc_api.op_history_type;
    results vsc_api.op_history_type[];
    results_arr jsonb[] DEFAULT '{}';
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
            SELECT ROW(o.id, a.name, o.nonce, o.block_num, o.trx_in_block, o.ts, ot.op_name, ho.body::jsonb->>'value')::vsc_api.op_history_type
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
            SELECT ROW(o.id, a.name, o.nonce, o.block_num, o.trx_in_block, o.ts, ot.op_name, ho.body::jsonb->>'value')::vsc_api.op_history_type
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
        SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
            'id', result.id,
            'username', result.username,
            'nonce', result.nonce,
            'ts', result.ts,
            'type', result.op_name,
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(result.block_num, result.trx_in_block)),
            'l1_block', result.block_num,
            'payload', (SELECT vsc_app.parse_l1_payload(result.op_name, result.body))
        )) INTO results_arr;
    END LOOP;
    
    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.l1_op_blk_trx CASCADE;
CREATE TYPE vsc_api.l1_op_blk_trx AS (
    id BIGINT,
    block_num INTEGER,
    trx_in_block SMALLINT,
    op_pos INTEGER,
    timestamp TIMESTAMP,
    body TEXT
);
CREATE OR REPLACE FUNCTION vsc_api.get_ops_by_l1_tx(trx_id VARCHAR)
RETURNS jsonb
AS
$function$
DECLARE
    _trxs vsc_api.l1_op_blk_trx[];
    _trx vsc_api.l1_op_blk_trx;
    _op vsc_api.l1_op_type;
    results_arr jsonb[] DEFAULT '{}';
BEGIN
    SELECT ARRAY(
        SELECT ROW(ho.id, ho.block_num, ho.trx_in_block, ho.op_pos, ho.timestamp, ho.body::TEXT)
            FROM hive.transactions_view ht
            JOIN hive.operations_view ho ON
                ho.block_num = ht.block_num AND ho.trx_in_block = ht.trx_in_block
            WHERE trx_hash = decode(trx_id, 'hex')
    ) INTO _trxs;

    IF _trxs IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    FOREACH _trx IN ARRAY _trxs
    LOOP
        SELECT vo.id, va.name, vo.nonce, vo.op_type, vt.op_name, _trx.block_num, _trx.trx_in_block, _trx.op_pos, vo.ts, _trx.body::jsonb->>'value'
            INTO _op
            FROM vsc_app.l1_operations vo
            JOIN vsc_app.l1_operation_types vt ON
                vt.id=vo.op_type
            JOIN hive.vsc_app_accounts va ON
                va.id=vo.user_id
            WHERE vo.op_id = _trx.id;
        IF _op IS NOT NULL THEN
            SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
                'id', _op.id,
                'username', _op.name,
                'nonce', _op.nonce,
                'type', _op.op_name,
                'l1_block', _op.block_num,
                'l1_tx', trx_id,
                'op_pos', _op.op_pos,
                'ts', _op.ts,
                'payload', (SELECT vsc_app.parse_l1_payload(_op.op_name, _op.body))
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
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;

    IF bitmask_filter IS NULL THEN
        SELECT ARRAY(
            SELECT ROW(o.id, a.name, o.nonce, o.block_num, o.trx_in_block, o.ts, ot.op_name, ho.body::jsonb->>'value')::vsc_api.op_history_type
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
            SELECT ROW(o.id, a.name, o.nonce, o.block_num, o.trx_in_block, o.ts, ot.op_name, ho.body::jsonb->>'value')::vsc_api.op_history_type
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
        IF with_payload IS TRUE THEN
            SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
                'id', result.id,
                'username', result.username,
                'nonce', result.nonce,
                'type', result.op_name,
                'ts', result.ts,
                'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(result.block_num, result.trx_in_block)),
                'l1_block', result.block_num,
                'payload', (SELECT vsc_app.parse_l1_payload(result.op_name, result.body))
            )) INTO results_arr;
        ELSE
            SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
                'id', result.id,
                'username', result.username,
                'nonce', result.nonce,
                'type', result.op_name,
                'ts', result.ts,
                'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(result.block_num, result.trx_in_block)),
                'l1_block', result.block_num
            )) INTO results_arr;
        END IF;
    END LOOP;

    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_latest_contracts(count INTEGER = 100)
RETURNS jsonb
AS $function$
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    RETURN (
        WITH contracts AS (
            SELECT c.*, o.block_num, o.trx_in_block, o.ts
            FROM vsc_app.contracts c
            JOIN vsc_app.l1_operations o ON
                o.id=c.created_in_op
            ORDER BY o.block_num DESC
            LIMIT 10
        )
        SELECT jsonb_agg(jsonb_build_object(
            'contract_id', contract_id,
            'created_in_op', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'created_in_l1_block', block_num,
            'created_at', ts,
            'name', name,
            'description', description,
            'code', code
        )) FROM contracts
    );
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_contract_by_id(id VARCHAR)
RETURNS jsonb
AS
$function$
DECLARE
	ct_id ALIAS FOR id;
BEGIN
    RETURN COALESCE((SELECT jsonb_build_object(
        'contract_id', c.contract_id,
        'created_in_op', (SELECT vsc_app.get_tx_hash_by_op(o.block_num, o.trx_in_block)),
        'created_in_l1_block', o.block_num,
        'created_at', o.ts,
        'name', c.name,
        'description', c.description,
        'code', c.code,
        'storage_proof', jsonb_build_object(
            'hash', c.proof_hash,
            'sig', encode(c.proof_sig, 'hex'),
            'bv', encode(c.proof_bv, 'hex')
        )
    )
    FROM vsc_app.contracts c
    JOIN vsc_app.l1_operations o ON
        o.id=c.created_in_op
    WHERE c.contract_id = ct_id), jsonb_build_object('error', 'contract not found'));
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l1_accounts_by_pubkeys(pubkeys VARCHAR[], key_type VARCHAR = 'sk_owner')
RETURNS jsonb 
AS
$function$
DECLARE
    _pubkey VARCHAR;
    _results VARCHAR[] DEFAULT '{}';
    _u VARCHAR;
BEGIN
    -- Do we need querying by other key types?
    IF key_type != 'sk_owner' THEN
        RETURN jsonb_build_object(
            'error', 'key_type must be sk_owner'
        );
    END IF;

    IF key_type = 'sk_owner' THEN
        FOREACH _pubkey IN ARRAY pubkeys
        LOOP
            SELECT a.name
                INTO _u
                FROM vsc_app.witnesses w
                JOIN hive.vsc_app_accounts a ON
                    a.id = w.id
                WHERE w.sk_owner = _pubkey
                LIMIT 1;
            IF _u IS NOT NULL THEN
                SELECT ARRAY_APPEND(_results, _u) INTO _results;
            END IF;
        END LOOP;
    END IF;
    RETURN array_to_json(_results)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

-- Bridge operations
CREATE OR REPLACE FUNCTION vsc_api.list_latest_deposits_hive(last_id INTEGER = NULL, count INTEGER = 100)
RETURNS jsonb
AS $function$
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    RETURN (
        WITH deposits AS (
            SELECT c.id, o.block_num, o.trx_in_block, o.ts, c.amount, c.asset, a.name
            FROM vsc_app.deposits_to_hive c
            JOIN vsc_app.l1_operations o ON
                o.id=c.in_op
            JOIN hive.vsc_app_accounts a ON
                a.id=c.dest_acc
            WHERE c.id <= COALESCE(last_id, 2147483647)
            ORDER BY c.id DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', id,
            'ts', ts,
            'in_op', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'l1_block', block_num,
            'username', name,
            'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset))
        )) FROM deposits
    );
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_latest_deposits_did(count INTEGER = 100)
RETURNS jsonb
AS $function$
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    RETURN (
        WITH deposits AS (
            SELECT c.id, o.block_num, o.trx_in_block, o.ts, c.amount, c.asset, a.did
            FROM vsc_app.deposits_to_did c
            JOIN vsc_app.l1_operations o ON
                o.id=c.in_op
            JOIN vsc_app.dids a ON
                a.id=c.dest_did
            ORDER BY c.id DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', id,
            'ts', ts,
            'in_op', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'l1_block', block_num,
            'did_key', did,
            'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset))
        )) FROM deposits
    );
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_latest_withdrawals(last_id INTEGER = NULL, count INTEGER = 100)
RETURNS jsonb
AS $function$
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    RETURN (
        WITH withdrawals AS (
            SELECT c.id, o.block_num, o.trx_in_block, o.ts, c.amount, c.asset, a.name
            FROM vsc_app.withdrawals c
            JOIN vsc_app.l1_operations o ON
                o.id=c.in_op
            JOIN hive.vsc_app_accounts a ON
                a.id=c.dest_acc
            WHERE c.id <= COALESCE(last_id, 2147483647)
            ORDER BY c.id DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', id,
            'ts', ts,
            'in_op', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'l1_block', block_num,
            'username', name,
            'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset))
        )) FROM withdrawals
    );
END $function$
LANGUAGE plpgsql STABLE;

-- Elections
CREATE OR REPLACE FUNCTION vsc_api.list_epochs(last_epoch INTEGER = NULL, count INTEGER = 100)
RETURNS jsonb
AS $function$
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    RETURN (
        WITH epochs AS (
            SELECT e.epoch, o.block_num, o.trx_in_block, o.ts, a.name, e.data_cid, e.sig, e.bv
            FROM vsc_app.election_results e
            JOIN vsc_app.l1_operations o ON
                o.id = e.proposed_in_op
            JOIN hive.vsc_app_accounts a ON
                a.id = e.proposer
            WHERE e.epoch <= COALESCE(last_epoch, 2147483647)
            ORDER BY e.epoch
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'epoch', epoch,
            'l1_block_num', block_num,
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'ts', ts,
            'proposer', name,
            'data_cid', data_cid,
            'sig', encode(sig, 'hex'),
            'bv', encode(bv, 'hex')
        )) FROM epochs
    );
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_election_at_epoch(epoch INTEGER, with_consensus_did BOOLEAN = FALSE)
RETURNS jsonb
AS $function$
BEGIN
    IF with_consensus_did IS TRUE THEN
        RETURN (
            SELECT jsonb_agg(jsonb_build_object(
                'username', name,
                'consensus_did', consensus_did
            ))
            FROM vsc_app.get_election_at_epoch(epoch)
        );
    ELSE
        RETURN (SELECT jsonb_agg(name) FROM vsc_app.get_election_at_epoch(epoch));
    END IF;
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_members_at_block(blk_num INTEGER, with_consensus_did BOOLEAN = FALSE)
RETURNS jsonb
AS $function$
BEGIN
    IF with_consensus_did IS TRUE THEN
        RETURN (
            SELECT jsonb_agg(jsonb_build_object(
                'username', name,
                'consensus_did', consensus_did
            ))
            FROM vsc_app.get_members_at_block(blk_num)
        );
    ELSE
        RETURN (SELECT jsonb_agg(name) FROM vsc_app.get_members_at_block(blk_num));
    END IF;
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_epoch(epoch_num INTEGER)
RETURNS jsonb
AS $function$
BEGIN
    RETURN (COALESCE((
        SELECT jsonb_build_object(
            'epoch', e.epoch,
            'l1_block_num', o.block_num,
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(o.block_num, o.trx_in_block)),
            'ts', o.ts,
            'proposer', a.name,
            'data_cid', e.data_cid,
            'election', (SELECT vsc_api.get_election_at_epoch(epoch_num, FALSE)),
            'members_at_start', (SELECT vsc_api.get_members_at_block(o.block_num - (o.block_num % 7200), FALSE)),
            'sig', encode(e.sig, 'hex'),
            'bv', encode(e.bv, 'hex')
        )
        FROM vsc_app.election_results e
        JOIN vsc_app.l1_operations o ON
            o.id = e.proposed_in_op
        JOIN hive.vsc_app_accounts a ON
            a.id = e.proposer
        WHERE e.epoch = epoch_num
    ), jsonb_build_object('error', 'epoch not found')));
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l2_blocks_in_epoch(epoch_num INTEGER, start_id INTEGER = 0, count INTEGER = 200)
RETURNS jsonb
AS $function$
DECLARE
    _start_op BIGINT;
    _end_op BIGINT;
BEGIN
    IF epoch_num < 0 THEN
        RETURN jsonb_build_object('error', 'epoch_num must be greater or equals to 0');
    ELSIF start_id < 0 THEN
        RETURN jsonb_build_object('error', 'start_id must be greater or equals to 0');
    ELSIF count < 1 OR count > 200 THEN
        RETURN jsonb_build_object('error', 'count must be between 1 and 200');
    END IF;

    SELECT proposed_in_op INTO _start_op FROM vsc_app.election_results WHERE epoch = epoch_num;
    IF _start_op IS NULL THEN
        RETURN jsonb_build_object('error', 'epoch does not exist');
    END IF;

    SELECT proposed_in_op INTO _end_op FROM vsc_app.election_results WHERE epoch = epoch_num+1;
    IF _end_op IS NULL THEN
        SELECT id INTO _end_op FROM vsc_app.l1_operations ORDER BY id DESC LIMIT 1;
        _end_op := _end_op + 1;
    END IF;

    RETURN COALESCE((
        WITH blocks AS (
            SELECT bk.id, l1_op.ts, bk.block_header_hash, a.name, bk.bv
            FROM vsc_app.blocks bk
            JOIN vsc_app.l1_operations l1_op ON
                bk.proposed_in_op = l1_op.id
            JOIN hive.vsc_app_accounts a ON
                bk.proposer = a.id
            WHERE bk.proposed_in_op >= _start_op AND bk.proposed_in_op < _end_op AND bk.id >= start_id
            ORDER BY bk.id ASC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', b.id,
            'ts', b.ts,
            'block_hash', b.block_header_hash,
            'proposer', b.name,
            'txs', (SELECT COUNT(*) FROM vsc_app.l2_txs t WHERE t.block_num = b.id)+(SELECT COUNT(*) FROM vsc_app.anchor_refs ar WHERE ar.block_num = b.id),
            'bv', encode(b.bv, 'hex')
        )) FROM blocks b
    ), '[]'::jsonb);
END $function$
LANGUAGE plpgsql STABLE;

-- Anchor refs
CREATE OR REPLACE FUNCTION vsc_api.list_anchor_refs(last_ref INTEGER = NULL, count INTEGER = 100)
RETURNS jsonb
AS $function$
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    RETURN (
        SELECT jsonb_agg(jsonb_build_object(
            'id', r.id,
            'cid', r.cid,
            'block_num', r.block_num,
            'ts', bo.ts,
            'tx_root', encode(r.tx_root, 'hex')
        ))
        FROM vsc_app.anchor_refs r
        JOIN vsc_app.blocks b ON
            b.id = r.block_num
        JOIN vsc_app.l1_operations bo ON
            bo.id = b.proposed_in_op
        WHERE r.id <= COALESCE(last_ref, 2147483647)
        LIMIT count
    );
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_anchor_ref_by_id(id INTEGER)
RETURNS jsonb
AS $function$
DECLARE
    aref_id ALIAS FOR id;
BEGIN
    RETURN (COALESCE(
        (SELECT jsonb_build_object(
            'id', r.id,
            'cid', r.cid,
            'block_num', r.block_num,
            'ts', bo.ts,
            'tx_root', encode(r.tx_root, 'hex'),
            'refs', (SELECT jsonb_agg(encode(tx_id, 'hex')) FROM vsc_app.anchor_ref_txs WHERE ref_id = r.id)
        )
        FROM vsc_app.anchor_refs r
        JOIN vsc_app.blocks b ON
            b.id = r.block_num
        JOIN vsc_app.l1_operations bo ON
            bo.id = b.proposed_in_op
        WHERE r.id = aref_id),
        jsonb_build_object('error', 'anchor ref not found')
    ));
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_anchor_ref_by_cid(cid VARCHAR)
RETURNS jsonb
AS $function$
DECLARE
    aref_cid ALIAS FOR cid;
BEGIN
    RETURN (COALESCE(
        (SELECT jsonb_build_object(
            'id', r.id,
            'cid', r.cid,
            'block_num', r.block_num,
            'ts', bo.ts,
            'tx_root', encode(r.tx_root, 'hex'),
            'refs', (SELECT jsonb_agg(encode(tx_id, 'hex')) FROM vsc_app.anchor_ref_txs WHERE ref_id = r.id)
        )
        FROM vsc_app.anchor_refs r
        JOIN vsc_app.blocks b ON
            b.id = r.block_num
        JOIN vsc_app.l1_operations bo ON
            bo.id = b.proposed_in_op
        WHERE r.cid = aref_cid),
        jsonb_build_object('error', 'anchor ref not found')
    ));
END $function$
LANGUAGE plpgsql STABLE;

-- Search by CID
CREATE OR REPLACE FUNCTION vsc_api.search_by_cid(cid VARCHAR)
RETURNS jsonb
AS $function$
DECLARE
    _cid ALIAS FOR cid;
    _result_int INTEGER;
    _result_varchar VARCHAR;
BEGIN
    -- Block search
    SELECT id INTO _result_int FROM vsc_app.blocks WHERE block_hash = _cid OR block_header_hash = _cid;
    IF _result_int IS NOT NULL THEN
        RETURN jsonb_build_object(
            'type', 'block',
            'result', _result_int
        );
    END IF;

    -- Transaction search
    SELECT tx_type::INTEGER INTO _result_int FROM vsc_app.l2_txs WHERE id = _cid;
    IF _result_int IS NOT NULL THEN
        IF _result_int = 1 THEN
            RETURN jsonb_build_object(
                'type', 'call_contract',
                'result', _cid
            );
        ELSIF _result_int = 2 THEN
            RETURN jsonb_build_object(
                'type', 'contract_output',
                'result', _cid
            );
        END IF;
    END IF;

    -- Contract search
    SELECT contract_id INTO _result_varchar FROM vsc_app.contracts WHERE contract_id = _cid;
    IF _result_varchar IS NOT NULL THEN
        RETURN jsonb_build_object(
            'type', 'contract',
            'result', _cid
        );
    END IF;

    -- Election search
    SELECT epoch INTO _result_int FROM vsc_app.election_results WHERE data_cid = _cid;
    IF _result_int IS NOT NULL THEN
        RETURN jsonb_build_object(
            'type', 'election_result',
            'result', _result_int
        );
    END IF;

    -- Anchor ref search
    SELECT a.id INTO _result_int FROM vsc_app.anchor_refs a WHERE a.cid = _cid;
    IF _result_int IS NOT NULL THEN
        RETURN jsonb_build_object(
            'type', 'anchor_ref',
            'result', _result_int
        );
    END IF;

    RETURN jsonb_build_object(
        'type', NULL,
        'result', NULL
    );
END $function$
LANGUAGE plpgsql STABLE;