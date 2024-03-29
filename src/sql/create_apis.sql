SET ROLE vsc_owner;

DROP SCHEMA IF EXISTS vsc_api CASCADE;
CREATE SCHEMA IF NOT EXISTS vsc_api AUTHORIZATION vsc_owner;
GRANT USAGE ON SCHEMA vsc_api TO vsc_user;
GRANT USAGE ON SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_api TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON TABLE hive.vsc_app_accounts TO vsc_user;
GRANT SELECT ON hive.vsc_app_transactions_view TO vsc_user;

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
        'operations', (SELECT COUNT(*) FROM vsc_app.l1_operations),
        'contracts', (SELECT COUNT(*) FROM vsc_app.contracts),
        'witnesses', (SELECT COUNT(*) FROM vsc_app.witnesses),
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
    _proposed_in_op BIGINT;
    _prev_block_hash VARCHAR = NULL;
    _block_id INTEGER;
    _proposed_in_tx_id BIGINT;
    _l1_tx vsc_app.l1_tx_type;
    _proposer_id INTEGER;
    _proposer TEXT;
    _merkle BYTEA;
    _sig BYTEA;
    _bv BYTEA;
BEGIN
    SELECT id, proposed_in_op, proposer, merkle_root, sig, bv INTO _block_id, _proposed_in_op, _proposer_id, _merkle, _sig, _bv
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
    SELECT l1_op.op_id INTO _proposed_in_tx_id
        FROM vsc_app.l1_operations l1_op
        WHERE l1_op.id = _proposed_in_op;
    SELECT * INTO _l1_tx FROM vsc_app.helper_get_tx_by_op_id(_proposed_in_tx_id);
    SELECT name INTO _proposer FROM hive.vsc_app_accounts WHERE id=_proposer_id;
    
    RETURN jsonb_build_object(
        'id', _block_id,
        'prev_block_hash', _prev_block_hash,
        'block_hash', blk_hash,
        'proposer', _proposer,
        'ts', _l1_tx.created_at,
        'l1_tx', _l1_tx.trx_hash,
        'l1_block', _l1_tx.block_num,
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
    _proposed_in_op BIGINT;
    _prev_block_hash VARCHAR = NULL;
    _block_hash VARCHAR;
    _proposed_in_tx_id BIGINT;
    _l1_tx vsc_app.l1_tx_type;
    _proposer_id INTEGER;
    _proposer TEXT;
    _merkle BYTEA;
    _sig BYTEA;
    _bv BYTEA;
BEGIN
    SELECT block_hash, proposed_in_op, proposer, merkle_root, sig, bv INTO _block_hash, _proposed_in_op, _proposer_id, _merkle, _sig, _bv
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
    SELECT l1_op.op_id INTO _proposed_in_tx_id
        FROM vsc_app.l1_operations l1_op
        WHERE l1_op.id = _proposed_in_op;
    SELECT * INTO _l1_tx FROM vsc_app.helper_get_tx_by_op_id(_proposed_in_tx_id);
    SELECT name INTO _proposer FROM hive.vsc_app_accounts WHERE id=_proposer_id;
    
    RETURN jsonb_build_object(
        'id', blk_id,
        'prev_block_hash', _prev_block_hash,
        'block_hash', _block_hash,
        'proposer', _proposer,
        'ts', _l1_tx.created_at,
        'l1_tx', _l1_tx.trx_hash,
        'l1_block', _l1_tx.block_num,
        'merkle_root', encode(_merkle, 'hex'),
        'signature', (jsonb_build_object(
            'sig', encode(_sig, 'hex'),
            'bv', encode(_bv, 'hex')
        ))
    );
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.block_type CASCADE;
CREATE TYPE vsc_api.block_type AS (
    id INTEGER,
    proposed_in_op BIGINT,
    block_hash VARCHAR,
    proposer INTEGER
);

CREATE OR REPLACE FUNCTION vsc_api.get_block_range(blk_id_start INTEGER, blk_count INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    b vsc_api.block_type;
    _block_details vsc_api.block_type[];
    _blocks jsonb[] DEFAULT '{}';
    _proposed_in_tx_id BIGINT;
    _l1_tx vsc_app.l1_tx_type;
    _proposer TEXT;
BEGIN
    IF blk_count > 1000 OR blk_count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'blk_count must be between 1 and 1000'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(bk.id, bk.proposed_in_op, bk.block_hash, bk.proposer)::vsc_api.block_type
            FROM vsc_app.blocks bk
            WHERE bk.id >= blk_id_start AND bk.id < blk_id_start+blk_count
    ) INTO _block_details;
    FOREACH b IN ARRAY _block_details
    LOOP
        SELECT l1_op.op_id INTO _proposed_in_tx_id
            FROM vsc_app.l1_operations l1_op
            WHERE l1_op.id = b.proposed_in_op;
        SELECT * INTO _l1_tx FROM vsc_app.helper_get_tx_by_op_id(_proposed_in_tx_id);
        SELECT name INTO _proposer FROM hive.vsc_app_accounts WHERE id=b.proposer;
        SELECT ARRAY_APPEND(_blocks, jsonb_build_object(
            'id', b.id,
            'ts', _l1_tx.created_at,
            'block_hash', b.block_hash,
            'proposer', _proposer,
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
    nonce INTEGER,
    op_id BIGINT,
    op_type INTEGER,
    op_name VARCHAR,
    block_num INTEGER,
    trx_in_block SMALLINT,
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
        SELECT ROW(o.id, hive.vsc_app_accounts.name, o.nonce, o.op_id, o.op_type, ot.op_name, ho.block_num, ho.trx_in_block, o.ts, ho.body::TEXT)::vsc_api.l1_op_type
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
    consensus_did VARCHAR,
    enabled BOOLEAN,
    enabled_at BIGINT,
    disabled_at BIGINT,
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
    _enabled_at_txhash VARCHAR;
    _disabled_at_txhash VARCHAR;
    _latest_git_commit VARCHAR;
BEGIN
    SELECT w.witness_id, name, w.did, w.consensus_did, w.enabled, l1_e.op_id AS enabled_at, l1_d.op_id AS disabled_at, w.git_commit, w.last_block, w.produced
        INTO result
        FROM vsc_app.witnesses w
        JOIN hive.vsc_app_accounts ON
            hive.vsc_app_accounts.id = w.id
        LEFT JOIN vsc_app.l1_operations l1_e ON
            l1_e.id = w.enabled_at
        LEFT JOIN vsc_app.l1_operations l1_d ON
            l1_d.id = w.disabled_at
        WHERE hive.vsc_app_accounts.name = username;
    SELECT trx_hash INTO _enabled_at_txhash FROM vsc_app.helper_get_tx_by_op_id(result.enabled_at);
    SELECT trx_hash INTO _disabled_at_txhash FROM vsc_app.helper_get_tx_by_op_id(result.disabled_at);
    SELECT git_commit INTO _latest_git_commit FROM vsc_app.vsc_node_git WHERE id=1;
    
    RETURN jsonb_build_object(
        'id', result.witness_id,
        'username', result.name,
        'did', result.did,
        'consensus_did', result.consensus_did,
        'enabled', result.enabled,
        'enabled_at', _enabled_at_txhash,
        'disabled_at', _disabled_at_txhash,
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
        SELECT ROW(w.witness_id, name, w.did, w.consensus_did, w.enabled, l1_e.op_id, l1_d.op_id, w.git_commit, w.last_block, w.produced)
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
            'enabled_at', (SELECT trx_hash FROM vsc_app.helper_get_tx_by_op_id(result.enabled_at)),
            'disabled_at', (SELECT trx_hash FROM vsc_app.helper_get_tx_by_op_id(result.disabled_at)),
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
    _bn INTEGER;
    _tb SMALLINT;
    _ts TIMESTAMP;
    _th TEXT;
BEGIN
    SELECT * INTO result FROM vsc_app.multisig_txrefs WHERE id=_id;
    SELECT block_num, trx_in_block, ts INTO _bn, _tb, _ts FROM vsc_app.l1_operations WHERE id=result.in_op;
    RETURN jsonb_build_object(
        'id', _id,
        'ts', _ts,
        'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(_bn, _tb)),
        'l1_block', _bn,
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
    _bn INTEGER;
    _tb SMALLINT;
    _ts TIMESTAMP;
    _th TEXT;
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
        SELECT block_num, trx_in_block, ts INTO _bn, _tb, _ts FROM vsc_app.l1_operations WHERE id=result.in_op;
        SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
            'id', r.id,
            'ts', _ts,
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(_bn, _tb)),
            'l1_block', _bn,
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
    nonce INTEGER,
    op_id BIGINT,
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
    _l1_tx vsc_app.l1_tx_type;
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
        SELECT * INTO _l1_tx FROM vsc_app.helper_get_tx_by_op_id(result.op_id);
        SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
            'id', result.id,
            'username', result.username,
            'nonce', result.nonce,
            'ts', _l1_tx.created_at,
            'type', result.op_name,
            'l1_tx', _l1_tx.trx_hash,
            'l1_block', _l1_tx.block_num,
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
        SELECT ROW(ho.id, ho.block_num, ho.trx_in_block, ho.timestamp, ho.body::TEXT)
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
        SELECT vo.id, va.name, vo.nonce, vo.op_id, vo.op_type, vt.op_name, _trx.block_num, _trx.trx_in_block, vo.ts, _trx.body::jsonb->>'value'
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
    _l1_tx vsc_app.l1_tx_type;
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
        SELECT * INTO _l1_tx FROM vsc_app.helper_get_tx_by_op_id(result.op_id);
        IF with_payload IS TRUE THEN
            SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
                'id', result.id,
                'username', result.username,
                'nonce', result.nonce,
                'type', result.op_name,
                'ts', _l1_tx.created_at,
                'l1_tx', _l1_tx.trx_hash,
                'l1_block', _l1_tx.block_num,
                'payload', (SELECT vsc_app.parse_l1_payload(result.op_name, result.body))
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
    contract_id VARCHAR,
    created_in_op BIGINT,
    name VARCHAR,
    description VARCHAR,
    code VARCHAR,
    block_num INTEGER,
    trx_in_block SMALLINT,
    ts TIMESTAMP
);

CREATE OR REPLACE FUNCTION vsc_api.list_latest_contracts(count INTEGER = 100)
RETURNS jsonb
AS
$function$
DECLARE
    result vsc_api.contract_type;
    results vsc_api.contract_type[];
    results_arr jsonb[] DEFAULT '{}';
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(c.*, o.block_num, o.trx_in_block, o.ts)
        FROM vsc_app.contracts c
        JOIN vsc_app.l1_operations o ON
            o.id=c.created_in_op
        ORDER BY o.ts DESC
        LIMIT count
    ) INTO results;

    FOREACH result IN ARRAY results
    LOOP
        SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
            'contract_id', result.contract_id,
            'created_in_op', (SELECT vsc_app.get_tx_hash_by_op(result.block_num, result.trx_in_block)),
            'created_in_l1_block', result.block_num,
            'created_at', result.ts,
            'name', result.name,
            'description', result.description,
            'code', result.code
        )) INTO results_arr;
    END LOOP;

    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_contract_by_id(id VARCHAR)
RETURNS jsonb
AS
$function$
DECLARE
	ct_id ALIAS FOR id;
    result vsc_api.contract_type = NULL;
BEGIN
    SELECT c.*, o.block_num, o.trx_in_block, o.ts
        INTO result
        FROM vsc_app.contracts c
        JOIN vsc_app.l1_operations o ON
            o.id=c.created_in_op
        WHERE c.contract_id = ct_id;
    IF result = NULL THEN
        RETURN jsonb_build_object(
            'error', 'contract not found'
        );
    END IF;
    RETURN jsonb_build_object(
        'contract_id', result.contract_id,
        'created_in_op', (SELECT vsc_app.get_tx_hash_by_op(result.block_num, result.trx_in_block)),
        'created_in_l1_block', result.block_num,
        'created_at', result.ts,
        'name', result.name,
        'description', result.description,
        'code', result.code
    );
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

DROP TYPE IF EXISTS vsc_api.deposit_type CASCADE;
CREATE TYPE vsc_api.deposit_type AS (
    id INTEGER,
    in_op BIGINT,
    amount INTEGER,
    asset SMALLINT,
    contract_id VARCHAR,
    name VARCHAR,
    op_id BIGINT
);

CREATE OR REPLACE FUNCTION vsc_api.list_latest_deposits(count INTEGER = 100)
RETURNS jsonb
AS
$function$
DECLARE
    result vsc_api.deposit_type;
    results vsc_api.deposit_type[];
    results_arr jsonb[] DEFAULT '{}';
    _l1_tx vsc_app.l1_tx_type;
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(c.*, a.name, o.op_id)
        FROM vsc_app.deposits c
        JOIN vsc_app.l1_operations o ON
            o.id=c.in_op
        JOIN hive.vsc_app_accounts a ON
            a.id=o.user_id
        ORDER BY c.id DESC
        LIMIT count
    ) INTO results;

    FOREACH result IN ARRAY results
    LOOP
        SELECT * INTO _l1_tx FROM vsc_app.helper_get_tx_by_op_id(result.op_id);
        SELECT ARRAY_APPEND(results_arr, jsonb_build_object(
            'id', result.id,
            'ts', _l1_tx.created_at,
            'in_op', _l1_tx.trx_hash,
            'l1_block', _l1_tx.block_num,
            'username', result.name,
            'amount', ROUND(result.amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(result.asset)),
            'contract_id', result.contract_id
        )) INTO results_arr;
    END LOOP;

    RETURN array_to_json(results_arr)::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;