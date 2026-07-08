/**
 * Tests for UtexoSourceEntrypoint on Tron.
 * Mirrors the structure of ethereum/test/UtexoSourceEntrypoint.t.sol.
 */

const UtexoSourceEntrypoint = artifacts.require('UtexoSourceEntrypoint');
const MockERC20             = artifacts.require('MockERC20');
const MockOFT               = artifacts.require('MockOFT');

// =============================================================================
// Constants
// =============================================================================

const DST_EID       = 30110;            // Arbitrum LayerZero V2 eid
const LZ_ADAPTER    = '0x' + '00'.repeat(12) + 'c0d1e0000000000000000000000000000000cafe';
const ZERO_ADDR_HEX = '0x' + '0'.repeat(40);
const ZERO_BYTES32  = '0x' + '0'.repeat(64);

const NATIVE_FEE     = 100_000;         // sun (= 0.1 TRX)
const DEST_CHAIN_ID  = 1_000_001;       // RGB id in our reserved range
const DEST_ADDR      = 'tb1q-dest-addr';
const OPERATION_ID   = 42;

const AMOUNT_LD = '100000000';          // 100 USDT (6 decimals), as string

const FEE_LIMIT = 1_000_000_000;        // 1000 TRX cap per call

// Polling settings for revert detection.
const POLL_INTERVAL_MS = 500;
const POLL_TIMEOUT_MS  = 20_000;

// =============================================================================
// Helpers
// =============================================================================

/**
 * Deploys a fresh instance using raw TronWeb (not Contract.new()) so that each
 * call resolves to a unique CREATE-derived address based on the current
 * on-chain nonce of the sender.
 */
async function deploy(artifact, ...parameters) {
  return tronWeb.contract().new({
    abi:               artifact.abi,
    bytecode:          artifact.bytecode,
    feeLimit:          FEE_LIMIT,
    callValue:         0,
    userFeePercentage: 100,
    parameters,
  });
}

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Polls `getTransactionInfo` until it is populated, then returns it. Tron tx
 * confirmation typically lands within 1-3 seconds.
 */
async function waitForTxInfo(txid) {
  const deadline = Date.now() + POLL_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const info = await tronWeb.trx.getTransactionInfo(txid);
    if (info && info.id) return info;
    await sleep(POLL_INTERVAL_MS);
  }
  throw new Error(`waitForTxInfo: tx ${txid} did not confirm within ${POLL_TIMEOUT_MS}ms`);
}

/**
 * Asserts that the call resulted in an on-chain revert. Accepts either:
 *   - a builder chain that ends in `.send(opts)` (we await it and poll), or
 *   - any thenable that already resolves to a txid string.
 */
async function sendExpectRevert(sendPromise) {
  let txid;
  try {
    txid = await sendPromise;
  } catch (e) {
    // TronWeb threw before broadcast — counts as expected revert.
    return;
  }
  if (typeof txid !== 'string') {
    // .send() can sometimes return an object; normalise.
    txid = (txid && (txid.txid || txid.transaction?.txID)) || String(txid);
  }
  const info = await waitForTxInfo(txid);
  const receiptResult = info.receipt && info.receipt.result;
  const isRevert =
       receiptResult === 'REVERT'
    || receiptResult === 'OUT_OF_ENERGY'
    || receiptResult === 'OUT_OF_TIME'
    || receiptResult === 'BAD_JUMP_DESTINATION'
    || info.result === 'FAILED';
  if (!isRevert) {
    assert.fail(`Expected REVERT, got receipt.result=${receiptResult}`);
  }
}

/**
 * Waits for tx confirmation and asserts it succeeded on-chain.
 */
async function sendExpectSuccess(sendPromise) {
  let txid = await sendPromise;
  if (typeof txid !== 'string') {
    txid = (txid && (txid.txid || txid.transaction?.txID)) || String(txid);
  }
  const info = await waitForTxInfo(txid);
  const receiptResult = info.receipt && info.receipt.result;
  const failed =
       receiptResult === 'REVERT'
    || receiptResult === 'OUT_OF_ENERGY'
    || receiptResult === 'OUT_OF_TIME'
    || receiptResult === 'BAD_JUMP_DESTINATION'
    || info.result === 'FAILED';
  if (failed) {
    const msg = info.resMessage ? Buffer.from(info.resMessage, 'hex').toString('utf8') : '';
    assert.fail(`Expected SUCCESS, got receipt.result=${receiptResult}; resMessage=${msg}`);
  }
  return info;
}

/**
 * Asserts that a deploy resulted in a constructor revert (TVM finalises the
 * tx successfully but writes no code to the address).
 */
async function deployExpectRevert(artifact, ...parameters) {
  let instance;
  try {
    instance = await deploy(artifact, ...parameters);
  } catch (e) {
    return; // TronWeb threw before broadcast — counts.
  }
  if (!instance || !instance.address) return;
  const onchain = await tronWeb.trx.getContract(instance.address);
  if (!onchain || !onchain.bytecode || onchain.bytecode === '0x' || onchain.bytecode === '') {
    return; // no code = constructor reverted
  }
  assert.fail(`Deploy succeeded when constructor revert was expected (addr ${instance.address})`);
}

/// NOTE: TronWeb ABI encoding for nested dynamic params (`string`, `bytes`) is
/// flaky when `bytes` is exactly empty (`0x`) in this test environment.
/// Use a non-empty sentinel by default so happy-path `deposit` doesn't revert
/// due to client-side encoding quirks unrelated to contract logic.
const DEFAULT_SETTLEMENT_DATA = '0x00';

/**
 * ABI-encodes the business payload that `Entrypoint.deposit` will decode:
 *   abi.encode(uint256 destinationChainId, string destinationAddress,
 *              uint256 operationId, bytes settlementData)
 *
 * `settlementData` defaults to `DEFAULT_SETTLEMENT_DATA` — for LZ-adapter routes
 * registered with `NullSettlementModule` on Arbitrum, the blob is always empty.
 * Non-empty values are exercised by the round-trip test below.
 */
function encodePayload(destChainId, destAddr, opId, settlementData = DEFAULT_SETTLEMENT_DATA) {
  return tronWeb.utils.abi.encodeParams(
    ['uint256', 'string', 'uint256', 'bytes'],
    [destChainId.toString(), destAddr, opId.toString(), settlementData]
  );
}

/** Strip the leading `41` byte from a hex-encoded Tron address. Returns 20-byte
 *  EVM-form hex with `0x` prefix. */
function tronAddrTo20ByteHex(addrBase58OrHex) {
  const hex = tronWeb.address.toHex(addrBase58OrHex).toLowerCase();
  return '0x' + hex.replace(/^41/, '');
}

// =============================================================================
// Test suite
// =============================================================================

contract('UtexoSourceEntrypoint', () => {
  let token;
  let oft;
  let entrypoint;
  let payload;
  let deployerAddr;

  beforeEach(async () => {
    deployerAddr = tronWeb.defaultAddress.base58;

    token = await deploy(MockERC20._json, 'Mock USDT', 'USDT');
    oft   = await deploy(MockOFT._json, token.address);

    await oft.setNativeFee(NATIVE_FEE).send({ feeLimit: FEE_LIMIT });

    entrypoint = await deploy(
      UtexoSourceEntrypoint._json,
      token.address,
      oft.address,
      DST_EID,
      LZ_ADAPTER
    );

    // Fund the deployer with 1M USDT (6 decimals).
    await token.mint(deployerAddr, '1000000000000').send({ feeLimit: FEE_LIMIT });

    payload = encodePayload(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID);
  });

  // ===========================================================================
  // Construction
  // ===========================================================================

  describe('Construction', () => {
    it('stores token immutable', async () => {
      const got = await entrypoint.token().call();
      assert.equal(tronAddrTo20ByteHex(got), tronAddrTo20ByteHex(token.address));
    });

    it('stores oft immutable', async () => {
      const got = await entrypoint.oft().call();
      assert.equal(tronAddrTo20ByteHex(got), tronAddrTo20ByteHex(oft.address));
    });

    it('stores dstEid immutable', async () => {
      const got = await entrypoint.dstEid().call();
      assert.equal(Number(got), DST_EID);
    });

    it('stores lzAdapter immutable', async () => {
      const got = await entrypoint.lzAdapter().call();
      assert.equal(got.toLowerCase(), LZ_ADAPTER.toLowerCase());
    });

    it('reverts on zero token', async () => {
      await deployExpectRevert(
        UtexoSourceEntrypoint._json, ZERO_ADDR_HEX, oft.address, DST_EID, LZ_ADAPTER
      );
    });

    it('reverts on zero oft', async () => {
      await deployExpectRevert(
        UtexoSourceEntrypoint._json, token.address, ZERO_ADDR_HEX, DST_EID, LZ_ADAPTER
      );
    });

    it('reverts on zero dstEid', async () => {
      await deployExpectRevert(
        UtexoSourceEntrypoint._json, token.address, oft.address, 0, LZ_ADAPTER
      );
    });

    it('reverts on zero lzAdapter', async () => {
      await deployExpectRevert(
        UtexoSourceEntrypoint._json, token.address, oft.address, DST_EID, ZERO_BYTES32
      );
    });
  });

  // ===========================================================================
  // deposit — happy path
  // ===========================================================================

  describe('deposit (happy path)', () => {
    it('pulls tokens and forwards SendParam to OFT', async () => {
      await token.approve(entrypoint.address, AMOUNT_LD).send({ feeLimit: FEE_LIMIT });

      await sendExpectSuccess(
        entrypoint.deposit(
          [AMOUNT_LD, AMOUNT_LD, '0x0003', payload]
        ).send({ callValue: NATIVE_FEE, feeLimit: FEE_LIMIT })
      );

      // OFT received the tokens (proves allowance was set and pull happened).
      assert.equal(
        (await token.balanceOf(oft.address).call()).toString(),
        AMOUNT_LD,
        'oft holds locked tokens'
      );
      assert.equal(
        (await token.balanceOf(entrypoint.address).call()).toString(),
        '0',
        'entrypoint holds no token residue'
      );

      // SendParam forwarded byte-for-byte.
      assert.equal((await oft.lastAmountLD().call()).toString(),    AMOUNT_LD,   'amountLD');
      assert.equal((await oft.lastMinAmountLD().call()).toString(), AMOUNT_LD,   'minAmountLD');
      assert.equal(Number(await oft.lastDstEid().call()),           DST_EID,     'dstEid');
      assert.equal(
        (await oft.lastTo().call()).toLowerCase(),
        LZ_ADAPTER.toLowerCase(),
        'recipient = lzAdapter'
      );
      assert.equal(
        (await oft.lastMsgValue().call()).toString(),
        String(NATIVE_FEE),
        'msg.value forwarded to OFT'
      );

      // Allowance fully consumed (OFT pulled exactly amount).
      assert.equal(
        (await token.allowance(entrypoint.address, oft.address).call()).toString(),
        '0',
        'allowance consumed'
      );
    });

    it('builds composeMsg = abi.encode(block.chainid, destChainId, destAddr, opId, settlementData)', async () => {
      await token.approve(entrypoint.address, AMOUNT_LD).send({ feeLimit: FEE_LIMIT });

      await sendExpectSuccess(
        entrypoint.deposit(
          [AMOUNT_LD, AMOUNT_LD, '0x0003', payload]
        ).send({ callValue: NATIVE_FEE, feeLimit: FEE_LIMIT })
      );

      const composeMsg = await oft.lastComposeMsg().call();
      const decoded = tronWeb.utils.abi.decodeParams(
        [],
        ['uint256', 'uint256', 'string', 'uint256', 'bytes'],
        composeMsg
      );

      // decoded[0] is whatever block.chainid the local node reports; we don't
      // pin its value here — just confirm something was prepended.
      assert.isAbove(Number(decoded[0]), 0, 'sourceChainId prepended');
      assert.equal(decoded[1].toString(), String(DEST_CHAIN_ID), 'destChainId');
      assert.equal(decoded[2],            DEST_ADDR,              'destAddr');
      assert.equal(decoded[3].toString(), String(OPERATION_ID),   'operationId');
      assert.equal(decoded[4],            DEFAULT_SETTLEMENT_DATA, 'settlementData forwarded');
    });

    /// Non-empty `settlementData` must round-trip byte-for-byte through the
    /// payload → composeMsg pipeline so the destination route's
    /// `SettlementModule.onFundsIn` on Arbitrum sees exactly what the caller
    /// intended. LZ-adapter flows default to empty data
    /// (`NullSettlementModule`), but future routes (or future modules) may
    /// consume a non-empty blob and the entrypoint must not lose or mangle it.
    it('round-trips non-empty settlementData through composeMsg', async () => {
      const blob = '0xdeadbeefcafebabe1122334455667788';
      const payloadWithBlob = encodePayload(DEST_CHAIN_ID, DEST_ADDR, OPERATION_ID, blob);

      await token.approve(entrypoint.address, AMOUNT_LD).send({ feeLimit: FEE_LIMIT });

      await sendExpectSuccess(
        entrypoint.deposit(
          [AMOUNT_LD, AMOUNT_LD, '0x0003', payloadWithBlob]
        ).send({ callValue: NATIVE_FEE, feeLimit: FEE_LIMIT })
      );

      const composeMsg = await oft.lastComposeMsg().call();
      const decoded = tronWeb.utils.abi.decodeParams(
        [],
        ['uint256', 'uint256', 'string', 'uint256', 'bytes'],
        composeMsg
      );

      assert.equal(decoded[1].toString(), String(DEST_CHAIN_ID), 'destChainId');
      assert.equal(decoded[2],            DEST_ADDR,              'destAddr');
      assert.equal(decoded[3].toString(), String(OPERATION_ID),   'operationId');
      assert.equal(
        decoded[4].toLowerCase(),
        blob.toLowerCase(),
        'settlementData round-trips byte-for-byte'
      );
    });

    it('forwards extraOptions byte-for-byte', async () => {
      const extra = '0x1234abcd00ff';
      await token.approve(entrypoint.address, AMOUNT_LD).send({ feeLimit: FEE_LIMIT });

      await sendExpectSuccess(
        entrypoint.deposit(
          [AMOUNT_LD, AMOUNT_LD, extra, payload]
        ).send({ callValue: NATIVE_FEE, feeLimit: FEE_LIMIT })
      );

      assert.equal(
        (await oft.lastExtraOptions().call()).toLowerCase(),
        extra.toLowerCase()
      );
      const oftCmd = await oft.lastOftCmd().call();
      assert.isTrue(oftCmd === '0x' || oftCmd === '0x0' || oftCmd === '', 'oftCmd empty');
    });
  });

  // ===========================================================================
  // deposit — reverts
  // ===========================================================================

  describe('deposit (reverts)', () => {
    it('reverts on zero amount', async () => {
      await sendExpectRevert(
        entrypoint.deposit(
          ['0', '0', '0x0003', payload]
        ).send({ callValue: NATIVE_FEE, feeLimit: FEE_LIMIT })
      );
    });

    it('reverts on insufficient native fee', async () => {
      await token.approve(entrypoint.address, AMOUNT_LD).send({ feeLimit: FEE_LIMIT });
      await sendExpectRevert(
        entrypoint.deposit(
          [AMOUNT_LD, AMOUNT_LD, '0x0003', payload]
        ).send({ callValue: NATIVE_FEE - 1, feeLimit: FEE_LIMIT })
      );
    });

    it('reverts on malformed payload (too short to decode)', async () => {
      await token.approve(entrypoint.address, AMOUNT_LD).send({ feeLimit: FEE_LIMIT });
      await sendExpectRevert(
        entrypoint.deposit(
          [AMOUNT_LD, AMOUNT_LD, '0x0003', '0x01020304']
        ).send({ callValue: NATIVE_FEE, feeLimit: FEE_LIMIT })
      );
    });

    it('reverts if token approval is missing', async () => {
      // Deliberately skip `token.approve`.
      await sendExpectRevert(
        entrypoint.deposit(
          [AMOUNT_LD, AMOUNT_LD, '0x0003', payload]
        ).send({ callValue: NATIVE_FEE, feeLimit: FEE_LIMIT })
      );
    });

    it('propagates OFT.send revert', async () => {
      await oft.setSendReverts(true).send({ feeLimit: FEE_LIMIT });
      await token.approve(entrypoint.address, AMOUNT_LD).send({ feeLimit: FEE_LIMIT });
      await sendExpectRevert(
        entrypoint.deposit(
          [AMOUNT_LD, AMOUNT_LD, '0x0003', payload]
        ).send({ callValue: NATIVE_FEE, feeLimit: FEE_LIMIT })
      );
    });
  });

  // ===========================================================================
  // quote
  // ===========================================================================

  describe('quote', () => {
    it('returns the OFT-supplied nativeFee unchanged', async () => {
      const FEE = 12_345_678;
      await oft.setNativeFee(FEE).send({ feeLimit: FEE_LIMIT });

      const quoted = await entrypoint.quote(
        [AMOUNT_LD, AMOUNT_LD, '0x0003', payload]
      ).call();

      assert.equal(quoted.toString(), String(FEE));
    });
  });
});
