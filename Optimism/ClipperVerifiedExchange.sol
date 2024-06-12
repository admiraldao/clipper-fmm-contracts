// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2023 Shipyard Software, Inc.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";

import "./ClipperDirectExchange.sol";


contract ClipperVerifiedExchange is ClipperDirectExchange {

  using PRBMathSD59x18 for int256;
  using SafeCast for uint256;
  using SafeCast for int256;

  uint256 constant ONE_IN_DEFAULT_DECIMALS = 1e18;
  uint256 constant ONE_IN_PRICE_DECIMALS = 1e8;

  struct UtilStruct {
    uint256 qX;
    uint256 qY;
    uint256 decimalMultiplierX;
    uint256 decimalMultiplierY;
  }

  constructor(address theSigner, address theWrapper, address[] memory tokens)
    ClipperDirectExchange(theSigner, theWrapper, tokens)
  {}

  function sellTokenForEth(address inputToken, uint256 inputAmount, uint256 outputAmount, uint256 packedGoodUntil,
    address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external override {

    (uint256 actualInput, uint256 fairOutput) = verifyTokensAndGetAmounts(inputToken, WRAPPER_CONTRACT, inputAmount, outputAmount);

    uint256 goodUntil = unpackAndCheckInvariant(inputToken, actualInput, WRAPPER_CONTRACT, fairOutput, packedGoodUntil);

    bytes32 digest = createSwapDigest(inputToken, WRAPPER_CONTRACT, inputAmount, outputAmount, packedGoodUntil, destinationAddress);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(digest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(digest, goodUntil);

    // We have to _sync the input token manually here
    _sync(inputToken);
    unwrapAndForwardEth(destinationAddress, fairOutput);

    emit Swapped(inputToken, WRAPPER_CONTRACT, destinationAddress, actualInput, fairOutput, auxiliaryData);
  }

  function swap(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 packedGoodUntil,
    address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) public override {

    // Revert if the tokens don't exist
    (uint256 actualInput, uint256 fairOutput) = verifyTokensAndGetAmounts(inputToken, outputToken, inputAmount, outputAmount);
    uint256 goodUntil = unpackAndCheckInvariant(inputToken, actualInput, outputToken, fairOutput, packedGoodUntil);

    bytes32 digest = createSwapDigest(inputToken, outputToken, inputAmount, outputAmount, packedGoodUntil, destinationAddress);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(digest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(digest, goodUntil);
    // OK, now we are safe to transfer
    syncAndTransfer(inputToken, outputToken, destinationAddress, fairOutput);
    emit Swapped(inputToken, outputToken, destinationAddress, actualInput, fairOutput, auxiliaryData);
  }

  function unpackAndCheckInvariant(address inputToken, uint256 inputAmount, address outputToken, uint256 outputAmount,
    uint256 packedGoodUntil) internal view returns (uint256) {

    UtilStruct memory s;

    (uint256 pX, uint256 pY,uint256 wX, uint256 wY, uint256 k) = unpackGoodUntil(packedGoodUntil);
    s.qX = lastBalances[inputToken];
    s.qY = lastBalances[outputToken];
    s.decimalMultiplierX = 10**(18 - IERC20Metadata(inputToken).decimals());
    s.decimalMultiplierY = 10**(18 - IERC20Metadata(outputToken).decimals());

    require(swapIncreasesInvariant(inputAmount * s.decimalMultiplierX, pX, s.qX * s.decimalMultiplierX, wX,
        outputAmount * s.decimalMultiplierY, pY, s.qY * s.decimalMultiplierY, wY, k), "Invariant check failed");

    return uint256(uint32(packedGoodUntil));
  }

  function unpackGoodUntil(uint256 packedGoodUntil) public pure
    returns (uint256 pX, uint256 pY, uint256 wX, uint256 wY, uint256 k) {
    /*
        * Input asset price in 8 decimals - uint64
        * Output asset price in 8 decimals - uint64
        * k value in 18 decimals - uint64
        * Input asset weight - uint16
        * Output asset weight - uint16
        * Current good until value - uint32 - can be taken as uint256(uint32(packedGoodUntil))
    */
    // goodUntil = uint256(uint32(packedGoodUntil));
    packedGoodUntil = packedGoodUntil >> 32;
    wY = uint256(uint16(packedGoodUntil));
    packedGoodUntil = packedGoodUntil >> 16;
    wX = uint256(uint16(packedGoodUntil));
    packedGoodUntil = packedGoodUntil >> 16;
    k = uint256(uint64(packedGoodUntil));
    packedGoodUntil = packedGoodUntil >> 64;
    pY = uint256(uint64(packedGoodUntil));
    packedGoodUntil = packedGoodUntil >> 64;
    pX = uint256(uint64(packedGoodUntil));
  }

  /*
  Before calling:
  Set qX = lastBalances[inAsset];
  Set qY = lastBalances[outAsset];

  Multiply all quantities (q and in/out) by 10**(18-asset.decimals()).
  This puts all quantities in 18 decimals.

  Assumed decimals:
  K: 18
  Quantities: 18 (ONE_IN_DEFAULT_DECIMALS = 1e18)
  Prices: 8 (ONE_IN_PRICE_DECIMALS = 1e8)
  Weights: 0 (100 = 100)
  */
  function swapIncreasesInvariant(uint256 inX, uint256 pX, uint256 qX, uint256 wX, uint256 outY, uint256 pY, uint256 qY,
    uint256 wY, uint256 k) internal pure returns (bool) {

    uint256 invariantBefore;
    uint256 invariantAfter;
    {
      uint256 pqX = pX * qX / ONE_IN_PRICE_DECIMALS;
      uint256 pqwXk = fractionalPow(pqX * wX, k);
      if (pqwXk > 0) {
        invariantBefore += (ONE_IN_DEFAULT_DECIMALS * pqX) / pqwXk;
      }

      uint256 pqY = pY * qY / ONE_IN_PRICE_DECIMALS;
      uint256 pqwYk = fractionalPow(pqY * wY, k);
      if (pqwYk > 0) {
        invariantBefore += (ONE_IN_DEFAULT_DECIMALS * pqY) / pqwYk;
      }
    }
    {
      uint256 pqXinX = (pX * (qX + inX)) / ONE_IN_PRICE_DECIMALS;
      uint256 pqwXinXk = fractionalPow(pqXinX * wX, k);
      if (pqwXinXk > 0) {
        invariantAfter += (ONE_IN_DEFAULT_DECIMALS * pqXinX) / pqwXinXk;
      }

      uint256 pqYoutY = pY * (qY - outY) / ONE_IN_PRICE_DECIMALS;
      uint256 pqwYoutYk = fractionalPow(pqYoutY * wY, k);
      if (pqwYoutYk > 0) {
        invariantAfter += (ONE_IN_DEFAULT_DECIMALS * pqYoutY) / pqwYoutYk;
      }
    }
    return invariantAfter > invariantBefore;
  }

  function fractionalPow(uint256 input, uint256 pow) internal pure returns (uint256) {
    if (input == 0) {
      return 0;
    } else {
      // input^(pow/1e18) -> exp2( (pow * log2( input ) / 1e18 ) )
      return exp2((int256(pow) * log2(input.toInt256())) / int256(ONE_IN_DEFAULT_DECIMALS));
    }
  }

  function exp2(int256 x) internal pure returns (uint256) {
    return x.exp2().toUint256();
  }

  function log2(int256 x) internal pure returns (int256 y) {
    y = x.log2();
  }

}
