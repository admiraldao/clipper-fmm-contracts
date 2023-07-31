//SPDX-License-Identifier: Copyright 2022 Shipyard Software, Inc.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./ClipperCommonExchange.sol";

abstract contract ClipperCommonPacked is ClipperCommonExchange {
  using SafeERC20 for IERC20;
 
  /*
    unpack: internal function to unpack uint256 representation
    Input arguments:
      amountAndAddress: uint256 where first 24 hexchars are a uint96 shortened uint256
                         and last 40 hexchars are an address
    Returns: unpacked amount and address
  */
  function unpack(uint256 amountAndAddress) internal pure returns (uint256 amount, address contractAddress) {
    // uint256 -> uint160 automatically takes just last 40 hexchars
    contractAddress = address(uint160(amountAndAddress));
    // shift over the 40 hexchars to capture the amount
    amount = amountAndAddress >> 160;
  }

  function unpackAndSwap(uint256 packedInput, uint256 packedOutput, uint256 packedDestination, bytes32 auxData, bytes32 r, bytes32 vs, bool performTransfer) internal virtual;

  // external function to transfer tokens and perform swap from packed calldata
  function packedTransmitAndSwap(uint256 packedInput, uint256 packedOutput, uint256 packedDestination, bytes32 auxData, bytes32 r, bytes32 vs) external payable {
    unpackAndSwap(packedInput, packedOutput, packedDestination, auxData, r, vs, true);
  }
  
  // external function to perform swap from packed calldata
  function packedSwap(uint256 packedInput, uint256 packedOutput, uint256 packedDestination, bytes32 auxData, bytes32 r, bytes32 vs) external payable {
    unpackAndSwap(packedInput, packedOutput, packedDestination, auxData, r, vs, false);
  }

  /*
    packedTransmitAndDepositOneAsset: deposit a single asset in a calldata-efficient way
    Input arguments:
      packedInput: Amount and contract address of asset to deposit
      packedConfig: First 32 hexchars are poolTokens, next 24 are goodUntil, next 6 are nDays, final 2 are v
      r, s: Signature values
  */
  function packedTransmitAndDepositOneAsset(uint256 packedInput, uint256 packedConfig, bytes32 r, bytes32 s) external payable {
    (uint256 inputAmount, address inputContractAddress) = unpack(packedInput);
    uint256 poolTokens = packedConfig >> 128;
    uint256 goodUntil = uint256(uint96(packedConfig >> 32));
    uint256 nDays = uint256(uint24(packedConfig >> 8));
    uint8 v = uint8(packedConfig);
    bool inputIsRawEth = (inputContractAddress==CLIPPER_ETH_SIGIL);

    Signature memory theSignature = Signature(v,r,s);
    delete v;

    if(inputIsRawEth){
      // Don't need to wrap the ETH here, do it in the deposit function
      inputContractAddress = WRAPPER_CONTRACT;
    } else {
      IERC20(inputContractAddress).safeTransferFrom(msg.sender, address(this), inputAmount);
    }

    uint i = 0;
    uint n = nTokens();
    uint256[] memory depositAmounts = new uint256[](n); 

    while(i < n){
      depositAmounts[i] = (tokenAt(i) == inputContractAddress) ? inputAmount : 0;
      i++;
    }

    // Have to use delegatecall to preserve msg.sender context
    (bool success, ) = address(this).delegatecall(
      abi.encodeWithSignature(
        "deposit(address,uint256[],uint256,uint256,uint256,(uint8,bytes32,bytes32))",
        msg.sender,
        depositAmounts,
        nDays,
        poolTokens,
        goodUntil,
        theSignature));
    require(success, "Clipper: Deposit failed");
  }

}