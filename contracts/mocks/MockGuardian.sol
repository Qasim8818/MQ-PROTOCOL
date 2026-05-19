// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDarkPoolCoreLike {
    function pause() external;
}

contract MockGuardian {
    // Presence of code passes DarkPoolCore constructor guardian check.
    // Also acts as a minimal transaction sender for pause() in tests.

    function pauseDarkPool(address darkPool) external {
        IDarkPoolCoreLike(darkPool).pause();
    }
}


