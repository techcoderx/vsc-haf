DROP TYPE IF EXISTS vsc_app.op_type CASCADE;
CREATE TYPE vsc_app.op_type AS (
    id BIGINT,
    block_num INT,
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
            body::TEXT
        FROM hive.vsc_app_operations_view
        WHERE block_num >= _first_block AND block_num <= _last_block AND
            (op_type_id=2 OR op_type_id=18 OR op_type_id=10)
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
        FROM hive.vsc_app_blocks_view
        WHERE num >= _first_block AND num <= _last_block
        ORDER BY num;
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

CREATE OR REPLACE FUNCTION vsc_app.update_witness(_username VARCHAR, _did VARCHAR, _enabled BOOLEAN, _op_id BIGINT, _git_commit VARCHAR = NULL)
RETURNS void
AS
$function$
DECLARE
    _hive_user_id INTEGER = NULL;
    _enabled_at INTEGER = NULL;
    _disabled_at INTEGER = NULL;
    _witness_exists BOOLEAN = NULL;
    _current_git_commit VARCHAR = NULL;
BEGIN
    SELECT id INTO _hive_user_id FROM hive.vsc_app_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;

    SELECT EXISTS INTO _witness_exists(
        SELECT git_commit INTO _current_git_commit FROM vsc_app.witnesses WHERE id=_hive_user_id
    );

    IF _witness_exists IS FALSE THEN
        IF _enabled IS TRUE THEN
            INSERT INTO vsc_app.witnesses(id, did, enabled, enabled_at, git_commit)
                VALUES (_hive_user_id, _did, TRUE, _op_id, COALESCE(_git_commit, _current_git_commit));
        ELSE
            RETURN;
        END IF;
    ELSE
        IF _enabled IS FALSE THEN
            UPDATE vsc_app.witnesses SET
                enabled = FALSE,
                did = _did,
                disabled_at = _op_id,
                git_commit = COALESCE(_git_commit, _current_git_commit)
            WHERE id = _hive_user_id;
        ELSE
            UPDATE vsc_app.witnesses SET
                enabled = TRUE,
                did = _did,
                enabled_at = _op_id,
                git_commit = COALESCE(_git_commit, _current_git_commit)
            WHERE id = _hive_user_id;
        END IF;
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_block(_announced_in_op BIGINT, _block_hash VARCHAR, _announcer VARCHAR)
RETURNS void
AS
$function$
DECLARE
    _acc_id INTEGER;
    _new_block_id INTEGER;
BEGIN
    SELECT id INTO _acc_id FROM hive.vsc_app_accounts WHERE name=_announcer;
    INSERT INTO vsc_app.blocks(announced_in_op, block_hash, announcer)
        VALUES(_announced_in_op, _block_hash, _acc_id)
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
    _contract_name VARCHAR,
    _manifest_id VARCHAR,
    _code_hash VARCHAR)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.contracts(created_in_op, name, manifest_id, code)
        VALUES(_created_in_op, _contract_name, _manifest_id, _code_hash);
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.update_contract_commitment(
    _contract_id VARCHAR,
    _node_identity VARCHAR,
    _is_active BOOLEAN
)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.contract_commitments(contract_id, node_identity, is_active)
        VALUES(_contract_id, _node_identity, _is_active)
        ON CONFLICT (contract_id, node_identity) DO UPDATE
        SET is_active=_is_active;
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