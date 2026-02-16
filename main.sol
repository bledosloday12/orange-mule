// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Remix: open this file in remix.ethereum.org; compiler 0.8.20+; deploy with no args. See REMIX_OrangeMule.md.

/// @title Orange Mule
/// @notice Query index and ranker registry for on-chain discovery; slot limits and crawl epochs are fixed at deploy. Discovery pool seeded from chain id and deploy block.
/// @dev Index keeper submits queries, ranker vault attests rankers, crawl oracle advances epochs. All config is constructor-set.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";

contract OrangeMule is ReentrancyGuard {

    event QueryRegistered(
        bytes32 indexed queryId,
        address indexed submitter,
        uint8 queryTier,
        uint256 crawlEpoch,
        bytes32 payloadHash
    );
    event RankerAttested(
        bytes32 indexed rankerId,
        uint8 slotIndex,
        uint256 attestedAtBlock,
        bytes32 configHash
    );
    event CrawlEpochBumped(uint256 previousEpoch, uint256 newEpoch, uint256 atBlock);
    event ResultHashStored(
        bytes32 indexed queryId,
        bytes32 resultHash,
        uint256 storedAtBlock
    );
    event DiscoveryPoolTopped(uint256 amount, address indexed from, uint256 newBalance);

    error ErrQuerySlotExhausted();
    error ErrNotIndexKeeper();
    error ErrEpochWindowNotReached();
    error ErrRankerSlotInvalid();
    error ErrDuplicateQueryId();
    error ErrQueryNotFound();
    error ErrZeroQueryId();
    error ErrCrawlCapReached();
    error ErrNotRankerVault();
    error ErrNotCrawlOracle();
    error ErrResultAlreadyStored();
    error ErrZeroResultHash();

    uint256 public constant MAX_QUERIES_PER_EPOCH = 256;
    uint256 public constant RANKER_SLOTS = 16;
    uint256 public constant EPOCH_BLOCKS = 64;
    uint256 public constant MAX_CRAWL_EPOCHS = 2048;
    bytes32 public constant DISCOVERY_DOMAIN =
        bytes32(0xa1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1);

    address public immutable indexKeeper;
    address public immutable rankerVault;
    address public immutable crawlOracle;
    uint256 public immutable genesisBlock;
    bytes32 public immutable discoverySeed;

    uint256 public currentCrawlEpoch;
    uint256 public totalQueriesRegistered;
    uint256 public discoveryPoolBalance;
    mapping(uint256 => uint256) private _queriesInEpoch;
    mapping(bytes32 => IndexedQuery) private _queries;
    mapping(bytes32 => bytes32) private _resultHashes;
    bytes32[] private _queryIdList;
    mapping(uint256 => RankerSlot) private _rankerSlots;
    mapping(uint256 => bool) private _epochAdvanced;

    struct IndexedQuery {
        bytes32 queryId;
        address submitter;
        uint8 queryTier;
        uint256 crawlEpoch;
        uint256 registeredAtBlock;
        bytes32 payloadHash;
        bool resultStored;
    }

    struct RankerSlot {
        bytes32 rankerId;
        bytes32 configHash;
        uint256 attestedAtBlock;
        bool active;
    }

    modifier onlyIndexKeeper() {
        if (msg.sender != indexKeeper) revert ErrNotIndexKeeper();
        _;
    }

    modifier onlyRankerVault() {
        if (msg.sender != rankerVault) revert ErrNotRankerVault();
        _;
    }

    modifier onlyCrawlOracle() {
        if (msg.sender != crawlOracle) revert ErrNotCrawlOracle();
        _;
    }

    constructor() {
        indexKeeper = address(0x8c3Ea1F5b7D9c2B4e6A0d8F1a3C5e7B9d2F4a6);
        rankerVault = address(0xD2f4A6c8E0b3D5f7A9c1E3b6D8f0A2c4E6b9d1);
        crawlOracle = address(0xF5a7C9e1B3d6F8a0C2e4B7d9F1a3c6E8b0D2f4);
        genesisBlock = block.number;
        discoverySeed = keccak256(
            abi.encodePacked(
                block.chainid,
                block.prevrandao,
                block.timestamp,
                blockhash(block.number - 1),
                "OrangeMule_Discovery_v2"
            )
        );
        currentCrawlEpoch = 0;
        totalQueriesRegistered = 0;
        discoveryPoolBalance = 0;
    }

    function _epochForBlock(uint256 blockNum) internal view returns (uint256) {
        if (blockNum <= genesisBlock) return 0;
        return (blockNum - genesisBlock) / EPOCH_BLOCKS;
    }

    function _advanceCrawlEpoch() internal {
        uint256 epoch = _epochForBlock(block.number);
        if (epoch > currentCrawlEpoch && epoch <= MAX_CRAWL_EPOCHS) {
            uint256 prev = currentCrawlEpoch;
            currentCrawlEpoch = epoch;
            _epochAdvanced[epoch] = true;
            emit CrawlEpochBumped(prev, epoch, block.number);
        }
    }

    function registerQuery(
        bytes32 queryId,
        uint8 queryTier,
        bytes32 payloadHash
    ) external onlyIndexKeeper nonReentrant {
        if (queryId == bytes32(0)) revert ErrZeroQueryId();
        _advanceCrawlEpoch();
        uint256 epoch = currentCrawlEpoch;
        if (_queriesInEpoch[epoch] >= MAX_QUERIES_PER_EPOCH) revert ErrQuerySlotExhausted();
        IndexedQuery storage q = _queries[queryId];
        if (q.registeredAtBlock != 0) revert ErrDuplicateQueryId();
        if (queryTier > 7) queryTier = 0;

        q.queryId = queryId;
        q.submitter = msg.sender;
        q.queryTier = queryTier;
        q.crawlEpoch = epoch;
        q.registeredAtBlock = block.number;
        q.payloadHash = payloadHash;
        q.resultStored = false;
        _queriesInEpoch[epoch] += 1;
        totalQueriesRegistered += 1;
        _queryIdList.push(queryId);
        emit QueryRegistered(queryId, msg.sender, queryTier, epoch, payloadHash);
    }

    function attestRanker(
        uint8 slotIndex,
        bytes32 rankerId,
        bytes32 configHash
    ) external onlyRankerVault nonReentrant {
        if (slotIndex >= RANKER_SLOTS) revert ErrRankerSlotInvalid();
        RankerSlot storage slot = _rankerSlots[slotIndex];
        slot.rankerId = rankerId;
        slot.configHash = configHash;
        slot.attestedAtBlock = block.number;
        slot.active = true;
        emit RankerAttested(rankerId, slotIndex, block.number, configHash);
    }

    function deactivateRankerSlot(uint8 slotIndex) external onlyRankerVault nonReentrant {
        if (slotIndex >= RANKER_SLOTS) revert ErrRankerSlotInvalid();
        _rankerSlots[slotIndex].active = false;
    }

    function storeResult(bytes32 queryId, bytes32 resultHash)
        external
        onlyIndexKeeper
        nonReentrant
    {
        if (resultHash == bytes32(0)) revert ErrZeroResultHash();
        IndexedQuery storage q = _queries[queryId];
        if (q.registeredAtBlock == 0) revert ErrQueryNotFound();
        if (q.resultStored) revert ErrResultAlreadyStored();
        q.resultStored = true;
        _resultHashes[queryId] = resultHash;
        emit ResultHashStored(queryId, resultHash, block.number);
    }

    function bumpCrawlEpoch() external onlyCrawlOracle nonReentrant {
        _advanceCrawlEpoch();
    }

    function topDiscoveryPool() external payable nonReentrant {
        if (msg.value == 0) return;
        discoveryPoolBalance += msg.value;
        emit DiscoveryPoolTopped(msg.value, msg.sender, discoveryPoolBalance);
    }

    function getQuery(bytes32 queryId)
        external
        view
        returns (
            address submitter,
            uint8 queryTier,
            uint256 crawlEpoch,
            uint256 registeredAtBlock,
            bytes32 payloadHash,
            bool resultStored
        )
    {
        IndexedQuery storage q = _queries[queryId];
        if (q.registeredAtBlock == 0) revert ErrQueryNotFound();
        return (
