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
