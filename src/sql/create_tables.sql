SET ROLE vsc_owner;
CREATE SCHEMA IF NOT EXISTS vsc_app;

CREATE TABLE IF NOT EXISTS vsc_app.l1_operation_types(
    id SERIAL PRIMARY KEY,
    op_name VARCHAR(25),
    filterer BIGINT GENERATED ALWAYS AS (2^(id-1)) STORED
);

CREATE TABLE IF NOT EXISTS vsc_app.l1_operations(
    id BIGSERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    nonce INTEGER NOT NULL,
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
    proposed_in_op BIGINT NOT NULL,
    block_hash VARCHAR(59) NOT NULL,
    proposer INTEGER NOT NULL,
    sig VARCHAR NOT NULL,
    bv VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.contracts(
    contract_id VARCHAR(68) PRIMARY KEY,
    created_in_op BIGINT NOT NULL,
    name VARCHAR,
    description VARCHAR,
    code VARCHAR(59) NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.witnesses(
    id INTEGER PRIMARY KEY, -- hive user id
    witness_id SERIAL, -- vsc witness id
    did VARCHAR NOT NULL,
    consensus_did VARCHAR,
    sk_posting VARCHAR(53),
    sk_active VARCHAR(53),
    sk_owner VARCHAR(53),
    enabled BOOLEAN DEFAULT FALSE,
    enabled_at BIGINT,
    disabled_at BIGINT,
    git_commit VARCHAR(40),
    last_block INTEGER,
    produced INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS vsc_app.election_results(
    id SERIAL PRIMARY KEY,
    epoch INTEGER NOT NULL,
    proposed_in_op BIGINT NOT NULL,
    proposer INTEGER NOT NULL,
    data_cid VARCHAR(59) NOT NULL,
    sig VARCHAR NOT NULL,
    bv VARCHAR NOT NULL,
    is_valid BOOLEAN
);

CREATE TABLE IF NOT EXISTS vsc_app.vsc_node_git(
    id INTEGER PRIMARY KEY,
    git_commit VARCHAR(40)
);

CREATE TABLE IF NOT EXISTS vsc_app.trusted_dids(
    did VARCHAR PRIMARY KEY,
    trusted BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS vsc_app.state(
    id SERIAL PRIMARY KEY,
    last_processed_block INTEGER NOT NULL DEFAULT 0,
    next_epoch_block INTEGER NOT NULL DEFAULT 0,
    db_version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS vsc_app.multisig_txrefs(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    ref_id VARCHAR(59) NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.deposits(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    contract_id VARCHAR(40)
);

CREATE TABLE IF NOT EXISTS vsc_app.withdrawals(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    contract_id VARCHAR(40)
);