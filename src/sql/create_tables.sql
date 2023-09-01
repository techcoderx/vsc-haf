CREATE TABLE IF NOT EXISTS vsc_app.l1_operation_types(
    id SERIAL PRIMARY KEY,
    op_name VARCHAR(20),
    filterer BIGINT GENERATED ALWAYS AS (2^(id-1)) STORED
);

CREATE TABLE IF NOT EXISTS vsc_app.l1_operations(
    id BIGSERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    nonce BIGINT NOT NULL,
    op_id BIGINT NOT NULL,
    op_type INTEGER NOT NULL,
    ts TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.l1_users(
    id INTEGER PRIMARY KEY,
    count BIGINT DEFAULT 0,
    last_op_ts TIMESTAMP
);

CREATE TABLE IF NOT EXISTS vsc_app.blocks(
    id SERIAL PRIMARY KEY,
    announced_in_op BIGINT NOT NULL,
    block_hash VARCHAR(59) NOT NULL,
    announcer INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.contracts(
    id SERIAL PRIMARY KEY,
    created_in_op BIGINT NOT NULL,
    -- contract_id VARCHAR NOT NULL, -- this should be PK
    name VARCHAR NOT NULL,
    manifest_id VARCHAR NOT NULL,
    code VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.witnesses(
    id INTEGER PRIMARY KEY, -- hive user id
    witness_id SERIAL, -- vsc witness id
    did VARCHAR NOT NULL,
    enabled BOOLEAN DEFAULT FALSE,
    enabled_at BIGINT,
    disabled_at BIGINT,
    last_block INTEGER,
    produced INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS vsc_app.contract_commitments(
    contract_id VARCHAR NOT NULL,
    node_identity VARCHAR NOT NULL,
    is_active BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (contract_id, node_identity)
);

CREATE TABLE IF NOT EXISTS vsc_app.trusted_dids(
    did VARCHAR PRIMARY KEY,
    trusted BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS vsc_app.state(
    id SERIAL PRIMARY KEY,
    last_processed_block INTEGER NOT NULL DEFAULT 0,
    db_version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS vsc_app.multisig_txrefs(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    ref_id VARCHAR(59) NOT NULL
);