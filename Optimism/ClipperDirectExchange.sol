// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2023 Shipyard Software, Inc.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/WrapperContractInterface.sol";

import "./ClipperCommonExchange.sol";

contract ClipperDirectExchange is ClipperCommonExchange {
  
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  // For prevention of replay attacks
  mapping(bytes32 => bool) invalidatedDigests;

  constructor(address theSigner, address theWrapper, address[] memory tokens) 
    ClipperCommonExchange(theSigner, theWrapper, tokens)
    {}

  function currentDeltaOverLastBalance(address token) internal view returns (uint256) {
    return IERC20(token).balanceOf(address(this))-lastBalances[token];
  }

  function _sync(address token) internal override {
    lastBalances[token] = IERC20(token).balanceOf(address(this));
  }

  function _syncAll() internal {
    uint i;
    uint n=assetSet.length();
    while(i < n) {
      _sync(tokenAt(i));
      i++;
    }
  }


  // syncAndTransfer() and unwrapAndForwardEth() are the two additional ways tokens leave the pool
  // Since they transfer assets, they are all marked as nonReentrant
  function syncAndTransfer(address inputToken, address outputToken, address recipient, uint256 amount) internal nonReentrant {
    _sync(inputToken);
    IERC20(outputToken).safeTransfer(recipient, amount);
    _sync(outputToken);
  }

  // Essentially transferAsset, but for raw ETH
  function unwrapAndForwardEth(address recipient, uint256 amount) internal nonReentrant {
    /* EFFECTS */
    WrapperContractInterface(WRAPPER_CONTRACT).withdraw(amount);
    _sync(WRAPPER_CONTRACT);
    /* INTERACTIONS */
    safeEthSend(recipient, amount);
  }

  /* DEPOSIT FUNCTIONALITY */
  function deposit(address sender, uint256[] calldata depositAmounts, uint256 nDays, uint256 poolTokens, uint256 goodUntil, Signature calldata theSignature) public payable override {
    // Wrap if it's there
    if(msg.value > 0){
      safeEthSend(WRAPPER_CONTRACT, msg.value);
    }
    require(msg.sender==sender, "Listed sender does not match msg.sender");
    // Did we actually deposit what we said we would? Revert otherwise
    verifyDepositAmounts(depositAmounts);
    // Check the signature
    bytes32 depositDigest = createDepositDigest(sender, depositAmounts, nDays, poolTokens, goodUntil);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(depositDigest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(depositDigest, goodUntil);
    // OK now we're good
    _syncAll();
    _mintOrVesting(sender, nDays, poolTokens);
    emit Deposited(sender, poolTokens, nDays);
  }

  function depositSingleAsset(address sender, address inputToken, uint256 inputAmount, uint256 nDays, uint256 poolTokens, uint256 goodUntil, Signature calldata theSignature) public payable override {
    // Wrap if it's there
    if(msg.value > 0){
      safeEthSend(WRAPPER_CONTRACT, msg.value);
    }
    require(msg.sender==sender && isToken(inputToken), "Invalid input");

    // Did we actually deposit what we said we would? Revert otherwise
    uint256 delta = currentDeltaOverLastBalance(inputToken);
    require(delta >= inputAmount, "Insufficient token deposit");

    // Check the signature
    bytes32 depositDigest = createSingleDepositDigest(sender, inputToken, inputAmount, nDays, poolTokens, goodUntil);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(depositDigest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(depositDigest, goodUntil);

    // OK now we're good
    _sync(inputToken);
    _mintOrVesting(sender, nDays, poolTokens);
    emit Deposited(sender, poolTokens, nDays);
  }

  function verifyDepositAmounts(uint256[] calldata depositAmounts) internal view {
    uint i=0;
    uint n = depositAmounts.length;
    while(i < n){
      uint256 myDeposit = depositAmounts[i];
      if(myDeposit > 0){
        address token = tokenAt(i);
        uint256 delta = currentDeltaOverLastBalance(token);
        require(delta >= myDeposit, "Insufficient token deposit");
      }
      i++;
    }
  }

  /* Single asset withdrawal functionality */
  function withdrawSingleAsset(address tokenHolder, uint256 poolTokenAmountToBurn, address assetAddress, uint256 assetAmount, uint256 goodUntil, Signature calldata theSignature) external override {
    // Make sure the withdrawer is allowed
    require(msg.sender==tokenHolder, "tokenHolder does not match msg.sender");
    
    bool sendEthBack;
    if(assetAddress == CLIPPER_ETH_SIGIL) {
      assetAddress = WRAPPER_CONTRACT;
      sendEthBack = true;
    }

    // Check the signature
    bytes32 withdrawalDigest = createWithdrawalDigest(tokenHolder, poolTokenAmountToBurn, assetAddress, assetAmount, goodUntil);
    // Reverts if it's signed by the wrong address
    verifyDigestSignature(withdrawalDigest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(withdrawalDigest, goodUntil);
    // Reverts if balance is insufficient
    _burn(msg.sender, poolTokenAmountToBurn);
    // Reverts if balance is insufficient
    // syncs done automatically on transfer
    if(sendEthBack){
      unwrapAndForwardEth(msg.sender, assetAmount);
    } else {
      transferAsset(assetAddress, msg.sender, assetAmount);
    }

    emit AssetWithdrawn(tokenHolder, poolTokenAmountToBurn, assetAddress, assetAmount);
  }

  /* SWAP Functionality */

  // Don't need a separate "transmit" function here since it's already payable
  function sellEthForToken(address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external payable override {
    // Wrap ETH (as balance or value) as input
    safeEthSend(WRAPPER_CONTRACT, inputAmount);
    swap(WRAPPER_CONTRACT, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress, theSignature, auxiliaryData);
  }

  // Mostly copied from swap functionality
  function sellTokenForEth(address inputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external virtual override {
    (uint256 actualInput, uint256 fairOutput) = verifyTokensAndGetAmounts(inputToken, WRAPPER_CONTRACT, inputAmount, outputAmount);
    
    bytes32 digest = createSwapDigest(inputToken, WRAPPER_CONTRACT, inputAmount, outputAmount, goodUntil, destinationAddress);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(digest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(digest, goodUntil);
    
    // We have to _sync the input token manually here
    _sync(inputToken);
    unwrapAndForwardEth(destinationAddress, fairOutput);

    emit Swapped(inputToken, WRAPPER_CONTRACT, destinationAddress, actualInput, fairOutput, auxiliaryData);
  }

  function transmitAndDepositSingleAsset(address inputToken, uint256 inputAmount, uint256 nDays, uint256 poolTokens, uint256 goodUntil, Signature calldata theSignature) external override{
    IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    depositSingleAsset(msg.sender, inputToken, inputAmount, nDays, poolTokens, goodUntil, theSignature);
  }

  function transmitAndSellTokenForEth(address inputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external override {
    IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    this.sellTokenForEth(inputToken, inputAmount, outputAmount, goodUntil, destinationAddress, theSignature, auxiliaryData);
  }

  // all-in-one transfer from msg.sender to destinationAddress.
  function transmitAndSwap(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external override {
    IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    swap(inputToken, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress, theSignature, auxiliaryData);
  }

  function swap(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) public virtual override {
    // Revert if the tokens don't exist
    (uint256 actualInput, uint256 fairOutput) = verifyTokensAndGetAmounts(inputToken, outputToken, inputAmount, outputAmount);
    
    bytes32 digest = createSwapDigest(inputToken, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(digest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(digest, goodUntil);
    // OK, now we are safe to transfer
    syncAndTransfer(inputToken, outputToken, destinationAddress, fairOutput);
    emit Swapped(inputToken, outputToken, destinationAddress, actualInput, fairOutput, auxiliaryData);
  }

  function verifyTokensAndGetAmounts(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount) internal view returns (uint256 actualInput, uint256 fairOutput) {
    require(isToken(inputToken) && isToken(outputToken), "Tokens not present in pool");
    actualInput = currentDeltaOverLastBalance(inputToken);
    fairOutput = calculateFairOutput(inputAmount, actualInput, outputAmount);
  }

  // Used to invalidate swap and deposit digests
  function checkTimestampAndInvalidateDigest(bytes32 theDigest, uint256 goodUntil) internal {
    require(!invalidatedDigests[theDigest], "Message digest already present");
    require(goodUntil >= block.timestamp, "Message received after allowed timestamp");
    invalidatedDigests[theDigest] = true;
  }

}
