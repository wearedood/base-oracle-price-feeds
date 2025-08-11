// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BaseBridge
 * @dev Cross-chain bridge for Base ecosystem with multi-signature validation
 * Features: Multi-chain support, validator consensus, emergency controls
 */
contract BaseBridge is ReentrancyGuard, Ownable, Pausable {
    using ECDSA for bytes32;

    struct BridgeTransaction {
        address token;
        address sender;
        address recipient;
        uint256 amount;
        uint256 targetChain;
        uint256 nonce;
        bool executed;
        uint256 validatorCount;
        mapping(address => bool) validatorSigned;
    }

    struct ChainConfig {
        bool isSupported;
        uint256 minConfirmations;
        uint256 bridgeFee;
        address bridgeContract;
    }

    mapping(bytes32 => BridgeTransaction) public transactions;
    mapping(uint256 => ChainConfig) public chainConfigs;
    mapping(address => bool) public validators;
    mapping(address => bool) public supportedTokens;
    mapping(address => uint256) public tokenLimits;

    address[] public validatorList;
    uint256 public requiredValidators;
    uint256 public transactionNonce;
    uint256 public constant MAX_VALIDATORS = 21;

    event BridgeInitiated(
        bytes32 indexed txHash,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 targetChain
    );

    event BridgeCompleted(
        bytes32 indexed txHash,
        address indexed recipient,
        uint256 amount
    );

    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ChainConfigured(uint256 indexed chainId, bool supported);

    modifier onlyValidator() {
        require(validators[msg.sender], "Not a validator");
        _;
    }

    constructor(address[] memory _validators, uint256 _requiredValidators) {
        require(_validators.length <= MAX_VALIDATORS, "Too many validators");
        require(_requiredValidators <= _validators.length, "Invalid required validators");
        
        for (uint256 i = 0; i < _validators.length; i++) {
            validators[_validators[i]] = true;
            validatorList.push(_validators[i]);
        }
        requiredValidators = _requiredValidators;
    }

    function initiateBridge(
        address _token,
        address _recipient,
        uint256 _amount,
        uint256 _targetChain
    ) external payable nonReentrant whenNotPaused {
        require(supportedTokens[_token], "Token not supported");
        require(chainConfigs[_targetChain].isSupported, "Chain not supported");
        require(_amount <= tokenLimits[_token], "Amount exceeds limit");
        require(_amount > 0, "Amount must be positive");
        
        ChainConfig memory config = chainConfigs[_targetChain];
        require(msg.value >= config.bridgeFee, "Insufficient bridge fee");
        
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        
        bytes32 txHash = keccak256(abi.encodePacked(
            _token,
            msg.sender,
            _recipient,
            _amount,
            _targetChain,
            transactionNonce,
            block.timestamp
        ));

        BridgeTransaction storage bridgeTx = transactions[txHash];
        bridgeTx.token = _token;
        bridgeTx.sender = msg.sender;
        bridgeTx.recipient = _recipient;
        bridgeTx.amount = _amount;
        bridgeTx.targetChain = _targetChain;
        bridgeTx.nonce = transactionNonce;
        
        transactionNonce++;
        
        emit BridgeInitiated(txHash, msg.sender, _recipient, _token, _amount, _targetChain);
    }

    function validateTransaction(bytes32 _txHash) external onlyValidator {
        BridgeTransaction storage bridgeTx = transactions[_txHash];
        require(bridgeTx.amount > 0, "Transaction not found");
        require(!bridgeTx.executed, "Transaction already executed");
        require(!bridgeTx.validatorSigned[msg.sender], "Already validated");
        
        bridgeTx.validatorSigned[msg.sender] = true;
        bridgeTx.validatorCount++;
        
        if (bridgeTx.validatorCount >= requiredValidators) {
            _executeBridge(_txHash);
        }
    }

    function _executeBridge(bytes32 _txHash) internal {
        BridgeTransaction storage bridgeTx = transactions[_txHash];
        bridgeTx.executed = true;
        
        IERC20(bridgeTx.token).transfer(bridgeTx.recipient, bridgeTx.amount);
        
        emit BridgeCompleted(_txHash, bridgeTx.recipient, bridgeTx.amount);
    }

    function emergencyWithdraw(address _token, address _recipient, uint256 _amount) external onlyOwner {
        IERC20(_token).transfer(_recipient, _amount);
    }

    function addValidator(address _validator) external onlyOwner {
        require(!validators[_validator], "Already a validator");
        require(validatorList.length < MAX_VALIDATORS, "Max validators reached");
        
        validators[_validator] = true;
        validatorList.push(_validator);
        
        emit ValidatorAdded(_validator);
    }

    function removeValidator(address _validator) external onlyOwner {
        require(validators[_validator], "Not a validator");
        require(validatorList.length > requiredValidators, "Cannot remove validator");
        
        validators[_validator] = false;
        
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validatorList[i] == _validator) {
                validatorList[i] = validatorList[validatorList.length - 1];
                validatorList.pop();
                break;
            }
        }
        
        emit ValidatorRemoved(_validator);
    }

    function configureChain(uint256 _chainId, bool _supported, uint256 _minConfirmations, uint256 _bridgeFee, address _bridgeContract) external onlyOwner {
        chainConfigs[_chainId] = ChainConfig({
            isSupported: _supported,
            minConfirmations: _minConfirmations,
            bridgeFee: _bridgeFee,
            bridgeContract: _bridgeContract
        });
        
        emit ChainConfigured(_chainId, _supported);
    }

    function addSupportedToken(address _token, uint256 _limit) external onlyOwner {
        supportedTokens[_token] = true;
        tokenLimits[_token] = _limit;
    }

    function removeSupportedToken(address _token) external onlyOwner {
        supportedTokens[_token] = false;
        tokenLimits[_token] = 0;
    }

    function setRequiredValidators(uint256 _required) external onlyOwner {
        require(_required <= validatorList.length, "Invalid required validators");
        require(_required > 0, "Must require at least 1 validator");
        requiredValidators = _required;
    }

    function getValidators() external view returns (address[] memory) {
        return validatorList;
    }

    function getTransactionStatus(bytes32 _txHash) external view returns (bool executed, uint256 validatorCount, uint256 requiredCount) {
        BridgeTransaction storage bridgeTx = transactions[_txHash];
        return (bridgeTx.executed, bridgeTx.validatorCount, requiredValidators);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    receive() external payable {}
}
