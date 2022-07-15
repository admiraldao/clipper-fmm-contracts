//SPDX-License-Identifier: Copyright 2022 Shipyard Software, Inc.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./ClipperCommonPacked.sol";
import "./ClipperVerifiedExchange.sol";

contract ClipperPackedVerifiedExchange is ClipperCommonPacked, ClipperVerifiedExchange {
  using SafeERC20 for IERC20;
 
  constructor(address theSigner, address theWrapper, address[] memory tokens) 
    ClipperVerifiedExchange(theSigner, theWrapper, tokens)
    {}

  /*
    unpackAndSwap: internal function that performs unpacks a set of calldata-packed inputs and performs a swap
    Input arguments:
      packedInput: input amount and contract
      packedOutput: output amount and contract
      packedGoodUntil: packed good until (for verifier, direct from server)
      auxData: bytes32, identifier. Final 20 bytes are destination address. First 12 bytes are auxData identifier string.
      r, vs: Signature values using EIP 2098 - https://eips.ethereum.org/EIPS/eip-2098
      performTransfer: if tokens should be transferred from msg.sender
  */
  function unpackAndSwap(uint256 packedInput, uint256 packedOutput, uint256 packedGoodUntil, bytes32 auxData, bytes32 r, bytes32 vs, bool performTransfer) internal override {    
    (uint256 inputAmount, address inputContractAddress) = unpack(packedInput);
    (uint256 outputAmount, address outputContractAddress) = unpack(packedOutput);
    Signature memory theSignature;

    {
      // Directly from https://eips.ethereum.org/EIPS/eip-2098
      bytes32 s = vs & 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
      uint8 v = 27 + uint8(uint256(vs) >> 255);

      theSignature = Signature(v,r,s);
    }

    if(performTransfer && (inputContractAddress!=CLIPPER_ETH_SIGIL)) {
      IERC20(inputContractAddress).safeTransferFrom(msg.sender, address(this), inputAmount);
    }

    performUnpackedSwap(inputContractAddress, outputContractAddress, inputAmount, outputAmount, packedGoodUntil, auxData, theSignature);
  }

  function performUnpackedSwap(address inputContractAddress, address outputContractAddress, uint256 inputAmount, uint256 outputAmount, uint256 packedGoodUntil, bytes32 auxData, Signature memory theSignature) internal {
      address destinationAddress = address(uint160(uint256(auxData)));
      bytes memory auxiliaryData = abi.encodePacked(auxData >> 40);
      
      if(inputContractAddress==CLIPPER_ETH_SIGIL) {
        this.sellEthForToken(outputContractAddress, inputAmount, outputAmount, packedGoodUntil, destinationAddress, theSignature, auxiliaryData);
      } else if(outputContractAddress==CLIPPER_ETH_SIGIL) {
        this.sellTokenForEth(inputContractAddress, inputAmount, outputAmount, packedGoodUntil, destinationAddress, theSignature, auxiliaryData);
      } else {
        this.swap(inputContractAddress, outputContractAddress, inputAmount, outputAmount, packedGoodUntil, destinationAddress, theSignature, auxiliaryData);
      }

  }
}
