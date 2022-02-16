//SPDX-License-Identifier: Copyright 2021 Shipyard Software, Inc.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface WrapperContractInterface {
  function withdraw(uint256 amount) external;
}

contract ClipperDirectExchange is ERC20, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
  }

  struct Deposit {
      uint lockedUntil;
      uint256 poolTokenAmount;
  }

  uint256 constant ONE_IN_TEN_DECIMALS = 1e10;

  // Signer is passed in on construction, hence "immutable"
  address immutable public DESIGNATED_SIGNER;
  address immutable public WRAPPER_CONTRACT;
  // Constant values for EIP-712 signing
  bytes32 immutable DOMAIN_SEPARATOR;
  string constant VERSION = '1.0.0';
  string constant NAME = 'ClipperDirect';

  bytes32 constant EIP712DOMAIN_TYPEHASH = keccak256(
     abi.encodePacked("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
  );

  bytes32 constant OFFERSTRUCT_TYPEHASH = keccak256(
    abi.encodePacked("OfferStruct(address input_token,address output_token,uint256 input_amount,uint256 output_amount,uint256 good_until,address destination_address)")
  );

  bytes32 constant DEPOSITSTRUCT_TYPEHASH = keccak256(
    abi.encodePacked("DepositStruct(address sender,uint256[] deposit_amounts,uint256 days_locked,uint256 pool_tokens,uint256 good_until)")
  );


  // Assets
  // lastBalances: used for "transmit then swap then sync" modality
  // assetSet is a set of keys that have lastBalances
  mapping(address => uint256) public lastBalances;
  EnumerableSet.AddressSet assetSet;

  // Both deposits and swaps are logged in this structure to prevent replay attacks
  mapping(bytes32 => bool) invalidatedDigests;

  // Allows lookup
  mapping(address => Deposit) public vestingDeposits;


  event Swapped(
    address indexed inAsset,
    address indexed outAsset,
    address indexed recipient,
    uint256 inAmount,
    uint256 outAmount,
    bytes auxiliaryData
  );

  event Deposited(
    address indexed depositor,
    uint256 poolTokens,
    uint256 nDays
  );

  event Withdrawn(
    address indexed withdrawer,
    uint256 poolTokens,
    uint256 fractionOfPool
  );

  // Take in the designated signer address and the token list
  constructor(address theSigner, address theWrapper, address[] memory tokens) ERC20("ClipperDirect Pool Token", "CLPRDRPL") {
    DESIGNATED_SIGNER = theSigner;
    uint i;
    uint n = tokens.length;
    while(i < n) {
        assetSet.add(tokens[i]);
        i++;
    }
    DOMAIN_SEPARATOR = createDomainSeparator(NAME, VERSION, address(this));
    WRAPPER_CONTRACT = theWrapper;
  }

  // Allows the receipt of ETH directly
  receive() external payable {
  }

  function safeEthSend(address recipient, uint256 howMuch) internal {
    (bool success, ) = payable(recipient).call{value: howMuch}("");
    require(success, "Call with value failed");
  }

  /* TOKEN AND ASSET FUNCTIONS */
  function nTokens() public view returns (uint) {
    return assetSet.length();
  }

  function tokenAt(uint i) public view returns (address) {
    return assetSet.at(i);
  } 

  function isToken(address token) public view returns (bool) {
    return assetSet.contains(token);
  }

  function currentDeltaOverLastBalance(address token) internal view returns (uint256) {
    return IERC20(token).balanceOf(address(this))-lastBalances[token];
  }

  function _sync(address token) internal {
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

  // transferAsset(), syncAndTransfer(), and unwrapAndForwardEth() are the three ways tokens leave the pool
  // Since they transfer assets, they are all marked as nonReentrant
  function transferAsset(address token, address recipient, uint256 amount) internal nonReentrant {
    IERC20(token).safeTransfer(recipient, amount);
    // We never want to transfer an asset without sync'ing
    _sync(token);
  }

  function syncAndTransfer(address inputToken, address outputToken, address recipient, uint256 amount) internal nonReentrant {
    _sync(inputToken);
    IERC20(outputToken).safeTransfer(recipient, amount);
    _sync(outputToken);
  }

  // Essentially transferAsset, but for raw ETH
  function unwrapAndForwardEth(address recipient, uint256 amount) internal nonReentrant {
    WrapperContractInterface(WRAPPER_CONTRACT).withdraw(amount);
    safeEthSend(recipient, amount);
    _sync(WRAPPER_CONTRACT);
  }

  /* DEPOSIT FUNCTIONALITY */
  function canUnlockDeposit(address theAddress) public view returns (bool) {
      Deposit storage myDeposit = vestingDeposits[theAddress];
      return (myDeposit.poolTokenAmount > 0) && (myDeposit.lockedUntil <= block.timestamp);
  }

  function unlockDeposit() external returns (uint256 poolTokens) {
    require(canUnlockDeposit(msg.sender), "ClipperDirect: Deposit cannot be unlocked");
    poolTokens = vestingDeposits[msg.sender].poolTokenAmount;
    delete vestingDeposits[msg.sender];

    _transfer(address(this), msg.sender, poolTokens);
  }

  // Mints tokens to this contract to hold for vesting
  function _createVestingDeposit(address theAddress, uint256 nDays, uint256 numPoolTokens) internal {
    require(nDays > 0, "ClipperDirect: Cannot create vesting deposit without positive vesting period");
    require(vestingDeposits[theAddress].poolTokenAmount==0, "ClipperDirect: Depositor already has an active deposit");

    Deposit memory myDeposit = Deposit({
      lockedUntil: block.timestamp + (nDays * 1 days),
      poolTokenAmount: numPoolTokens
    });
    vestingDeposits[theAddress] = myDeposit;
  
    _mint(address(this), numPoolTokens);
  }

  function transmitAndDeposit(uint256[] calldata depositAmounts, uint256 nDays, uint256 poolTokens, uint256 goodUntil, Signature calldata theSignature) external {
    uint i=0;
    uint n = depositAmounts.length;
    while(i < n){
      IERC20(tokenAt(i)).safeTransferFrom(msg.sender, address(this), depositAmounts[i]);
      i++;
    }
    deposit(msg.sender, depositAmounts, nDays, poolTokens, goodUntil, theSignature);
  }

  function deposit(address sender, uint256[] calldata depositAmounts, uint256 nDays, uint256 poolTokens, uint256 goodUntil, Signature calldata theSignature) public {
    // Make sure the depositor is allowed
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
    if(nDays==0){
      // No vesting period required - mint tokens directly for the user
      _mint(sender, poolTokens);
    } else {
      // Set up a vesting deposit for the sender
      _createVestingDeposit(sender, nDays, poolTokens);
    }
    _syncAll();
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


  /* WITHDRAWAL FUNCTIONALITY */
  function _proportionalWithdrawal(uint256 myFraction) internal {
    uint256 toTransfer;

    uint i;
    uint n = nTokens();
    while(i < n) {
        address theToken = tokenAt(i);
        toTransfer = (myFraction*lastBalances[theToken]) / ONE_IN_TEN_DECIMALS;
        // syncs done automatically on transfer
        transferAsset(theToken, msg.sender, toTransfer);
        i++;
    }
  }

  function burnToWithdraw(uint256 amount) external {
    // Capture the fraction first, before burning
    uint256 theFractionBaseTen = (ONE_IN_TEN_DECIMALS*amount)/totalSupply();
    
    // Reverts if balance is insufficient
    _burn(msg.sender, amount);

    _proportionalWithdrawal(theFractionBaseTen);
    emit Withdrawn(msg.sender, amount, theFractionBaseTen);
  }

  /* SWAP Functionality */

  // Don't need a separate "transmit" function here since it's already payable
  function sellEthForToken(address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external payable {
    // Wrap ETH (as balance or value) as input
    safeEthSend(WRAPPER_CONTRACT, inputAmount);
    swap(WRAPPER_CONTRACT, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress, theSignature, auxiliaryData);
  }

  // Mostly copied from swap functionality
  function sellTokenForEth(address inputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) public {
    verifyTokensAndInputAmount(inputToken, WRAPPER_CONTRACT, inputAmount);
    
    bytes32 digest = createSwapDigest(inputToken, WRAPPER_CONTRACT, inputAmount, outputAmount, goodUntil, destinationAddress);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(digest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(digest, goodUntil);
    
    // We have to _sync the input token manually here
    _sync(inputToken);
    unwrapAndForwardEth(destinationAddress, outputAmount);

    emit Swapped(inputToken, WRAPPER_CONTRACT, destinationAddress, inputAmount, outputAmount, auxiliaryData);
  }

  function transmitAndSellTokenForEth(address inputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) external {
    IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    sellTokenForEth(inputToken, inputAmount, outputAmount, goodUntil, destinationAddress, theSignature, auxiliaryData);
  }

  // all-in-one transfer from msg.sender to destinationAddress.
  function transmitAndSwap(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) public {
    IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    swap(inputToken, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress, theSignature, auxiliaryData);
  }

  function swap(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress, Signature calldata theSignature, bytes calldata auxiliaryData) public {
    // Revert if the tokens don't exist or haven't been transmitted
    verifyTokensAndInputAmount(inputToken, outputToken, inputAmount);
    
    bytes32 digest = createSwapDigest(inputToken, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress);
    // Revert if it's signed by the wrong address
    verifyDigestSignature(digest, theSignature);
    // Revert if it's a replay, or if the timestamp is too late
    checkTimestampAndInvalidateDigest(digest, goodUntil);
    // OK, now we are safe to transfer
    syncAndTransfer(inputToken, outputToken, destinationAddress, outputAmount);
    emit Swapped(inputToken, outputToken, destinationAddress, inputAmount, outputAmount, auxiliaryData);
  }


  function verifyTokensAndInputAmount(address inputToken, address outputToken, uint256 inputAmount) internal view {
    require(isToken(inputToken) && isToken(outputToken), "Tokens not present in pool");
    uint256 delta = currentDeltaOverLastBalance(inputToken);
    require((inputAmount > 0) && (delta >= inputAmount), "Insufficient input token amount");
  }


  /* SIGNING Functionality */

  function createDomainSeparator(string memory name, string memory version, address theSigner) internal view returns (bytes32) {
    return keccak256(abi.encode(
        EIP712DOMAIN_TYPEHASH,
        keccak256(abi.encodePacked(name)),
        keccak256(abi.encodePacked(version)),
        uint256(block.chainid),
        theSigner
      ));
  }

  function hashInputOffer(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress) internal pure returns (bytes32) {
    return keccak256(abi.encode(
            OFFERSTRUCT_TYPEHASH,
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            goodUntil,
            destinationAddress
        ));
  }

  function hashDeposit(address sender, uint256[] calldata depositAmounts, uint256 daysLocked, uint256 poolTokens, uint256 goodUntil) internal pure returns (bytes32) {
    bytes32 depositAmountsHash = keccak256(abi.encodePacked(depositAmounts));
    return keccak256(abi.encode(
        DEPOSITSTRUCT_TYPEHASH,
        sender,
        depositAmountsHash,
        daysLocked,
        poolTokens,
        goodUntil
      ));
  }

  function createSwapDigest(address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 goodUntil, address destinationAddress) internal view returns (bytes32 digest){
    bytes32 hashedInput = hashInputOffer(inputToken, outputToken, inputAmount, outputAmount, goodUntil, destinationAddress);    
    digest = ECDSA.toTypedDataHash(DOMAIN_SEPARATOR, hashedInput);
  }

  function createDepositDigest(address sender, uint256[] calldata depositAmounts, uint256 nDays, uint256 poolTokens, uint256 goodUntil) internal view returns (bytes32 depositDigest){
    bytes32 hashedInput = hashDeposit(sender, depositAmounts, nDays, poolTokens, goodUntil);    
    depositDigest = ECDSA.toTypedDataHash(DOMAIN_SEPARATOR, hashedInput);
  }

  function verifyDigestSignature(bytes32 theDigest, Signature calldata theSignature) internal view {
    address signingAddress = ecrecover(theDigest, theSignature.v, theSignature.r, theSignature.s);

    require(signingAddress==DESIGNATED_SIGNER, "Message signed by incorrect address");
  }

  // Used to invalidate swap and deposit digests
  function checkTimestampAndInvalidateDigest(bytes32 theDigest, uint256 goodUntil) internal {
    require(!invalidatedDigests[theDigest], "Message digest already present");
    require(goodUntil >= block.timestamp, "Message received after allowed timestamp");
    invalidatedDigests[theDigest] = true;
  }

}
