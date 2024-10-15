SET ROLE vsc_owner;

DROP TYPE IF EXISTS vsc_app.op_type CASCADE;
CREATE TYPE vsc_app.op_type AS (
    id BIGINT,
    block_num INT,
    trx_in_block SMALLINT,
    op_pos INT,
    body TEXT
);

CREATE OR REPLACE FUNCTION vsc_app.enum_op(IN _first_block INT, IN _last_block INT)
RETURNS SETOF vsc_app.op_type
AS
$function$
BEGIN
    -- Fetch transfer, custom_json and account_update operations
    RETURN QUERY
        SELECT
            id,
            block_num,
            trx_in_block,
            op_pos,
            body::TEXT
        FROM vsc_app.operations_view
        WHERE block_num >= _first_block AND block_num <= _last_block AND
            (op_type_id=2 OR (op_type_id=18 AND (body::jsonb)->'value'->>'id' LIKE 'vsc.%') OR op_type_id=10)
        ORDER BY block_num, id;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_app.block_type CASCADE;
CREATE TYPE vsc_app.block_type AS (
    num INTEGER,
    created_at TIMESTAMP
);

CREATE OR REPLACE FUNCTION vsc_app.enum_block(IN _first_block INT, IN _last_block INT)
RETURNS SETOF vsc_app.block_type
AS
$function$
BEGIN
    -- Fetch block headers
    RETURN QUERY
        SELECT
            num,
            created_at
        FROM vsc_app.blocks_view
        WHERE num >= _first_block AND num <= _last_block
        ORDER BY num;
END
$function$
LANGUAGE plpgsql STABLE;

-- Get transaction hash from block_num and trx_in_block
CREATE OR REPLACE FUNCTION vsc_app.get_tx_hash_by_op(_block_num INTEGER, _trx_in_block SMALLINT)
RETURNS TEXT
AS
$function$
BEGIN
    RETURN (
        SELECT encode(t.trx_hash::bytea, 'hex')
        FROM vsc_app.transactions_view t
        WHERE t.block_num = _block_num AND t.trx_in_block = _trx_in_block
    );
END
$function$
LANGUAGE plpgsql STABLE;

-- SMALLINT to ASSET string mapping
CREATE OR REPLACE FUNCTION vsc_app.asset_by_id(id SMALLINT = -1)
RETURNS VARCHAR
AS
$function$
BEGIN
    IF id = 0 THEN
        RETURN 'HIVE';
    ELSIF id = 1 THEN
        RETURN 'HBD';
    ELSE
        RETURN '';
    END IF;
END
$function$
LANGUAGE plpgsql IMMUTABLE;

-- ASSET to SMALLINT string mapping
CREATE OR REPLACE FUNCTION vsc_app.get_asset_id(asset VARCHAR)
RETURNS SMALLINT AS $function$
BEGIN
    IF asset = 'HIVE' THEN
        RETURN 0::SMALLINT;
    ELSIF asset = 'HBD' THEN
        RETURN 1::SMALLINT;
    ELSE
        RETURN -1;
    END IF;
END $function$
LANGUAGE plpgsql IMMUTABLE;

-- L2 Account ID to string
CREATE OR REPLACE FUNCTION vsc_app.l2_account_id_to_str(_id INTEGER, _acctype SMALLINT)
RETURNS VARCHAR
AS $function$
BEGIN
    IF _acctype = 1 THEN
        RETURN 'hive:' || (SELECT name FROM hive.vsc_app_accounts WHERE id=_id);
    ELSIF _acctype = 2 THEN
        RETURN (SELECT did from vsc_app.dids WHERE id=_id);
    ELSE
        RETURN '';
    END IF;
END $function$
LANGUAGE plpgsql STABLE;

-- Process transactions
CREATE OR REPLACE FUNCTION vsc_app.process_operation(_username VARCHAR, _op_id BIGINT, _op_type INTEGER, _ts TIMESTAMP)
RETURNS BIGINT
AS
$function$
DECLARE
    _hive_user_id INTEGER = NULL;
    _vsc_op_id BIGINT = NULL;
    _nonce INTEGER = NULL;

    -- To replace op_id joins in queries
    _block_num INTEGER;
    _trx_in_block SMALLINT;
    _op_pos INTEGER;
BEGIN
    SELECT id INTO _hive_user_id FROM hive.vsc_app_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;

    SELECT count INTO _nonce FROM vsc_app.l1_users WHERE id=_hive_user_id;
    IF _nonce IS NOT NULL THEN
        UPDATE vsc_app.l1_users SET
            count=count+1,
            last_op_ts=_ts
        WHERE id=_hive_user_id;
    ELSE
        INSERT INTO vsc_app.l1_users(id, count, last_op_ts)
            VALUES(_hive_user_id, 1, _ts);
    END IF;

    SELECT o.block_num, o.trx_in_block, o.op_pos
        INTO _block_num, _trx_in_block, _op_pos
        FROM vsc_app.operations_view o
        WHERE o.id = _op_id;

    INSERT INTO vsc_app.l1_operations(user_id, nonce, op_id, block_num, trx_in_block, op_pos, op_type, ts)
        VALUES(_hive_user_id, COALESCE(_nonce, 0), _op_id, _block_num, _trx_in_block, _op_pos, _op_type, _ts)
        RETURNING id INTO _vsc_op_id;

    RETURN _vsc_op_id;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.update_witness(_username VARCHAR,
    _did VARCHAR,
    _consensus_did VARCHAR,
    _sk_posting VARCHAR,
    _sk_active VARCHAR,
    _sk_owner VARCHAR,
    _enabled BOOLEAN,
    _op_id BIGINT,
    _git_commit VARCHAR = NULL
)
RETURNS void
AS
$function$
DECLARE
    _hive_user_id INTEGER = NULL;
    _current_git_commit VARCHAR = NULL;

    -- For state archive
    _latest_toggle_archive INTEGER = NULL;
    _latest_keyauth_archive INTEGER = NULL;
    _current_did VARCHAR = NULL;
    _current_consensus_did VARCHAR = NULL;
    _current_sk_posting VARCHAR = NULL;
    _current_sk_active VARCHAR = NULL;
    _current_sk_owner VARCHAR = NULL;
    _current_enabled BOOLEAN = NULL;
BEGIN
    SELECT id INTO _hive_user_id FROM hive.vsc_app_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;

    SELECT git_commit, did, consensus_did, sk_posting, sk_active, sk_owner, enabled, last_toggle_archive, last_keyauth_archive
        INTO _current_git_commit, _current_did, _current_consensus_did, _current_sk_posting, _current_sk_active, _current_sk_owner, _current_enabled, _latest_toggle_archive, _latest_keyauth_archive
        FROM vsc_app.witnesses
        WHERE id=_hive_user_id;

    IF _current_git_commit IS NULL THEN
        IF _enabled IS TRUE THEN
            INSERT INTO vsc_app.keyauths_archive(user_id, op_id, last_updated, node_did, consensus_did, sk_posting, sk_active, sk_owner)
                VALUES (_hive_user_id, _op_id, _op_id, _did, _consensus_did, _sk_posting, _sk_active, _sk_owner)
                RETURNING id INTO _latest_keyauth_archive;
            INSERT INTO vsc_app.witness_toggle_archive(witness_id, op_id, last_updated, enabled)
                VALUES (_hive_user_id, _op_id, _op_id, TRUE)
                RETURNING id INTO _latest_toggle_archive;
            INSERT INTO vsc_app.witnesses(id, did, consensus_did, sk_posting, sk_active, sk_owner, enabled, enabled_at, first_seen, git_commit, last_toggle_archive, last_keyauth_archive)
                VALUES (_hive_user_id, _did, _consensus_did, _sk_posting, _sk_active, _sk_owner, TRUE, _op_id, _op_id, _git_commit, _latest_toggle_archive, _latest_keyauth_archive);
        ELSE
            RETURN;
        END IF;
    ELSE
        IF ((_did = _current_did) IS NOT TRUE)
            OR ((_consensus_did = _current_consensus_did) IS NOT TRUE)
            OR ((_sk_posting = _current_sk_posting) IS NOT TRUE)
            OR ((_sk_active = _current_sk_active) IS NOT TRUE)
            OR ((_sk_owner = _current_sk_owner) IS NOT TRUE) THEN
            INSERT INTO vsc_app.keyauths_archive(user_id, op_id, last_updated, node_did, consensus_did, sk_posting, sk_active, sk_owner)
                VALUES (_hive_user_id, _op_id, _op_id, _did, _consensus_did, _sk_posting, _sk_active, _sk_owner)
                RETURNING id INTO _latest_keyauth_archive;
        ELSE
            UPDATE vsc_app.keyauths_archive SET
                last_updated = _op_id
            WHERE id = _latest_keyauth_archive;
        END IF;
        IF _enabled != _current_enabled THEN
            INSERT INTO vsc_app.witness_toggle_archive(witness_id, op_id, last_updated, enabled)
                VALUES (_hive_user_id, _op_id, _op_id, _enabled)
                RETURNING id INTO _latest_toggle_archive;
        ELSE
            UPDATE vsc_app.witness_toggle_archive SET
                last_updated = _op_id
            WHERE id = _latest_toggle_archive;
        END IF;
        IF _enabled IS FALSE THEN
            UPDATE vsc_app.witnesses SET
                enabled = FALSE,
                did = _did,
                consensus_did = _consensus_did,
                sk_posting = _sk_posting,
                sk_active = _sk_active,
                sk_owner = _sk_owner,
                disabled_at = _op_id,
                git_commit = COALESCE(_git_commit, _current_git_commit),
                last_toggle_archive = _latest_toggle_archive,
                last_keyauth_archive = _latest_keyauth_archive
            WHERE id = _hive_user_id;
        ELSE
            UPDATE vsc_app.witnesses SET
                enabled = TRUE,
                did = _did,
                consensus_did = _consensus_did,
                sk_posting = _sk_posting,
                sk_active = _sk_active,
                sk_owner = _sk_owner,
                enabled_at = _op_id,
                git_commit = COALESCE(_git_commit, _current_git_commit),
                last_toggle_archive = _latest_toggle_archive,
                last_keyauth_archive = _latest_keyauth_archive
            WHERE id = _hive_user_id;
        END IF;
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_multisig_txref(
    _in_op BIGINT,
    _txref VARCHAR
)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.multisig_txrefs(in_op, ref_id)
        VALUES(_in_op, _txref);
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_deposit(
    _in_op BIGINT,
    _amount INTEGER,
    _asset SMALLINT,
    _dest VARCHAR,
    _dest_type VARCHAR
)
RETURNS void
AS
$function$
DECLARE
    _dest_id INTEGER = NULL;
BEGIN
    IF _dest_type = 'did' THEN
        SELECT id INTO _dest_id FROM vsc_app.dids WHERE did=_dest;
        IF _dest_id IS NULL THEN
            INSERT INTO vsc_app.dids(did) VALUES(_dest) RETURNING id INTO _dest_id;
        END IF;
        INSERT INTO vsc_app.deposits_to_did(in_op, amount, asset, dest_did)
            VALUES(_in_op, _amount, _asset, _dest_id);
    ELSIF _dest_type = 'hive' THEN
        SELECT id INTO _dest_id FROM hive.vsc_app_accounts WHERE name=_dest;
        IF _dest_id IS NULL THEN
            RAISE EXCEPTION 'hive username does not exist';
        END IF;
        INSERT INTO vsc_app.deposits_to_hive(in_op, amount, asset, dest_acc)
            VALUES(_in_op, _amount, _asset, _dest_id);
    ELSE
        RAISE EXCEPTION '_dest_type must be did or hive';
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_withdrawal_request(
    _in_op BIGINT,
    _amount INTEGER,
    _amount2 INTEGER,
    _asset SMALLINT,
    _dest VARCHAR
)
RETURNS void
AS
$function$
DECLARE
    _dest_id INTEGER = NULL;
BEGIN
    SELECT id INTO _dest_id FROM hive.vsc_app_accounts WHERE name=_dest;
    IF _dest_id IS NULL THEN
        RAISE EXCEPTION 'hive username does not exist';
    END IF;

    INSERT INTO vsc_app.withdrawal_request(in_op, amount, amount2, asset, dest_acc)
        VALUES(_in_op, _amount, _amount2, _asset, _dest_id);
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_withdrawal(
    _in_op BIGINT,
    _amount INTEGER,
    _asset SMALLINT,
    _dest VARCHAR
)
RETURNS void
AS
$function$
DECLARE
    _dest_id INTEGER = NULL;
BEGIN
    SELECT id INTO _dest_id FROM hive.vsc_app_accounts WHERE name=_dest;
    IF _dest_id IS NULL THEN
        RAISE EXCEPTION 'hive username does not exist';
    END IF;
    INSERT INTO vsc_app.withdrawals(in_op, amount, asset, dest_acc)
        VALUES(_in_op, _amount, _asset, _dest_id);
END
$function$
LANGUAGE plpgsql VOLATILE;

-- Set latest git commit hash for vsc-node repo
CREATE OR REPLACE FUNCTION vsc_app.set_vsc_node_git_hash(_commit_hash VARCHAR)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.vsc_node_git(id, git_commit)
        VALUES(1, _commit_hash)
        ON CONFLICT(id) DO UPDATE
        SET git_commit=_commit_hash;
END
$function$
LANGUAGE plpgsql VOLATILE;

-- Helper function for parsing L1 payload mainly for use by vsc_api schema
CREATE OR REPLACE FUNCTION vsc_app.parse_l1_payload(_op_name VARCHAR, _op_body jsonb)
RETURNS jsonb AS $$
DECLARE
    _payload TEXT;
    _payload2 jsonb;
BEGIN
    IF _op_name = 'announce_node' THEN
        _payload := '{}';
        _payload2 := (_op_body->>'json_metadata')::jsonb;
        IF _payload2 ? 'vsc_node' IS TRUE THEN
            _payload := jsonb_set(_payload::jsonb, '{vsc_node}', _payload2->'vsc_node');
        END IF;
        IF _payload2 ? 'did_keys' IS TRUE THEN
            _payload := jsonb_set(_payload::jsonb, '{did_keys}', _payload2->'did_keys');
        END IF;
    ELSIF _op_name = 'rotate_multisig' OR _op_name = 'deposit' OR _op_name = 'withdrawal' OR _op_name = 'withdrawal_request' THEN
        _payload := _op_body;
    ELSE
        _payload := _op_body->>'json';
    END IF;

    RETURN _payload::jsonb;
END $$
LANGUAGE plpgsql STABLE;

-- Get total L2 block operations count
CREATE OR REPLACE FUNCTION vsc_app.get_l2_operation_count_in_block(_block_num INTEGER)
RETURNS INTEGER
AS $function$
BEGIN
    RETURN (SELECT COUNT(*) FROM vsc_app.l2_txs t WHERE t.block_num = _block_num)+(SELECT COUNT(*) FROM vsc_app.contract_outputs co WHERE co.block_num = _block_num)+(SELECT COUNT(*) FROM vsc_app.events e WHERE e.block_num = _block_num)+(SELECT COUNT(*) FROM vsc_app.anchor_refs ar WHERE ar.block_num = _block_num);
END $function$
LANGUAGE plpgsql STABLE;

-- Get events in l2 tx
CREATE OR REPLACE FUNCTION vsc_app.get_events_in_tx_by_id(id INTEGER)
RETURNS jsonb AS $$
BEGIN
    RETURN COALESCE((
        WITH events AS (
            SELECT te2.evt_type t, vsc_app.asset_by_id(te2.token) tk, te2.amount amt, te2.memo, te2.owner_name owner
            FROM vsc_app.l2_tx_events te2
            WHERE te2.l2_tx_id = id
            ORDER BY te2.evt_pos
        )
        SELECT jsonb_agg(jsonb_build_object(
            't', t,
            'tk', tk,
            'amt', amt,
            'memo', memo,
            'owner', owner
        )) FROM events
    ), '[]'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

-- Get all event items in event by id
CREATE OR REPLACE FUNCTION vsc_app.get_event_details(_id INTEGER)
RETURNs jsonb AS $$
BEGIN
    RETURN (
        WITH txs AS (
            SELECT t.cid, ot.op_name, vsc_app.get_events_in_tx_by_id(t.id) evts
            FROM vsc_app.l2_tx_events te
            JOIN vsc_app.l2_txs t ON
                t.id = te.l2_tx_id
            JOIN vsc_app.l2_operation_types ot ON
                ot.id = t.tx_type
            WHERE te.event_id = _id
            GROUP BY t.id
        )
        SELECT jsonb_agg(jsonb_build_object(
            'tx_id', cid,
            'tx_type', op_name,
            'events', evts
        )) FROM txs
    );
END $$
LANGUAGE plpgsql STABLE;

-- Flat event array
CREATE OR REPLACE FUNCTION vsc_app.get_event_details2(_id INTEGER)
RETURNs jsonb AS $$
BEGIN
    RETURN (
        WITH events AS (
            SELECT t.cid, ot.op_name, te.evt_type, vsc_app.asset_by_id(te.token) token, te.amount, te.memo, te.owner_name
            FROM vsc_app.l2_tx_events te
            JOIN vsc_app.l2_txs t ON
                t.id = te.l2_tx_id
            JOIN vsc_app.l2_operation_types ot ON
                ot.id = t.tx_type
            WHERE te.event_id = _id
            ORDER BY te.tx_pos ASC, te.evt_pos ASC
        )
        SELECT jsonb_agg(jsonb_build_object(
            'tx_id', cid,
            'tx_type', op_name,
            'type', evt_type,
            'token', token,
            'amount', amount,
            'memo', memo,
            'owner', owner_name
        )) FROM events
    );
END $$
LANGUAGE plpgsql STABLE;
