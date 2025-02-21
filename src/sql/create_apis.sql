SET ROLE vsc_owner;

DROP SCHEMA IF EXISTS vsc_api CASCADE;
CREATE SCHEMA IF NOT EXISTS vsc_api AUTHORIZATION vsc_owner;
GRANT USAGE ON SCHEMA vsc_api TO vsc_user;
GRANT USAGE ON SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_api TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON TABLE hafd.vsc_app_accounts TO vsc_user;
GRANT SELECT ON vsc_app.transactions_view TO vsc_user;
GRANT SELECT ON vsc_app.operations_view TO vsc_user;

-- GET /
CREATE OR REPLACE FUNCTION vsc_api.home()
RETURNS jsonb
AS
$function$
BEGIN
    RETURN (
    WITH s1 AS (SELECT * FROM vsc_app.state),
        s2 AS (SELECT * FROM vsc_app.subindexer_state)
    SELECT jsonb_build_object(
        'last_processed_block', s1.last_processed_block,
        'last_processed_subindexer_op', s2.last_processed_op,
        'db_version', s1.db_version,
        'epoch', (SELECT epoch FROM vsc_app.election_results ORDER BY epoch DESC LIMIT 1),
        'l2_block_height', s2.l2_head_block,
        'transactions', (SELECT COUNT(*) FROM vsc_app.contract_calls),
        'operations', (SELECT COUNT(*) FROM vsc_app.l1_operations),
        'contracts', (SELECT COUNT(*) FROM vsc_app.contracts),
        'witnesses', (SELECT COUNT(*) FROM vsc_app.witnesses),
        'bridge_txs', (SELECT COUNT(*) FROM vsc_app.deposits)+(SELECT COUNT(*) FROM vsc_app.withdrawals),
        'anchor_refs', (SELECT COUNT(*) FROM vsc_app.anchor_refs),
        'txrefs', (SELECT COUNT(*) FROM vsc_app.multisig_txrefs)
    ) FROM s1, s2);
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
    _vw INTEGER;
BEGIN
    SELECT b.id, b.block_header_hash, b.block_hash, o.block_num, o.trx_in_block, o.ts, a.name, b.merkle_root, b.sig, b.bv, b.voted_weight
        INTO _block_id, _block_hash, _block_body_hash, _block_num, _tb, _ts, _proposer, _merkle, _sig, _bv, _vw
        FROM vsc_app.l2_blocks b
        JOIN vsc_app.l1_operations o ON
            o.id = b.proposed_in_op
        JOIN hafd.vsc_app_accounts a ON
            a.id = b.proposer
        WHERE b.block_header_hash = blk_hash OR b.block_hash = blk_hash;
    IF _block_hash IS NULL THEN
        RETURN jsonb_build_object('error', 'Block does not exist');
    END IF;
    IF _block_id > 1 THEN
        SELECT b.block_header_hash INTO _prev_block_hash
            FROM vsc_app.l2_blocks b
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
        'txs', (SELECT vsc_app.get_l2_operation_count_in_block(_block_id)),
        'merkle_root', encode(_merkle, 'hex'),
        'voted_weight', _vw,
        'eligible_weight', (SELECT SUM(weight) FROM vsc_app.get_members_at_block(_block_num)),
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
    _vw INTEGER;
BEGIN
    SELECT b.block_header_hash, b.block_hash, o.block_num, o.trx_in_block, o.ts, a.name, b.merkle_root, b.sig, b.bv, b.voted_weight
        INTO _block_hash, _block_body_hash, _block_num, _tb, _ts, _proposer, _merkle, _sig, _bv, _vw
        FROM vsc_app.l2_blocks b
        JOIN vsc_app.l1_operations o ON
            o.id = b.proposed_in_op
        JOIN hafd.vsc_app_accounts a ON
            a.id = b.proposer
        WHERE b.id = blk_id;
    IF _block_hash IS NULL THEN
        RETURN jsonb_build_object('error', 'Block does not exist');
    END IF;
    IF blk_id > 1 THEN
        SELECT b.block_header_hash INTO _prev_block_hash
            FROM vsc_app.l2_blocks b
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
        'txs', (SELECT vsc_app.get_l2_operation_count_in_block(blk_id)),
        'merkle_root', encode(_merkle, 'hex'),
        'voted_weight', _vw,
        'eligible_weight', (SELECT SUM(weight) FROM vsc_app.get_members_at_block(_block_num)),
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
            'txs', (SELECT vsc_app.get_l2_operation_count_in_block(bk.id)),
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(l1_op.block_num, l1_op.trx_in_block)),
            'l1_block', l1_op.block_num,
            'voted_weight', bk.voted_weight,
            'eligible_weight', (SELECT SUM(weight) FROM vsc_app.get_members_at_block(l1_op.block_num-1)),
            'bv', encode(bk.bv, 'hex')
        ))
        FROM vsc_app.l2_blocks bk
        JOIN vsc_app.l1_operations l1_op ON
            bk.proposed_in_op = l1_op.id
        JOIN hafd.vsc_app_accounts a ON
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
        SELECT t.cid AS id, t.block_num, t.idx_in_block, t.tx_type, MIN(d.did) did, COUNT(a.id) auth_count
            FROM vsc_app.l2_txs t
            LEFT JOIN vsc_app.l2_tx_multiauth a ON
                a.id = t.id
            LEFT JOIN vsc_app.dids d ON
                a.did = d.id
            WHERE t.block_num = blk_id
            GROUP BY t.id
        UNION ALL
        SELECT o.id, o.block_num, o.idx_in_block, 2, NULL, 0
            FROM vsc_app.contract_outputs o
            WHERE o.block_num = blk_id
        UNION ALL
        SELECT e.cid, e.block_num, e.idx_in_block, 6, NULL, 0
            FROM vsc_app.events e
            WHERE e.block_num = blk_id
        UNION ALL
        SELECT r.cid AS id, r.block_num, r.idx_in_block, 5, NULL, 0
            FROM vsc_app.anchor_refs r
            WHERE r.block_num = blk_id
        ORDER BY idx_in_block ASC
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', r.id,
            'block_num', r.block_num,
            'idx_in_block', r.idx_in_block,
            'tx_type', (SELECT ot.op_name FROM vsc_app.l2_operation_types ot WHERE ot.id=r.tx_type),
            'did', r.did,
            'auth_count', r.auth_count
        )
    ), '[]'::jsonb) FROM result r);
END $function$
LANGUAGE plpgsql STABLE;

-- Called by vsc_api.get_l1_tx_all_outputs
CREATE OR REPLACE FUNCTION vsc_api.get_l1_tx(trx_id VARCHAR, op_pos INTEGER)
RETURNS jsonb
AS $function$
DECLARE
    l1_op_id BIGINT;
    op_position ALIAS FOR op_pos;
    _bn INTEGER;
    _op_name VARCHAR;
BEGIN
    SELECT o.id, ht.block_num, ot.op_name INTO l1_op_id, _bn, _op_name
        FROM vsc_app.transactions_view ht
        JOIN vsc_app.l1_operations o ON
            o.block_num = ht.block_num AND o.trx_in_block = ht.trx_in_block
        JOIN vsc_app.l1_operation_types ot ON
            ot.id = o.op_type
        WHERE ht.trx_hash = decode(trx_id, 'hex')::BYTEA AND o.op_pos = op_position;
    IF l1_op_id IS NULL THEN
        RETURN jsonb_build_object('error', 'could not find transaction');
    END IF;
    IF _op_name = 'tx' THEN
        SELECT ot.op_name INTO _op_name FROM vsc_app.l1_txs t JOIN vsc_app.l2_operation_types ot ON ot.id = t.tx_type WHERE t.id = l1_op_id;
        IF _op_name = 'call_contract' THEN
            RETURN (
                SELECT (jsonb_build_object(
                    'tx_type', _op_name,
                    'io_gas', d.io_gas,
                    'contract_output', d.contract_output,
                    'events', vsc_app.get_events_in_tx_by_id(l1_op_id::INTEGER, 1)
                ))
                FROM vsc_app.l1_txs t
                JOIN vsc_app.contract_calls d ON
                    t.details = d.id
                WHERE t.id = l1_op_id
            );
        ELSIF _op_name = 'transfer' OR _op_name = 'withdraw' THEN
            RETURN jsonb_build_object(
                'tx_type', _op_name,
                'events', vsc_app.get_events_in_tx_by_id(l1_op_id::INTEGER, 1)
            );
        ELSE
            RETURN jsonb_build_object('error', 'unsupported call op type');
        END IF;
    ELSIF _op_name = 'election_result' THEN
        RETURN (
            SELECT (jsonb_build_object(
                'epoch', e.epoch,
                'proposer', a.name,
                'data_cid', e.data_cid,
                'voted_weight', e.voted_weight,
                'eligible_weight', (SELECT SUM(me.weight) FROM vsc_app.get_members_at_block(_bn-1) me),
                'sig', encode(e.sig, 'hex'),
                'bv', encode(e.bv, 'hex')
            ))
            FROM vsc_app.election_results e
            JOIN hafd.vsc_app_accounts a ON
                a.id = e.proposer
            WHERE e.proposed_in_op = l1_op_id
        );
    ELSIF _op_name = 'propose_block' THEN
        RETURN (
            SELECT (jsonb_build_object(
                'id', b.id,
                'prev_block_hash', (
                    SELECT pb.block_header_hash
                    FROM vsc_app.l2_blocks pb
                    WHERE pb.id = b.id-1
                ),
                'block_hash', b.block_header_hash,
                'block_body_hash', b.block_hash,
                'proposer', (
                    SELECT bp.name FROM hafd.vsc_app_accounts bp WHERE bp.id = b.proposer
                ),
                'txs', (SELECT vsc_app.get_l2_operation_count_in_block(b.id)),
                'merkle_root', encode(b.merkle_root, 'hex'),
                'voted_weight', b.voted_weight,
                'eligible_weight', (SELECT SUM(mb.weight) FROM vsc_app.get_members_at_block(_bn) mb),
                'signature', (jsonb_build_object(
                    'sig', encode(b.sig, 'hex'),
                    'bv', encode(b.bv, 'hex')
                ))
            ))
            FROM vsc_app.l2_blocks b
            WHERE b.proposed_in_op = l1_op_id
        );
    ELSIF _op_name = 'create_contract' THEN
        RETURN (
            SELECT jsonb_build_object('contract_id', c.contract_id)
            FROM vsc_app.contracts c
            WHERE c.created_in_op = l1_op_id
        );
    ELSE
        RETURN jsonb_build_object('error', 'unsupported operation type');
    END IF;
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l1_tx_all_outputs(trx_id VARCHAR)
RETURNS jsonb
AS $function$
DECLARE
    _bn INTEGER;
    _tb SMALLINT;
    op_nums INTEGER[];
    op_num INTEGER;
    result jsonb;
    result_arr jsonb[] DEFAULT '{}';
BEGIN
    SELECT ARRAY(
        SELECT ho.op_pos
            FROM hive.transactions_view ht
            JOIN hive.operations_view ho ON
                ho.block_num = ht.block_num AND ho.trx_in_block = ht.trx_in_block
            WHERE trx_hash = decode(trx_id, 'hex')
    ) INTO op_nums;

    SELECT ht.block_num, ht.trx_in_block INTO _bn, _tb
        FROM vsc_app.transactions_view ht
        WHERE ht.trx_hash = decode(trx_id, 'hex')::BYTEA;

    IF op_nums IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    FOREACH op_num IN ARRAY op_nums
    LOOP
        IF (SELECT EXISTS (SELECT 1 FROM vsc_app.l1_operations WHERE block_num = _bn AND trx_in_block = _tb AND op_pos = op_num)) THEN
            SELECT vsc_api.get_l1_tx(trx_id, op_num) INTO result;
            IF NOT result ? 'error' THEN
                SELECT ARRAY_APPEND(result_arr, result) INTO result_arr;
            ELSE
                SELECT ARRAY_APPEND(result_arr, NULL) INTO result_arr;
            END IF;
        END IF;
    END LOOP;
    RETURN array_to_json(result_arr)::jsonb;
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
        'id', t.cid,
        'block_num', t.block_num,
        'idx_in_block', t.idx_in_block,
        'ts', bo.ts,
        'tx_type', ot.op_name,
        'nonce', t.nonce,
        'signers', (
            SELECT jsonb_agg(k.did)
            FROM vsc_app.l2_tx_multiauth ma
            JOIN vsc_app.dids k ON
                ma.did = k.id
            WHERE ma.id = t.id
        ),
        'events', (SELECT vsc_app.get_events_in_tx_by_id(t.id, 2))
    ), t.tx_type, t.details
    INTO _result, _tx_type, _tx_id
    FROM vsc_app.l2_txs t
    JOIN vsc_app.l2_operation_types ot ON
        ot.id = t.tx_type
    JOIN vsc_app.l2_blocks b ON
        b.id = t.block_num
    JOIN vsc_app.l1_operations bo ON
        bo.id = b.proposed_in_op
    WHERE t.cid = trx_id;

    IF _result IS NULL THEN
        RETURN jsonb_build_object('error', 'transaction not found');
    END IF;

    IF _tx_type = 1 THEN
        _result := _result || (
            SELECT jsonb_build_object(
                'input', trx_id,
                'input_src', _input_src,
                'output', d.contract_output_tx_id,
                'contract_id', d.contract_id,
                'contract_action', d.contract_action,
                'payload', (d.payload->0),
                'io_gas', d.io_gas,
                'contract_output', d.contract_output
            )
            FROM vsc_app.contract_calls d
            WHERE d.id = _tx_id
        );
    ELSIF _tx_type = 3 THEN
        _result := jsonb_set(_result, '{payload}', (
            SELECT jsonb_build_object(
                'from', (SELECT vsc_app.l2_account_id_to_str(d.from_id, d.from_acctype)),
                'to', (SELECT vsc_app.l2_account_id_to_str(d.to_id, d.to_acctype)),
                'amount', d.amount,
                'asset', (SELECT vsc_app.asset_by_id(d.coin)),
                'memo', d.memo
            )
            FROM vsc_app.transfers d
            WHERE d.id = _tx_id
        ));
    ELSIF _tx_type = 4 THEN
        _result := jsonb_set(_result, '{payload}', (
            SELECT jsonb_build_object(
                'from', (SELECT vsc_app.l2_account_id_to_str(d.from_id, d.from_acctype)),
                'to', (SELECT vsc_app.l2_account_id_to_str(d.to_id, 1::SMALLINT)),
                'amount', d.amount,
                'asset', (SELECT vsc_app.asset_by_id(d.asset)),
                'memo', d.memo
            )
            FROM vsc_app.l2_withdrawals d
            WHERE d.id = _tx_id
        ));
    END IF;

    RETURN _result;
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l2_tx_history_by_did(did VARCHAR, count INTEGER = 100, last_nonce INTEGER = NULL)
RETURNS jsonb AS $$
DECLARE
    _did ALIAS FOR did;
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

    RETURN COALESCE((
        WITH history AS (
            SELECT t.id, t.cid, t.block_num, t.idx_in_block, l2bp.ts, ot.op_name, tm.nonce_counter
            , (CASE
                WHEN t.tx_type = 1 THEN 
                    jsonb_build_object(
                        'contract_id', cc.contract_id,
                        'action', cc.contract_action,
                        'io_gas', cc.io_gas
                    )
                WHEN t.tx_type = 3 THEN
                    jsonb_build_object(
                        'from', vsc_app.l2_account_id_to_str(xf.from_id, xf.from_acctype),
                        'to', vsc_app.l2_account_id_to_str(xf.to_id, xf.to_acctype),
                        'amount', xf.amount,
                        'token', vsc_app.asset_by_id(xf.coin),
                        'memo', xf.memo
                    )
                WHEN t.tx_type = 4 THEN
                    jsonb_build_object(
                        'from', vsc_app.l2_account_id_to_str(wd.from_id, wd.from_acctype),
                        'to', vsc_app.l2_account_id_to_str(wd.to_id, 1::SMALLINT),
                        'amount', wd.amount,
                        'token', vsc_app.asset_by_id(wd.asset),
                        'memo', wd.memo
                    )
                END
            ) details
            FROM vsc_app.l2_tx_multiauth tm
            JOIN vsc_app.l2_txs t ON
                t.id = tm.id
            JOIN vsc_app.l2_operation_types ot ON
                ot.id = t.tx_type
            JOIN vsc_app.l2_blocks l2b ON
                l2b.id = t.block_num
            JOIN vsc_app.l1_operations l2bp ON
                l2bp.id = l2b.proposed_in_op
            LEFT JOIN vsc_app.contract_calls cc ON
                cc.id = t.details AND t.tx_type = 1
            LEFT JOIN vsc_app.transfers xf ON
                xf.id = t.details AND t.tx_type = 3
            LEFT JOIN vsc_app.l2_withdrawals wd ON
                wd.id = t.details AND t.tx_type = 4
            WHERE tm.did = (SELECT id FROM vsc_app.dids d WHERE d.did=_did) AND (SELECT CASE WHEN last_nonce IS NOT NULL THEN tm.nonce_counter <= last_nonce ELSE TRUE END)
            ORDER BY tm.nonce_counter DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', h.cid,
            'block_num', h.block_num,
            'idx_in_block', h.idx_in_block,
            'ts', h.ts,
            'tx_type', h.op_name,
            'nonce', h.nonce_counter,
            'details', h.details
        )) FROM history h
    ), '[]'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

-- Event history by 'did:' or 'hive:' prefixed account name
-- last_event_pos are tx_pos and evt_pos bits concatenated with 2 byte each
CREATE OR REPLACE FUNCTION vsc_api.get_event_history_by_account_name(account_name VARCHAR, count INTEGER = 100, last_nonce INTEGER = NULL)
RETURNS jsonb AS $$
DECLARE
    _owner_name VARCHAR := account_name;
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    ELSIF last_nonce IS NOT NULL AND last_nonce < 0 THEN
        RETURN jsonb_build_object(
            'error', 'last_nonce must be greater than or equal to 0 if not null'
        );
    END IF;

    IF starts_with(account_name, 'hive:') IS FALSE AND starts_with(account_name, 'did:') IS FALSE THEN
        -- hive: l1 account
        _owner_name := 'hive:' || account_name;
    END IF;
    RETURN COALESCE((
        WITH history AS (
            SELECT te.event_id evt_id, ev.cid evt_cid, te.tx_pos, te.evt_pos, te.nonce_counter, ev.block_num, bp.ts, encode(ht.trx_hash, 'hex') || '-' || t1.op_pos l1_tx_id, t2.cid l2_cid, te.evt_type, vsc_app.asset_by_id(te.token) token, te.amount, te.memo
            FROM vsc_app.l2_tx_events te
            JOIN vsc_app.events ev ON
                ev.id = te.event_id
            JOIN vsc_app.l2_blocks b ON
                b.id = ev.block_num
            JOIN vsc_app.l1_operations bp ON
                bp.id = b.proposed_in_op
            LEFT JOIN vsc_app.l2_txs t2 ON
                t2.id = te.l2_tx_id
            LEFT JOIN vsc_app.l1_operations t1 ON
                t1.id = te.l1_tx_id
            LEFT JOIN hive.irreversible_transactions_view ht ON
                ht.block_num = t1.block_num AND ht.trx_in_block = t1.trx_in_block
            WHERE
                te.owner_name = _owner_name AND
                (CASE WHEN last_nonce IS NOT NULL THEN te.nonce_counter <= last_nonce ELSE TRUE END)
            ORDER BY te.nonce_counter DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', COALESCE(l1_tx_id, l2_cid),
            'block_num', block_num,
            'ts', ts,
            'nonce', nonce_counter,
            'event_id', evt_id,
            'event_cid', evt_cid,
            'tx_pos', tx_pos,
            'pos_in_tx', evt_pos,
            'event', jsonb_build_object(
                't', evt_type,
                'tk', token,
                'amt', amount,
                'memo', memo
            )
        )) FROM history
    ), '[]'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

-- todo: remove after replacing this call on discord bot
CREATE OR REPLACE FUNCTION vsc_api.get_l1_contract_call(trx_id VARCHAR, op_pos INTEGER = 0)
RETURNS jsonb
AS $function$
DECLARE
    _result jsonb;
    _tb SMALLINT;
    _bn INTEGER;
    _ra jsonb;
    _rpa jsonb;
    _op_pos ALIAS FOR op_pos;
BEGIN
    SELECT ho.block_num, ho.trx_in_block, ho.body::jsonb->'value'->'required_auths', ho.body::jsonb->'value'->'required_posting_auths'
        INTO _bn, _tb, _ra, _rpa
        FROM hive.transactions_view ht
        JOIN hive.operations_view ho ON
            ho.block_num = ht.block_num AND ho.trx_in_block = ht.trx_in_block
        WHERE trx_hash = decode(trx_id, 'hex');
    IF _tb IS NULL OR _bn IS NULL THEN
        RETURN jsonb_build_object('error', 'could not find L1 transaction');
    END IF;
    SELECT jsonb_build_object(
        'id', o.id,
        'block_num', _bn,
        'idx_in_block', _tb,
        'ts', o.ts,
        'tx_type', 'call_contract',
        'nonce', o.nonce,
        'input', trx_id,
        'input_src', 'hive',
        'output', d.contract_output_tx_id,
        'signers', jsonb_build_object(
            'active', _ra,
            'posting', _rpa
        ),
        'contract_id', d.contract_id,
        'contract_action', d.contract_action,
        'payload', (d.payload->0),
        'io_gas', d.io_gas,
        'contract_output', d.contract_output
    )
    INTO _result
    FROM vsc_app.l1_operations o
    JOIN vsc_app.l1_txs t ON
        t.id = o.id
    JOIN vsc_app.contract_calls d ON
        t.details = d.id
    WHERE o.block_num = _bn AND o.trx_in_block = _tb AND o.op_pos = _op_pos AND o.op_type = 5;

    RETURN COALESCE(_result, jsonb_build_object('error', 'could not find contract call operation in L1 transaction'));
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_contract_output(cid VARCHAR)
RETURNS jsonb
AS $function$
DECLARE
    co_cid ALIAS FOR cid;
BEGIN
    RETURN COALESCE((
        SELECT jsonb_build_object(
            'id', co_cid,
            'block_num', co.block_num,
            'idx_in_block', co.idx_in_block,
            'ts', bo.ts,
            'contract_id', co.contract_id,
            'total_io_gas', co.total_io_gas,
            'outputs', (
                SELECT json_agg(jsonb_build_object(
                    'src', (CASE WHEN t.id IS NULL THEN 'hive' ELSE 'vsc' END),
                    'tx_id', COALESCE(t.cid, encode(ht.trx_hash, 'hex')),
                    'op_pos', l1o.op_pos,
                    'output', c.contract_output
                ))
                FROM vsc_app.contract_calls c
                LEFT JOIN vsc_app.l2_txs t ON
                    c.id = t.details
                LEFT JOIN vsc_app.l1_txs t1 ON
                    c.id = t1.details
                LEFT JOIN vsc_app.l1_operations l1o ON
                    t1.id = l1o.id
                LEFT JOIN hive.transactions_view ht ON
                    ht.block_num = l1o.block_num AND ht.trx_in_block = l1o.trx_in_block
                WHERE (t.tx_type = 1 OR t1.tx_type = 1) AND c.contract_output_tx_id = co_cid
            )
        )
        FROM vsc_app.contract_outputs co
        JOIN vsc_app.l2_blocks b ON
            b.id = co.block_num
        JOIN vsc_app.l1_operations bo ON
            bo.id = b.proposed_in_op
        WHERE co.id = co_cid
    ), jsonb_build_object('error', 'contract output not found'));
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_event(cid VARCHAR, flat_events_arr BOOLEAN = FALSE)
RETURNS jsonb
AS $function$
DECLARE
    event_cid ALIAS FOR cid;
BEGIN
    RETURN COALESCE((
        SELECT jsonb_build_object(
            'id', event_cid,
            'block_num', ev.block_num,
            'idx_in_block', ev.idx_in_block,
            'ts', bo.ts,
            'events', (SELECT CASE WHEN flat_events_arr THEN vsc_app.get_event_details2(ev.id) ELSE vsc_app.get_event_details(ev.id) END)
        )
        FROM vsc_app.events ev
        JOIN vsc_app.l2_blocks b ON
            b.id = ev.block_num
        JOIN vsc_app.l1_operations bo ON
            bo.id = b.proposed_in_op
        WHERE ev.cid = event_cid
    ), jsonb_build_object('error', 'event not found'));
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l1_operations_by_l1_blocks(l1_blk_start INTEGER, l1_blk_count INTEGER, full_tx_body BOOLEAN = FALSE)
RETURNS jsonb AS $$
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

    RETURN COALESCE((
        WITH op AS (
            SELECT o.id, hafd.vsc_app_accounts.name, o.nonce, o.op_type, ot.op_name, ho.block_num, ho.trx_in_block, ho.op_pos, o.ts, ho.body::TEXT
            FROM vsc_app.l1_operations o
            JOIN vsc_app.l1_operation_types ot ON
                ot.id = o.op_type
            JOIN hive.operations_view ho ON
                ho.id = o.op_id
            JOIN hafd.vsc_app_accounts ON
                hafd.vsc_app_accounts.id = o.user_id
            WHERE ho.block_num >= l1_blk_start AND ho.block_num < l1_blk_start+l1_blk_count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', op.id,
            'username', op.name,
            'nonce', op.nonce,
            'type', op.op_name,
            'block_num', op.block_num,
            'l1_tx', vsc_app.get_tx_hash_by_op(op.block_num, op.trx_in_block),
            'ts', op.ts,
            'payload', (CASE WHEN full_tx_body THEN op.body::jsonb->'value' ELSE vsc_app.parse_l1_payload(op.op_name, op.body::jsonb->'value') END)
        )) FROM op
    ), '[]'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l1_user(username VARCHAR)
RETURNS jsonb AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'name', username,
            'tx_count', COALESCE(u.count, 0),
            'event_count', COALESCE(u.event_count, 0),
            'deposit_count', COALESCE(u.deposit_count, 0),
            'withdraw_req_count', COALESCE(u.wdrq_count, 0),
            'last_activity', COALESCE(u.last_op_ts, '1970-01-01T00:00:00')
        )
        FROM vsc_app.l1_users u
        RIGHT JOIN hafd.vsc_app_accounts ac ON
            ac.id = u.id
        WHERE ac.name=username
    );
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_l2_user(did VARCHAR)
RETURNS jsonb AS $$
DECLARE
    _did ALIAS FOR did;
BEGIN
    IF starts_with(_did, 'hive:') THEN
        RETURN vsc_api.get_l1_user(REPLACE(_did, 'hive:', ''));
    END IF;
    RETURN (
        SELECT jsonb_build_object(
            'name', _did,
            'tx_count', COALESCE(d.count, 0),
            'event_count', COALESCE(d.event_count, 0),
            'deposit_count', COALESCE(d.deposit_count, 0),
            'withdraw_req_count', COALESCE(d.wdrq_count, 0),
            'last_activity', COALESCE(d.last_op_ts, '1970-01-01T00:00:00')
        )
        FROM vsc_app.dids d
        WHERE d.did = _did
    );
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_witness(username VARCHAR)
RETURNS jsonb AS $$
BEGIN    
    RETURN COALESCE((
        SELECT jsonb_build_object(
            'id', w.witness_id,
            'username', a.name,
            'did', w.did,
            'consensus_did', w.consensus_did,
            'enabled', w.enabled,
            'enabled_at', vsc_app.get_tx_hash_by_op(l1_e.block_num, l1_e.trx_in_block),
            'disabled_at', vsc_app.get_tx_hash_by_op(l1_d.block_num, l1_d.trx_in_block),
            'git_commit', w.git_commit,
            'latest_git_commit', (SELECT git_commit FROM vsc_app.vsc_node_git WHERE id=1),
            'is_up_to_date', ((SELECT git_commit FROM vsc_app.vsc_node_git WHERE id=1) = w.git_commit),
            'last_block', w.last_block,
            'produced', w.produced
        )
        FROM vsc_app.witnesses w
        JOIN hafd.vsc_app_accounts a ON
            a.id = w.id
        LEFT JOIN vsc_app.l1_operations l1_e ON
            l1_e.id = w.enabled_at
        LEFT JOIN vsc_app.l1_operations l1_d ON
            l1_d.id = w.disabled_at
        WHERE a.name = username
    ), '{"id":null,"error":"witness does not exist"}'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_witnesses_by_id(id_start INTEGER = 0, count INTEGER = 50)
RETURNS jsonb AS $$
BEGIN
    IF count > 50 OR count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 50'
        );
    END IF;
    RETURN COALESCE((
        WITH result AS (
            SELECT w.witness_id, a.name, w.did, w.consensus_did, w.enabled, vsc_app.get_tx_hash_by_op(l1_e.block_num, l1_e.trx_in_block) enabled_at, vsc_app.get_tx_hash_by_op(l1_d.block_num, l1_d.trx_in_block) disabled_at, w.git_commit, w.last_block, w.produced
            FROM vsc_app.witnesses w
            JOIN hafd.vsc_app_accounts a ON
                a.id = w.id
            LEFT JOIN vsc_app.l1_operations l1_e ON
                l1_e.id = w.enabled_at
            LEFT JOIN vsc_app.l1_operations l1_d ON
                l1_d.id = w.disabled_at
            WHERE w.witness_id >= id_start
            ORDER BY w.witness_id
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', r.witness_id,
            'username', r.name,
            'did', r.did,
            'consensus_did', r.consensus_did,
            'enabled', r.enabled,
            'enabled_at', r.enabled_at,
            'disabled_at', r.disabled_at,
            'git_commit', r.git_commit,
            'is_up_to_date', ((SELECT git_commit FROM vsc_app.vsc_node_git WHERE id=1) = r.git_commit),
            'last_block', r.last_block,
            'produced', r.produced
        )) FROM result r
    ));
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_op_history_by_l1_user(username VARCHAR, count INTEGER = 50, last_nonce INTEGER = NULL, bitmask_filter BIGINT = NULL)
RETURNS jsonb AS $$
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

    RETURN COALESCE((
        WITH result AS (
            SELECT o.id, a.name, o.nonce, o.block_num, o.trx_in_block, o.ts, ot.op_name, ho.body::jsonb->'value' body
            FROM vsc_app.l1_operations o
            JOIN vsc_app.l1_operation_types ot ON
                ot.id = o.op_type
            JOIN hafd.vsc_app_accounts a ON
                a.id = o.user_id
            JOIN hive.operations_view ho ON
                ho.id = o.op_id
            WHERE a.name = username AND
                (SELECT CASE WHEN last_nonce IS NOT NULL THEN o.nonce <= last_nonce ELSE TRUE END) AND
                (SELECT CASE WHEN bitmask_filter IS NOT NULL THEN (ot.filterer & bitmask_filter) > 0 ELSE TRUE END)
            ORDER BY o.id DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', result.id,
            'username', result.name,
            'nonce', result.nonce,
            'ts', result.ts,
            'type', result.op_name,
            'l1_tx', vsc_app.get_tx_hash_by_op(result.block_num, result.trx_in_block),
            'block_num', result.block_num,
            'payload', vsc_app.parse_l1_payload(result.op_name, result.body)
        )) FROM result
    ), '[]'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_ops_by_l1_tx(trx_id VARCHAR)
RETURNS jsonb AS $$
BEGIN
    RETURN COALESCE((
        WITH results AS (
            SELECT vo.id, va.name, vo.nonce, vo.op_type, vt.op_name, vo.block_num, vo.trx_in_block, vo.op_pos, vo.ts, vsc_app.parse_l1_payload(vt.op_name, ho.body::jsonb->'value') payload
            FROM vsc_app.l1_operations vo
            JOIN vsc_app.l1_operation_types vt ON
                vt.id=vo.op_type
            JOIN hafd.vsc_app_accounts va ON
                va.id=vo.user_id
            JOIN hive.operations_view ho ON
                ho.block_num = vo.block_num AND ho.trx_in_block = vo.trx_in_block AND ho.op_pos = vo.op_pos
            JOIN hive.transactions_view ht ON
                ho.block_num = ht.block_num AND ho.trx_in_block = ht.trx_in_block
            WHERE ht.trx_hash = decode(trx_id, 'hex')
            ORDER BY vo.id ASC
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', r.id,
            'username', r.name,
            'nonce', r.nonce,
            'type', r.op_name,
            'block_num', r.block_num,
            'l1_tx', trx_id,
            'op_pos', r.op_pos,
            'ts', r.ts,
            'payload', r.payload
        )) FROM results r
    ), '[]'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_latest_ops(count INTEGER = 100, bitmask_filter BIGINT = NULL, with_payload BOOLEAN = FALSE)
RETURNS jsonb AS $$
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;

    RETURN COALESCE((
        WITH result AS (
            SELECT o.id, a.name, o.nonce, o.block_num, o.trx_in_block, o.ts, ot.op_name, ho.body::jsonb->'value' body
            FROM vsc_app.l1_operations o
            JOIN vsc_app.l1_operation_types ot ON
                ot.id = o.op_type
            JOIN hafd.vsc_app_accounts a ON
                a.id = o.user_id
            JOIN hive.operations_view ho ON
                ho.id = o.op_id
            WHERE (SELECT CASE WHEN bitmask_filter IS NOT NULL THEN (ot.filterer & bitmask_filter) > 0 ELSE TRUE END)
            ORDER BY o.id DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', result.id,
            'username', result.name,
            'nonce', result.nonce,
            'type', result.op_name,
            'ts', result.ts,
            'l1_tx', vsc_app.get_tx_hash_by_op(result.block_num, result.trx_in_block),
            'block_num', result.block_num,
            'payload', (CASE WHEN with_payload THEN vsc_app.parse_l1_payload(result.op_name, result.body) ELSE NULL END)
        )) FROM result
    ), '[]'::jsonb);
END $$
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
            SELECT c.*, o.block_num, o.trx_in_block, o.ts, a.name AS creator
            FROM vsc_app.contracts c
            JOIN vsc_app.l1_operations o ON
                o.id=c.created_in_op
            JOIN hafd.vsc_app_accounts a ON
                a.id=o.user_id
            ORDER BY o.block_num DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'contract_id', contract_id,
            'created_in_op', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'created_in_l1_block', block_num,
            'created_at', ts,
            'creator', creator,
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
        'creator', a.name,
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
    JOIN hafd.vsc_app_accounts a ON
        a.id=o.user_id
    WHERE c.contract_id = ct_id), jsonb_build_object('error', 'contract not found'));
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.list_contract_calls_by_contract_id(contract_id VARCHAR, count INTEGER = 100, last_id BIGINT = NULL)
RETURNS jsonb
AS $function$
DECLARE
    _contract_id ALIAS FOR contract_id;
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;

    RETURN (
        WITH calls AS (
            SELECT 
                c.id,
                COALESCE(l2t.cid, (SELECT vsc_app.get_tx_hash_by_op(l1o.block_num, l1o.trx_in_block))) AS input,
                (SELECT CASE WHEN l2t.id IS NULL THEN 'hive' ELSE 'vsc' END) AS input_src,
                COALESCE(l2t.block_num, l1o.block_num) block_num,
                COALESCE(l2bp.ts, l1o.ts) AS ts,
                COALESCE((
                    SELECT jsonb_agg(k.did)
                    FROM vsc_app.l2_tx_multiauth ma
                    JOIN vsc_app.dids k ON
                        ma.did = k.id
                    WHERE ma.id = l2t.id
                ), (
                    SELECT jsonb_build_object(
                        'active', (ho.body::jsonb->'value')->'required_auths',
                        'posting', (ho.body::jsonb->'value')->'required_posting_auths'
                    )
                    FROM vsc_app.operations_view ho
                    WHERE ho.block_num = l1o.block_num AND ho.trx_in_block = l1o.trx_in_block AND ho.op_pos = l1o.op_pos
                )) AS signers,
                c.contract_action,
                c.io_gas,
                c.contract_output_tx_id AS output
            FROM vsc_app.contract_calls c
            LEFT JOIN vsc_app.l2_txs l2t ON
                c.id = l2t.details AND l2t.tx_type = 1
            LEFT JOIN vsc_app.l1_txs l1t ON
                c.id = l1t.details AND l1t.tx_type = 1
            LEFT JOIN vsc_app.l1_operations l1o ON
                l1t.id = l1o.id
            LEFT JOIN vsc_app.l2_blocks l2b ON
                l2t.block_num = l2b.id
            LEFT JOIN vsc_app.l1_operations l2bp ON
                l2b.proposed_in_op = l2bp.id
            WHERE c.contract_id=_contract_id AND c.id <= COALESCE(last_id, (SELECT c2.id FROM vsc_app.contract_calls c2 ORDER BY c2.id DESC LIMIT 1))
            ORDER BY c.id DESC
            LIMIT count
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id', c.id,
            'input', c.input,
            'input_src', c.input_src,
            'block_num', c.block_num,
            'ts', c.ts,
            'signers', c.signers,
            'contract_action', c.contract_action,
            'io_gas', c.io_gas,
            'output', c.output
        )), '[]'::jsonb)
        FROM calls c
    );
END $function$
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
                JOIN hafd.vsc_app_accounts a ON
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
CREATE OR REPLACE FUNCTION vsc_api.list_latest_deposits(count INTEGER = 100, last_id INTEGER = NULL)
RETURNS jsonb
AS $function$
DECLARE
    _count ALIAS FOR count;
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    RETURN (
        WITH deposits AS (
            SELECT c.id, o.block_num, o.trx_in_block, o.ts, c.amount, c.asset, COALESCE(d.did, 'hive:' || a.name) name
            FROM vsc_app.deposits c
            JOIN vsc_app.l1_operations o ON
                o.id = c.in_op
            LEFT JOIN vsc_app.dids d ON
                d.id = c.dest_did
            LEFT JOIN hafd.vsc_app_accounts a ON
                a.id = c.dest_acc
            WHERE (CASE WHEN last_id IS NOT NULL THEN c.id <= last_id ELSE TRUE END)
            ORDER BY c.id DESC
            LIMIT _count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', id,
            'ts', ts,
            'tx_hash', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'block_num', block_num,
            'to', name,
            'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset))
        )) FROM deposits
    );
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_deposits_by_address(address VARCHAR, count INTEGER = 100, last_nonce INTEGER = NULL)
RETURNS jsonb AS $$
DECLARE
    _count ALIAS FOR count;
BEGIN
    IF last_nonce IS NOT NULL AND last_nonce < 0 THEN
        RETURN jsonb_build_object(
            'error', 'last_nonce must be greater than or equal to 0 if not null'
        );
    ELSIF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;
    IF starts_with(address, 'hive:') THEN
        RETURN (
            WITH deposits AS (
                SELECT c.id, o.block_num, o.trx_in_block, o.ts, c.amount, c.asset, 'hive:' || a.name name, c.nonce_counter
                FROM vsc_app.deposits c
                JOIN vsc_app.l1_operations o ON
                    o.id = c.in_op
                JOIN hafd.vsc_app_accounts a ON
                    a.id = c.dest_acc
                WHERE a.name = REPLACE(address, 'hive:', '') AND (CASE WHEN last_nonce IS NOT NULL THEN c.nonce_counter <= last_nonce ELSE TRUE END)
                ORDER BY c.nonce_counter DESC
                LIMIT _count
            )
            SELECT jsonb_agg(jsonb_build_object(
                'id', id,
                'ts', ts,
                'tx_hash', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
                'block_num', block_num,
                'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset)),
                'nonce', nonce_counter
            )) FROM deposits
        );
    ELSIF starts_with(address, 'did:') THEN
         RETURN (
            WITH deposits AS (
                SELECT c.id, o.block_num, o.trx_in_block, o.ts, c.amount, c.asset, d.did name, c.nonce_counter
                FROM vsc_app.deposits c
                JOIN vsc_app.l1_operations o ON
                    o.id = c.in_op
                JOIN vsc_app.dids d ON
                    d.id = c.dest_did
                WHERE d.did = address AND (CASE WHEN last_nonce IS NOT NULL THEN c.nonce_counter <= last_nonce ELSE TRUE END)
                ORDER BY c.nonce_counter DESC
                LIMIT _count
            )
            SELECT jsonb_agg(jsonb_build_object(
                'id', id,
                'ts', ts,
                'tx_hash', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
                'block_num', block_num,
                'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset)),
                'nonce', nonce_counter
            )) FROM deposits
        );
    ELSE
        RETURN jsonb_build_object('error', 'invalid address');
    END IF;
END $$
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
            JOIN hafd.vsc_app_accounts a ON
                a.id=c.dest_acc
            WHERE c.id <= COALESCE(last_id, 2147483647)
            ORDER BY c.id DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', id,
            'ts', ts,
            'tx_hash', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'block_num', block_num,
            'to', name,
            'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset))
        )) FROM withdrawals
    );
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_withdrawal_requests_by_address(address VARCHAR, count INTEGER = 100, last_nonce INTEGER = NULL)
RETURNS jsonb AS $$
DECLARE
    _count ALIAS FOR count;
    _from_id INTEGER;
BEGIN
    IF last_nonce IS NOT NULL AND last_nonce < 0 THEN
        RETURN jsonb_build_object(
            'error', 'last_nonce must be greater than or equal to 0 if not null'
        );
    ELSIF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;

    -- get from id
    IF starts_with(address, 'hive:') THEN
        SELECT id INTO _from_id FROM hafd.vsc_app_accounts WHERE name = REPLACE(address, 'hive:', '');
        RETURN (
            WITH wdrq AS (
                SELECT w.id, encode(ht.trx_hash, 'hex') trx_hash, ha.name to_user, o.block_num, o.ts, w.amount, w.asset, w.memo, (CASE WHEN o.ts < NOW() - INTERVAL '1 day' AND w.status = 1 THEN 'failed' ELSE ws.name END) status, w.nonce_counter
                FROM vsc_app.l2_withdrawals w
                JOIN vsc_app.withdrawal_status ws ON
                    ws.id = w.status
                JOIN hafd.vsc_app_accounts ha ON
                    ha.id = w.to_id
                JOIN vsc_app.l1_txs t ON
                    t.details = w.id AND t.tx_type = 4
                JOIN vsc_app.l1_operations o ON
                    o.id = t.id
                JOIN hive.irreversible_transactions_view ht ON
                    ht.block_num = o.block_num AND ht.trx_in_block = o.trx_in_block
                WHERE w.from_acctype = 1 AND w.from_id = _from_id AND (CASE WHEN last_nonce IS NOT NULL THEN w.nonce_counter <= last_nonce ELSE TRUE END)
                ORDER BY w.nonce_counter DESC
                LIMIT _count
            )
            SELECT jsonb_agg(jsonb_build_object(
                'id', id,
                'ts', ts,
                'tx_hash', trx_hash,
                'block_num', block_num,
                'to', to_user,
                'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset)),
                'memo', memo,
                'status', status,
                'nonce', nonce_counter
            )) FROM wdrq
        );
    ELSIF starts_with(address, 'did:') THEN
        SELECT id INTO _from_id FROM vsc_app.dids WHERE did = address;
        RETURN (
            WITH wdrq AS (
                SELECT w.id, t.cid trx_hash, ha.name to_user, t.block_num, o.ts, w.amount, w.asset, w.memo, (CASE WHEN o.ts < NOW() - INTERVAL '1 day' AND w.status = 1 THEN 'failed' ELSE ws.name END) status, w.nonce_counter
                FROM vsc_app.l2_withdrawals w
                JOIN vsc_app.withdrawal_status ws ON
                    ws.id = w.status
                JOIN hafd.vsc_app_accounts ha ON
                    ha.id = w.to_id
                JOIN vsc_app.l2_txs t ON
                    t.details = w.id AND t.tx_type = 4
                JOIN vsc_app.l2_blocks b ON
                    b.id = t.block_num
                JOIN vsc_app.l1_operations o ON
                    o.id = b.proposed_in_op
                WHERE w.from_acctype = 2 AND w.from_id = _from_id AND (CASE WHEN last_nonce IS NOT NULL THEN w.nonce_counter <= last_nonce ELSE TRUE END)
                ORDER BY w.nonce_counter DESC
                LIMIT _count
            )
            SELECT jsonb_agg(jsonb_build_object(
                'id', id,
                'ts', ts,
                'tx_hash', trx_hash,
                'block_num', block_num,
                'to', to_user,
                'amount', ROUND(amount::decimal/1000,3) || ' ' || (SELECT vsc_app.asset_by_id(asset)),
                'memo', memo,
                'status', status,
                'nonce', nonce_counter
            )) FROM wdrq
        );
    ELSE
        RETURN jsonb_build_object('error', 'invalid address');
    END IF;
END $$
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
            SELECT e.epoch, o.block_num, o.trx_in_block, o.ts, a.name, e.data_cid, e.voted_weight, e.sig, e.bv
            FROM vsc_app.election_results e
            JOIN vsc_app.l1_operations o ON
                o.id = e.proposed_in_op
            JOIN hafd.vsc_app_accounts a ON
                a.id = e.proposer
            WHERE e.epoch <= COALESCE(last_epoch, 2147483647)
            ORDER BY e.epoch DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', epoch,
            'epoch', epoch,
            'block_num', block_num,
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(block_num, trx_in_block)),
            'ts', ts,
            'proposer', name,
            'data_cid', data_cid,
            'voted_weight', voted_weight,
            'eligible_weight', (SELECT SUM(weight) FROM vsc_app.get_members_at_block(block_num-1)),
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
                'consensus_did', consensus_did,
                'weight', weight
            ))
            FROM vsc_app.get_election_at_epoch(epoch)
        );
    ELSE
        RETURN (
            SELECT jsonb_agg(jsonb_build_object(
                'username', name,
                'weight', weight
            ))
            FROM vsc_app.get_election_at_epoch(epoch)
        );
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
                'consensus_did', consensus_did,
                'weight', weight
            ))
            FROM vsc_app.get_members_at_block(blk_num)
        );
    ELSE
        RETURN (
            SELECT jsonb_agg(jsonb_build_object(
                'username', name,
                'weight', weight
            ))
            FROM vsc_app.get_members_at_block(blk_num)
        );
    END IF;
END $function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_epoch(epoch_num INTEGER)
RETURNS jsonb
AS $function$
BEGIN
    RETURN (COALESCE((
        SELECT jsonb_build_object(
            'id', e.epoch,
            'epoch', e.epoch,
            'block_num', o.block_num,
            'l1_tx', (SELECT vsc_app.get_tx_hash_by_op(o.block_num, o.trx_in_block)),
            'ts', o.ts,
            'proposer', a.name,
            'data_cid', e.data_cid,
            'election', (SELECT vsc_api.get_election_at_epoch(epoch_num, FALSE)),
            'members_at_start', (SELECT vsc_api.get_members_at_block(o.block_num - (o.block_num % 7200), FALSE)),
            'voted_weight', voted_weight,
            'eligible_weight', (SELECT SUM(weight) FROM vsc_app.get_members_at_block(o.block_num-1)),
            'sig', encode(e.sig, 'hex'),
            'bv', encode(e.bv, 'hex')
        )
        FROM vsc_app.election_results e
        JOIN vsc_app.l1_operations o ON
            o.id = e.proposed_in_op
        JOIN hafd.vsc_app_accounts a ON
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
            SELECT bk.id, l1_op.block_num, l1_op.ts, bk.block_header_hash, a.name, bk.bv, bk.voted_weight
            FROM vsc_app.l2_blocks bk
            JOIN vsc_app.l1_operations l1_op ON
                bk.proposed_in_op = l1_op.id
            JOIN hafd.vsc_app_accounts a ON
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
            'txs', (SELECT vsc_app.get_l2_operation_count_in_block(b.id)),
            'voted_weight', b.voted_weight,
            'eligible_weight', (SELECT SUM(weight) FROM vsc_app.get_members_at_block(block_num-1)),
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
        JOIN vsc_app.l2_blocks b ON
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
        JOIN vsc_app.l2_blocks b ON
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
        JOIN vsc_app.l2_blocks b ON
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
    -- did: address search
    IF starts_with(_cid, 'did:') THEN
        SELECT id INTO _result_int FROM vsc_app.dids WHERE did = _cid;
        RETURN jsonb_build_object(
            'type', 'address',
            'result', (CASE WHEN _result_int IS NOT NULL THEN _cid ELSE NULL END)
        );
    END IF;

    -- Block search
    SELECT id INTO _result_int FROM vsc_app.l2_blocks WHERE block_hash = _cid OR block_header_hash = _cid;
    IF _result_int IS NOT NULL THEN
        RETURN jsonb_build_object(
            'type', 'block',
            'result', _result_int
        );
    END IF;

    -- Transaction search
    SELECT t.tx_type::INTEGER INTO _result_int FROM vsc_app.l2_txs t WHERE t.cid = _cid;
    IF _result_int IS NOT NULL THEN
        IF _result_int = 1 THEN
            RETURN jsonb_build_object(
                'type', 'call_contract',
                'result', _cid
            );
        ELSIF _result_int = 3 THEN
            RETURN jsonb_build_object(
                'type', 'transfer',
                'result', _cid
            );
        ELSIF _result_int = 4 THEN
            RETURN jsonb_build_object(
                'type', 'withdraw',
                'result', _cid
            );
        END IF;
    END IF;

    -- Contract output search
    SELECT id INTO _result_varchar FROM vsc_app.contract_outputs WHERE id = _cid;
    IF _result_varchar IS NOT NULL THEN
        RETURN jsonb_build_object(
            'type', 'contract_output',
            'result', _result_varchar
        );
    END IF;

    -- Event search
    SELECT e.cid INTO _result_varchar FROM vsc_app.events e WHERE e.cid = _cid;
    IF _result_varchar IS NOT NULL THEN
        RETURN jsonb_build_object(
            'type', 'event',
            'result', _result_varchar
        );
    END IF;

    -- Contract search
    SELECT contract_id INTO _result_varchar FROM vsc_app.contracts WHERE contract_id = _cid OR code = _cid;
    IF _result_varchar IS NOT NULL THEN
        RETURN jsonb_build_object(
            'type', 'contract',
            'result', _result_varchar
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