//SPDX-License-Identifier: Copyright 2021 Shipyard Software, Inc.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/WrapperContractInterface.sol";

import "./ClipperCommonExchange.sol";

contract ClipperCaravelExchange is ClipperCommonExchange, Ownable {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  modifier receivedInTime(uint256 goodUntil){
    require(block.timestamp <= goodUntil, "Clipper: Expired");
    _;
  }

  constructor(address theSigner, address theWrapper, address[] memory tokens)
    ClipperCommonExchange(theSigner, theWrapper, tokens)
    {}

  function addAsset(address token) external onlyOwner {
    assetSet.add(token);
    _sync(token);
  }

  function tokenBalance(address token) internal view returns (uint256) {
    (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
    require(success && data.length >= 32);
    return abi.decode(data, (uint256));
  }

  function _sync(address token) internal override {
    lastBalances[token] = tokenBalance(token);
  }

  // Can deposit raw ETH by attaching as msg.value
  function deposit(address sender, uint256[] calldata depositAmounts, uint256 nDays, uint256 poolTokens, uint256 goodUntil, Signature calldata theSignature) public payable override receivedInTime(goodUntil){
    if(msg.value > 0){
      safeEthSend(WRAPPER_CONTRACT, msg.value);
    }
    // Make sure the depositor is allowed
    require(msg.sender==sender, "Listed sender does not match msg.sender");
    bytes32 depositDigest = createDepositDigest(sender, depositAmounts, nDays, poolTokens, goodUntil);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(depositDigest, theSignature);

    // Check deposit amounts, syncing as we go
    uint i=0;
    uint n = depositAmounts.length;
    while(i < n){
      uint256 allegedDeposit = depositAmounts[i];
      if(allegedDeposit > 0){
        address _token = tokenAt(i);
        uint256 currentBalance = tokenBalance(_token);
        require(currentBalance - lastBalances[_token] >= allegedDeposit, "Insufficient token deposit");
        lastBalances[_token] = currentBalance;
      }
      i++;
    }
    // OK now we're good
    if(nDays==0){
      // No vesting period required - mint tokens directly for the user
      _mint(sender, poolTokens);
    } else {
      // Set up a vesting deposit for the sender
      _createVestingDeposit(sender, nDays, poolTokens);
    }
    emit Deposited(sender, poolTokens, nDays);
  }

  /* WITHDRAWAL FUNCTIONALITY */
  
  function _proportionalWithdrawalSelected(uint256 myFraction, address[] calldata tokens) internal {
    uint256 toTransfer;

    uint i;
    uint j;
    uint n = tokens.length;

    while(i < n) {
        address theToken = tokens[i];
        require(isToken(theToken), "Clipper: Invalid token");
        toTransfer = (myFraction*lastBalances[theToken]) / ONE_IN_TEN_DECIMALS;
        // syncs done automatically on transfer
        transferAsset(theToken, msg.sender, toTransfer);
        for(j=i+1 ; j<n ; j++){
          require(tokens[j]!=theToken, "Clipper: Dupe token");
        }
        i++;
    }
  }

  function burnToWithdrawSpecificAssets(uint256 amount, address[] calldata tokens) external {
    // Capture the fraction first, before burning
    uint256 theFractionBaseTen = (ONE_IN_TEN_DECIMALS*amount)/totalSupply();

    // Reverts if balance is insufficient
    _burn(msg.sender, amount);

    _proportionalWithdrawalSelected(theFractionBaseTen, tokens);
    emit Withdrawn(msg.sender, amount, theFractionBaseTen);
  }

  /* Single asset withdrawal functionality */

  function withdrawSingleAsset(address tokenHolder, uint256 poolTokenAmountToBurn, address assetAddress, uint256 assetAmount, uint256 goodUntil, Signature calldata theSignature) external override receivedInTime(goodUntil) {
    /* CHECKS */
    require(msg.sender==tokenHolder, "tokenHolder does not match msg.sender");
    bytes32 withdrawalDigest = createWithdrawalDigest(tokenHolder, poolTokenAmountToBurn, assetAddress, assetAmount, goodUntil);
    // Reverts if it's signed by the wrong address
    verifyDigestSignature(withdrawalDigest, theSignature);

    /* EFFECTS */
    // Reverts if balance is insufficient
    _burn(msg.sender, poolTokenAmountToBurn);
    // Reverts if balance is insufficient
    lastBalances[assetAddress] -= assetAmount;

    /* INTERACTIONS */
    IERC20(assetAddress).safeTransfer(msg.sender, assetAmount);

    emit AssetWithdrawn(tokenHolder, poolTokenAmountToBurn, assetAddress, assetAmount);
  }

  /* SWAP Functionality */

  // Don't need a separate "transmit" function here since it's already payable
  // Gas optimized - no balance checks
  // Don't need fairOutput checks since exactly inputAmount is wrapped
  function sellEthForToken(address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external override receivedInTime(goodUntil) payable {
    /* CHECKS */
    require(isToken(outputToken), "Clipper: Invalid token");
    // Wrap ETH (as balance or value) as input. This will revert if insufficient balance is provided
    safeEthSend(WRAPPER_CONTRACT, inputAmount);
    // Revert if it's signed by the wrong address    
    bytes32 digest = createSwapDigest(WRAPPER_CONTRACT, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress);
    verifyDigestSignature(digest, theSignature);

    /* EFFECTS */
    lastBalances[WRAPPER_CONTRACT] += inputAmount;
    lastBalances[outputToken] -= outputAmount;

    /* INTERACTIONS */
    IERC20(outputToken).safeTransfer(destinationAddress, outputAmount);

    emit Swapped(WRAPPER_CONTRACT, outputToken, destinationAddress, inputAmount, outputAmount, auxiliaryData);
  }

  // Mostly copied from gas-optimized swap functionality
  function sellTokenForEth(address inputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external override receivedInTime(goodUntil) {
    /* CHECKS */
    require(isToken(inputToken), "Clipper: Invalid token");
    // Revert if it's signed by the wrong address    
    bytes32 digest = createSwapDigest(inputToken, WRAPPER_CONTRACT, inputAmount, outputAmount, goodUntil, destinationAddress);
    verifyDigestSignature(digest, theSignature);
    
    // Check that enough input token has been transmitted
    uint256 currentInputBalance = tokenBalance(inputToken);
    uint256 actualInput = currentInputBalance-lastBalances[inputToken];    
    uint256 fairOutput = calculateFairOutput(inputAmount, actualInput, outputAmount);


    /* EFFECTS */
    lastBalances[inputToken] = currentInputBalance;
    lastBalances[WRAPPER_CONTRACT] -= fairOutput;

    /* INTERACTIONS */
    // Unwrap and forward ETH, without sync
    WrapperContractInterface(WRAPPER_CONTRACT).withdraw(fairOutput);
    safeEthSend(destinationAddress, fairOutput);

    emit Swapped(inputToken, WRAPPER_CONTRACT, destinationAddress, actualInput, fairOutput, auxiliaryData);
  }

  // Gas optimized, no balance checks
  // No need to check fairOutput since the inputToken pull works
  function transmitAndSellTokenForEth(address inputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external override receivedInTime(goodUntil) {
    /* CHECKS */
    require(isToken(inputToken), "Clipper: Invalid token");
    // Will revert if msg.sender has insufficient balance
    IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    // Revert if it's signed by the wrong address    
    bytes32 digest = createSwapDigest(inputToken, WRAPPER_CONTRACT, inputAmount, outputAmount, goodUntil, destinationAddress);
    verifyDigestSignature(digest, theSignature);

    /* EFFECTS */
    lastBalances[inputToken] += inputAmount;
    lastBalances[WRAPPER_CONTRACT] -= outputAmount;
    // Wrapper contract lastBalance set in unwrapAndForward

    /* INTERACTIONS */
    // Unwrap and forward ETH, no _sync
    WrapperContractInterface(WRAPPER_CONTRACT).withdraw(outputAmount);
    safeEthSend(destinationAddress, outputAmount);

    emit Swapped(inputToken, WRAPPER_CONTRACT, destinationAddress, inputAmount, outputAmount, auxiliaryData);
  }

  // all-in-one transfer from msg.sender to destinationAddress.
  // Gas optimized - never checks balances
  // No need to check fairOutput since the inputToken pull works
  function transmitAndSwap(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external override receivedInTime(goodUntil) {
    /* CHECKS */
    require(isToken(inputToken) && isToken(outputToken), "Clipper: Invalid tokens");
    // Will revert if msg.sender has insufficient balance
    IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    // Revert if it's signed by the wrong address    
    bytes32 digest = createSwapDigest(inputToken, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress);
    verifyDigestSignature(digest, theSignature);

    /* EFFECTS */
    lastBalances[inputToken] += inputAmount;
    lastBalances[outputToken] -= outputAmount;

    /* INTERACTIONS */
    IERC20(outputToken).safeTransfer(destinationAddress, outputAmount);

    emit Swapped(inputToken, outputToken, destinationAddress, inputAmount, outputAmount, auxiliaryData);
  }

  // Gas optimized - single token balance check for input
  // output is dead-reckoned and scaled back if necessary
  function swap(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) public override receivedInTime(goodUntil) {
    /* CHECKS */
    require(isToken(inputToken) && isToken(outputToken), "Clipper: Invalid tokens");

    { // Avoid stack too deep
    // Revert if it's signed by the wrong address    
    bytes32 digest = createSwapDigest(inputToken, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress);
    verifyDigestSignature(digest, theSignature);
    }

    // Get fair output value
    uint256 currentInputBalance = tokenBalance(inputToken);
    uint256 actualInput = currentInputBalance-lastBalances[inputToken];    
    uint256 fairOutput = calculateFairOutput(inputAmount, actualInput, outputAmount);


    /* EFFECTS */
    lastBalances[inputToken] = currentInputBalance;
    lastBalances[outputToken] -= fairOutput;

    /* INTERACTIONS */
    IERC20(outputToken).safeTransfer(destinationAddress, fairOutput);

    emit Swapped(inputToken, outputToken, destinationAddress, actualInput, fairOutput, auxiliaryData);
  }

}
