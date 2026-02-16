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
