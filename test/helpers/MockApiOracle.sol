// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
// pragma experimental ABIEncoderV2;

/**
 * @title The Chainlink Mock Oracle contract
 * @notice Chainlink smart contract developers can use this to test their contracts
 */
contract MockApiOracle {
    function sendRequest(
        uint64 subscriptionId,
        bytes calldata data,
        uint16 dataVersion,
        uint32 callbackGasLimit,
        bytes32 donId
    ) external returns (bytes32) {
        return getRandomBytes32();
    }

    function fulfillRequest(address _requester, bytes32 _requestId, bytes memory _data) external returns (bool) {
        bytes memory err;
        (bool success,) =
            _requester.call(abi.encodeWithSelector(this.handleOracleFulfillment.selector, _requestId, _data, err)); // solhint-disable-line avoid-low-level-calls
        return success;
    }

    function handleOracleFulfillment(bytes32 requestId, bytes memory response, bytes memory err) external {}

    function getRandomBytes32() public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, block.difficulty, msg.sender));
    }
}
