// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ICrypto5Factory {
    function issuanceIndexTokens(
        address _tokenIn,
        address[] memory _tokenInPath,
        uint24[] memory _tokenInFees,
        uint256 _inputAmount
    ) external payable;
}
