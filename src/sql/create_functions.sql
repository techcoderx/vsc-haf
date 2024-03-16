SET ROLE vsc_owner;

DROP TYPE IF EXISTS vsc_app.op_type CASCADE;
CREATE TYPE vsc_app.op_type AS (
    id BIGINT,
    block_num INT,
    trx_in_block SMALLINT,
    op_pos INT,
    timestamp TIMESTAMP,
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
            timestamp,
            body::TEXT
        FROM hive.vsc_app_operations_view
        WHERE block_num >= _first_block AND block_num <= _last_block AND
            (op_type_id=2 OR op_type_id=18 OR op_type_id=10)
        ORDER BY block_num, id;
END
$function$
LANGUAGE plpgsql STABLE;

-- Get transaction_id from operation id
DROP TYPE IF EXISTS vsc_app.l1_tx_type CASCADE;
CREATE TYPE vsc_app.l1_tx_type AS (
    trx_hash TEXT,
    block_num INTEGER,
    created_at TIMESTAMP
);

CREATE OR REPLACE FUNCTION vsc_app.helper_get_tx_by_op_id(_op_id BIGINT)
RETURNS vsc_app.l1_tx_type
AS
$function$
DECLARE
    result vsc_app.l1_tx_type;
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

CREATE OR REPLACE FUNCTION vsc_app.get_tx_hash_by_op(_block_num INTEGER, _trx_in_block SMALLINT)
RETURNS TEXT
AS
$function$
BEGIN
    RETURN (
        SELECT encode(t.trx_hash::bytea, 'hex')
        FROM hive.vsc_app_transactions_view t
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

-- Process transactions
CREATE OR REPLACE FUNCTION vsc_app.process_operation(_username VARCHAR, _op_id BIGINT, _op_type INTEGER, _ts TIMESTAMP)
RETURNS BIGINT
AS
$function$
DECLARE
    _hive_user_id INTEGER = NULL;
    _vsc_op_id BIGINT = NULL;
    _nonce INTEGER = NULL;
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

    INSERT INTO vsc_app.l1_operations(user_id, nonce, op_id, op_type, ts)
        VALUES(_hive_user_id, COALESCE(_nonce, 0), _op_id, _op_type, _ts)
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
    _enabled_at INTEGER = NULL;
    _disabled_at INTEGER = NULL;
    _current_git_commit VARCHAR = NULL;
BEGIN
    SELECT id INTO _hive_user_id FROM hive.vsc_app_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;

    SELECT git_commit INTO _current_git_commit FROM vsc_app.witnesses WHERE id=_hive_user_id;

    IF _current_git_commit IS NULL THEN
        IF _enabled IS TRUE THEN
            INSERT INTO vsc_app.witnesses(id, did, consensus_did, sk_posting, sk_active, sk_owner, enabled, enabled_at, git_commit)
                VALUES (_hive_user_id, _did, _consensus_did, _sk_posting, _sk_active, _sk_owner, TRUE, _op_id, _git_commit);
        ELSE
            RETURN;
        END IF;
    ELSE
        IF _enabled IS FALSE THEN
            UPDATE vsc_app.witnesses SET
                enabled = FALSE,
                did = _did,
                consensus_did = _consensus_did,
                sk_posting = _sk_posting,
                sk_active = _sk_active,
                sk_owner = _sk_owner,
                disabled_at = _op_id,
                git_commit = COALESCE(_git_commit, _current_git_commit)
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
                git_commit = COALESCE(_git_commit, _current_git_commit)
            WHERE id = _hive_user_id;
        END IF;
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_multisig_rotation(_in_op BIGINT)
RETURNS void
AS
$function$
DECLARE
    _payload jsonb;
    _k jsonb;
    _pub_keys_str TEXT[] DEFAULT '{}';
    _members TEXT[] DEFAULT '{}';
    _epoch INTEGER = NULL;
BEGIN
    SELECT ho.body->'value'
        INTO _payload
        FROM hive.operations_view ho
        WHERE ho.id = (SELECT o.op_id FROM vsc_app.l1_operations o WHERE o.id=_in_op);
    FOR _k IN SELECT jsonb_array_elements((_payload->'owner')->'key_auths')
    LOOP
        SELECT ARRAY_APPEND(_pub_keys_str, _k->>0) INTO _pub_keys_str;
    END LOOP;
    SELECT ARRAY(
		SELECT a.name
			FROM vsc_test.witnesses w
			JOIN hive.vsc_app_accounts a ON
				a.id = w.id
			WHERE sk_owner = ANY(_pub_keys_str)
	) INTO _members;
    IF (SELECT jsonb_typeof((_payload->>'json_metadata')::jsonb->'epoch')) = 'number' THEN
        _epoch := ((_payload->>'json_metadata')::jsonb->'epoch')::INTEGER;
    END IF;
    INSERT INTO vsc_app.multisig_history(rotated_at, epoch, members)
        VALUES(_in_op, _epoch, _members);
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.process_election_result(_proposed_in_op BIGINT, _proposer VARCHAR, _epoch INTEGER, _data_cid VARCHAR, _sig VARCHAR, _bv VARCHAR)
RETURNS void
AS
$function$
DECLARE
    _acc_id INTEGER;
BEGIN
    SELECT id INTO _acc_id FROM hive.vsc_app_accounts WHERE name=_proposer;
    INSERT INTO vsc_app.election_results(epoch, proposed_in_op, proposer, data_cid, sig, bv)
        VALUES(_epoch, _proposed_in_op, _acc_id, _data_cid, _sig, _bv);
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_block(_proposed_in_op BIGINT, _block_hash VARCHAR, _proposer VARCHAR, _sig VARCHAR, _bv VARCHAR)
RETURNS void
AS
$function$
DECLARE
    _acc_id INTEGER;
    _new_block_id INTEGER;
BEGIN
    SELECT id INTO _acc_id FROM hive.vsc_app_accounts WHERE name=_proposer;
    INSERT INTO vsc_app.blocks(proposed_in_op, block_hash, proposer, sig, bv)
        VALUES(_proposed_in_op, _block_hash, _acc_id, _sig, _bv)
        RETURNING id INTO _new_block_id;
    
    IF EXISTS (SELECT 1 FROM vsc_app.witnesses w WHERE w.id=_acc_id) THEN
        UPDATE vsc_app.witnesses SET
            last_block=_new_block_id,
            produced=produced+1
        WHERE id=_acc_id;
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_contract(
    _created_in_op BIGINT,
    _contract_id VARCHAR,
    _contract_name VARCHAR,
    _contract_description VARCHAR,
    _code_hash VARCHAR)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.contracts(contract_id, created_in_op, name, description, code)
        VALUES(_contract_id, _created_in_op, _contract_name, _contract_description, _code_hash);
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
    _contract_id VARCHAR
)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.deposits(in_op, amount, asset, contract_id)
        VALUES(_in_op, _amount, _asset, _contract_id);
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_withdrawal(
    _in_op BIGINT,
    _amount INTEGER,
    _asset SMALLINT,
    _contract_id VARCHAR
)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.withdrawals(in_op, amount, asset, contract_id)
        VALUES(_in_op, _amount, _asset, _contract_id);
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
CREATE OR REPLACE FUNCTION vsc_app.parse_l1_payload(_op_name VARCHAR, _op_body TEXT)
RETURNS jsonb
AS
$function$
DECLARE
    _payload TEXT;
    _payload2 jsonb;
BEGIN
    IF _op_name = 'announce_node' THEN
        _payload := '{}';
        _payload2 := (_op_body::jsonb->>'json_metadata')::jsonb;
        IF _payload2 ? 'vsc_node' IS TRUE THEN
            _payload := jsonb_set(_payload::jsonb, '{vsc_node}', _payload2->'vsc_node');
        END IF;
        IF _payload2 ? 'did_keys' IS TRUE THEN
            _payload := jsonb_set(_payload::jsonb, '{did_keys}', _payload2->'did_keys');
        END IF;
    ELSIF _op_name = 'deposit' OR _op_name = 'withdrawal' THEN
        _payload := _op_body::jsonb;
        _payload := jsonb_set(_payload::jsonb, '{memo}', (_op_body::jsonb->>'memo')::jsonb);
    ELSE
        _payload := _op_body::jsonb->>'json';
    END IF;

    RETURN _payload::jsonb;
END
$function$
LANGUAGE plpgsql STABLE;