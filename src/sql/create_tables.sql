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
    block_num INTEGER NOT NULL, -- TODO replace op_id reference with these 3 columns
    trx_in_block SMALLINT NOT NULL,
    op_pos INTEGER NOT NULL,
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
    sig BYTEA NOT NULL,
    bv BYTEA NOT NULL
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
    witness_id SERIAL, -- sequential vsc witness id
    did VARCHAR NOT NULL,
    consensus_did VARCHAR,
    sk_posting VARCHAR(53),
    sk_active VARCHAR(53),
    sk_owner VARCHAR(53),
    enabled BOOLEAN DEFAULT FALSE,
    enabled_at BIGINT,
    disabled_at BIGINT,
    first_seen BIGINT NOT NULL,
    git_commit VARCHAR(40),
    last_block INTEGER,
    produced INTEGER DEFAULT 0,
    last_toggle_archive INTEGER NOT NULL,
    last_keyauth_archive INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.witness_toggle_archive(
    id SERIAL PRIMARY KEY,
    witness_id INTEGER NOT NULL, -- hive user id, not vsc witness id
    op_id BIGINT NOT NULL,
    last_updated BIGINT NOT NULL,
    enabled BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.keyauths_archive(
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    op_id BIGINT NOT NULL,
    last_updated BIGINT NOT NULL,
    node_did VARCHAR,
    consensus_did VARCHAR,
    sk_posting VARCHAR(53),
    sk_active VARCHAR(53),
    sk_owner VARCHAR(53)
);

CREATE TABLE IF NOT EXISTS vsc_app.election_results(
    id SERIAL PRIMARY KEY,
    epoch INTEGER NOT NULL,
    proposed_in_op BIGINT NOT NULL,
    proposer INTEGER NOT NULL,
    data_cid VARCHAR(59) NOT NULL,
    sig BYTEA NOT NULL,
    bv BYTEA NOT NULL,
    is_valid BOOLEAN
);

CREATE TABLE IF NOT EXISTS vsc_app.vsc_node_git(
    id INTEGER PRIMARY KEY,
    git_commit VARCHAR(40)
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

CREATE TABLE IF NOT EXISTS vsc_app.deposits_to_hive(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    dest_acc INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.deposits_to_did(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    dest_did INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.withdrawal_request(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    amount2 INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    dest_acc INTEGER NOT NULL,
    status SMALLINT DEFAULT 1
);

CREATE TABLE IF NOT EXISTS vsc_app.withdrawal_status(
    id SERIAL PRIMARY KEY,
    name VARCHAR(10)
);

CREATE TABLE IF NOT EXISTS vsc_app.withdrawals(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    dest_acc INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.dids(
    id SERIAL PRIMARY KEY,
    did VARCHAR(78) NOT NULL,
    UNIQUE(did)
);