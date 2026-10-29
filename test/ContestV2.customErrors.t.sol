// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ContestV2.sol";

/// @title ContestV2 Custom Errors Test
/// @notice Verifies custom error selectors are correct and match expected values
contract ContestV2CustomErrorsTest is Test {

    // ─── Custom Error Selector Verification ─────────────────────────────────────��
    // These tests ensure that after the require→custom error migration,
    // all selectors are stable and match the expected keccak256 values.

    function test_selector_InvalidState() public pure {
        assertEq(ContestV2.InvalidState.selector, bytes4(keccak256("InvalidState()")));
    }

    function test_selector_NotCreator() public pure {
        assertEq(ContestV2.NotCreator.selector, bytes4(keccak256("NotCreator()")));
    }

    function test_selector_NotFactory() public pure {
        assertEq(ContestV2.NotFactory.selector, bytes4(keccak256("NotFactory()")));
    }

    function test_selector_AlreadyInitialized() public pure {
        assertEq(ContestV2.AlreadyInitialized.selector, bytes4(keccak256("AlreadyInitialized()")));
    }

    function test_selector_InvalidConfig() public pure {
        assertEq(ContestV2.InvalidConfig.selector, bytes4(keccak256("InvalidConfig()")));
    }

    function test_selector_NotDeposited() public pure {
        assertEq(ContestV2.NotDeposited.selector, bytes4(keccak256("NotDeposited()")));
    }

    function test_selector_AlreadyDeposited() public pure {
        assertEq(ContestV2.AlreadyDeposited.selector, bytes4(keccak256("AlreadyDeposited()")));
    }

    function test_selector_AlreadyCommitted() public pure {
        assertEq(ContestV2.AlreadyCommitted.selector, bytes4(keccak256("AlreadyCommitted()")));
    }

    function test_selector_AlreadyRevealed() public pure {
        assertEq(ContestV2.AlreadyRevealed.selector, bytes4(keccak256("AlreadyRevealed()")));
    }

    function test_selector_AlreadyCancelled() public pure {
        assertEq(ContestV2.AlreadyCancelled.selector, bytes4(keccak256("AlreadyCancelled()")));
    }

    function test_selector_AlreadyFinalized() public pure {
        assertEq(ContestV2.AlreadyFinalized.selector, bytes4(keccak256("AlreadyFinalized()")));
    }

    function test_selector_AlreadyClaimed() public pure {
        assertEq(ContestV2.AlreadyClaimed.selector, bytes4(keccak256("AlreadyClaimed()")));
    }

    function test_selector_InvalidReveal() public pure {
        assertEq(ContestV2.InvalidReveal.selector, bytes4(keccak256("InvalidReveal()")));
    }

    function test_selector_InvalidOption() public pure {
        assertEq(ContestV2.InvalidOption.selector, bytes4(keccak256("InvalidOption()")));
    }

    // Submission errors (InvalidSubmission / SubmissionsNotEnabled / SubmissionsNotOpen)
    // were removed in the 2026-04 slim-down along with the submission feature.

    function test_selector_NotAuthorized() public pure {
        assertEq(ContestV2.NotAuthorized.selector, bytes4(keccak256("NotAuthorized()")));
    }

    function test_selector_TransferFailed() public pure {
        assertEq(ContestV2.TransferFailed.selector, bytes4(keccak256("TransferFailed()")));
    }

    function test_selector_TooManyOptions() public pure {
        assertEq(ContestV2.TooManyOptions.selector, bytes4(keccak256("TooManyOptions()")));
    }

    function test_selector_NoReward() public pure {
        assertEq(ContestV2.NoReward.selector, bytes4(keccak256("NoReward()")));
    }

    function test_selector_TierRequired() public pure {
        assertEq(ContestV2.TierRequired.selector, bytes4(keccak256("TierRequired()")));
    }

    function test_selector_WindowNotActive() public pure {
        assertEq(ContestV2.WindowNotActive.selector, bytes4(keccak256("WindowNotActive()")));
    }

    // ─── All selectors are unique (no collisions) ────────────────────────────────

    function test_allSelectorsUnique() public pure {
        bytes4[] memory selectors = new bytes4[](20);
        selectors[0]  = ContestV2.InvalidState.selector;
        selectors[1]  = ContestV2.NotCreator.selector;
        selectors[2]  = ContestV2.NotFactory.selector;
        selectors[3]  = ContestV2.AlreadyInitialized.selector;
        selectors[4]  = ContestV2.InvalidConfig.selector;
        selectors[5]  = ContestV2.NotDeposited.selector;
        selectors[6]  = ContestV2.AlreadyDeposited.selector;
        selectors[7]  = ContestV2.AlreadyCommitted.selector;
        selectors[8]  = ContestV2.AlreadyRevealed.selector;
        selectors[9]  = ContestV2.AlreadyCancelled.selector;
        selectors[10] = ContestV2.AlreadyFinalized.selector;
        selectors[11] = ContestV2.AlreadyClaimed.selector;
        selectors[12] = ContestV2.InvalidReveal.selector;
        selectors[13] = ContestV2.InvalidOption.selector;
        selectors[14] = ContestV2.NotAuthorized.selector;
        selectors[15] = ContestV2.TransferFailed.selector;
        selectors[16] = ContestV2.TooManyOptions.selector;
        selectors[17] = ContestV2.NoReward.selector;
        selectors[18] = ContestV2.TierRequired.selector;
        selectors[19] = ContestV2.WindowNotActive.selector;

        for (uint256 i = 0; i < selectors.length; i++) {
            for (uint256 j = i + 1; j < selectors.length; j++) {
                assertTrue(selectors[i] != selectors[j], "Selector collision detected");
            }
        }
    }
}
