SET ROLE vsc_owner;

DROP TYPE IF EXISTS vsc_mainnet.op_type CASCADE;
CREATE TYPE vsc_mainnet.op_type AS (
    id BIGINT,
    block_num INT,
    trx_in_block SMALLINT,
    op_pos INT,
    body TEXT
);

CREATE OR REPLACE FUNCTION vsc_mainnet.enum_op(IN _first_block INT, IN _last_block INT)
RETURNS SETOF vsc_mainnet.op_type
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
        FROM vsc_mainnet.operations_view
        WHERE block_num >= _first_block AND block_num <= _last_block AND (
            op_type_id=2 OR -- transfer
            (op_type_id=18 AND (body::jsonb)->'value'->>'id' LIKE 'vsc.%') OR -- custon_json
            op_type_id=10 OR -- account_update
            op_type_id=32 OR -- transfer_to_savings
            op_type_id=33 OR -- transfer_from_savings
            op_type_id=55 OR -- interest
            op_type_id=59 -- fill_transfer_from_savings
        )
        ORDER BY block_num, id;
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_mainnet.block_type CASCADE;
CREATE TYPE vsc_mainnet.block_type AS (
    num INTEGER,
    created_at TIMESTAMP
);

CREATE OR REPLACE FUNCTION vsc_mainnet.enum_block(IN _first_block INT, IN _last_block INT)
RETURNS SETOF vsc_mainnet.block_type
AS
$function$
BEGIN
    -- Fetch block headers
    RETURN QUERY
        SELECT
            num,
            created_at
        FROM vsc_mainnet.blocks_view
        WHERE num >= _first_block AND num <= _last_block
        ORDER BY num;
END
$function$
LANGUAGE plpgsql STABLE;

-- Get transaction hash from block_num and trx_in_block
CREATE OR REPLACE FUNCTION vsc_mainnet.get_tx_hash_by_op(_block_num INTEGER, _trx_in_block SMALLINT)
RETURNS TEXT
AS
$function$
BEGIN
    RETURN (
        SELECT encode(t.trx_hash::bytea, 'hex')
        FROM vsc_mainnet.transactions_view t
        WHERE t.block_num = _block_num AND t.trx_in_block = _trx_in_block
    );
END
$function$
LANGUAGE plpgsql STABLE;

-- Process transactions
CREATE OR REPLACE FUNCTION vsc_mainnet.process_operation(_username VARCHAR, _op_id BIGINT, _op_type INTEGER, _ts TIMESTAMP)
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
    SELECT id INTO _hive_user_id FROM hafd.vsc_mainnet_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;

    SELECT count INTO _nonce FROM vsc_mainnet.l1_users WHERE id=_hive_user_id;
    IF _nonce IS NOT NULL THEN
        UPDATE vsc_mainnet.l1_users SET
            count=count+1,
            last_op_ts=_ts
        WHERE id=_hive_user_id;
    ELSE
        INSERT INTO vsc_mainnet.l1_users(id, count, last_op_ts)
            VALUES(_hive_user_id, 1, _ts);
    END IF;

    SELECT o.block_num, o.trx_in_block, o.op_pos
        INTO _block_num, _trx_in_block, _op_pos
        FROM vsc_mainnet.operations_view o
        WHERE o.id = _op_id;

    INSERT INTO vsc_mainnet.l1_operations(user_id, nonce, op_id, block_num, trx_in_block, op_pos, op_type, ts)
        VALUES(_hive_user_id, COALESCE(_nonce, 0), _op_id, _block_num, _trx_in_block, _op_pos, _op_type, _ts)
        RETURNING id INTO _vsc_op_id;

    RETURN _vsc_op_id;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_mainnet.update_witness(
    _username VARCHAR,
    _consensus_did VARCHAR,
    _peer_id VARCHAR,
    _peer_addrs jsonb,
    _version_id VARCHAR,
    _git_commit VARCHAR,
    _protocol_version SMALLINT,
    _gateway_key VARCHAR,
    _enabled BOOLEAN,
    _op_id BIGINT
)
RETURNS void AS $$
DECLARE
    _hive_user_id INTEGER = NULL;
BEGIN
    SELECT id INTO _hive_user_id FROM hafd.vsc_mainnet_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;

    INSERT INTO vsc_mainnet.witnesses (id, consensus_did, peer_id, peer_addrs, version_id, git_commit, protocol_version, gateway_key, enabled, last_update, first_seen)
        VALUES(_hive_user_id, _consensus_did, _peer_id, _peer_addrs, _version_id, _git_commit, _protocol_version, _gateway_key, _enabled, _op_id, _op_id)
        ON CONFLICT(id) DO UPDATE SET
            consensus_did = _consensus_did,
            peer_id = _peer_id,
            peer_addrs = _peer_addrs,
            version_id = _version_id,
            git_commit = _git_commit,
            protocol_version = _protocol_version,
            gateway_key = _gateway_key,
            enabled = _enabled,
            last_update = _op_id;
END
$function$
LANGUAGE plpgsql VOLATILE;

-- Helper function for parsing L1 payload mainly for use by vsc_mainnet_api schema
CREATE OR REPLACE FUNCTION vsc_mainnet.parse_l1_payload(_op_name VARCHAR, _op_body jsonb)
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
    ELSIF _op_name = 'rotate_multisig' OR _op_name = 'l1_transfer' OR op_name = 'transfer_to_savings' OR op_name = 'transfer_from_savings' OR op_name = 'interest' OR op_name = 'fill_transfer_from_savings' THEN
        _payload := _op_body;
    ELSE
        _payload := _op_body->>'json';
    END IF;

    RETURN _payload::jsonb;
END $$
LANGUAGE plpgsql STABLE;
