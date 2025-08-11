
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title BasePriceOracle
 * @dev Advanced oracle contract for Base blockchain price feeds
 * @notice Provides decentralized price data aggregation with MEV protection
 */
contract BasePriceOracle is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    struct PriceFeed {
        uint256 price;
        uint256 timestamp;
        uint256 confidence;
        bool isActive;
    }

    struct OracleNode {
        address nodeAddress;
        uint256 reputation;
        uint256 lastUpdate;
        bool isAuthorized;
    }

    // State variables
    mapping(string => PriceFeed) public priceFeeds;
    mapping(address => OracleNode) public oracleNodes;
    mapping(string => address[]) public feedProviders;
    
    address[] public authorizedNodes;
    uint256 public constant PRICE_VALIDITY_PERIOD = 300; // 5 minutes
    uint256 public constant MIN_CONFIDENCE_THRESHOLD = 80;
    uint256 public constant MAX_PRICE_DEVIATION = 500; // 5%
    
    // Events
    event PriceUpdated(
        string indexed symbol,
        uint256 price,
        uint256 timestamp,
        address indexed provider
    );
    
    event NodeAuthorized(address indexed node, uint256 reputation);
    event NodeDeauthorized(address indexed node);
    event PriceFeedAdded(string indexed symbol);
    
    modifier onlyAuthorizedNode() {
        require(oracleNodes[msg.sender].isAuthorized, "Not authorized node");
        _;
    }

    modifier validSymbol(string memory symbol) {
        require(bytes(symbol).length > 0, "Invalid symbol");
        _;
    }

    constructor() {
        // Initialize with common Base ecosystem tokens
        _addPriceFeed("ETH");
        _addPriceFeed("USDC");
        _addPriceFeed("WETH");
        _addPriceFeed("cbETH");
    }

    /**
     * @dev Add a new price feed
     * @param symbol Token symbol to add
     */
    function addPriceFeed(string memory symbol) external onlyOwner validSymbol(symbol) {
        _addPriceFeed(symbol);
    }

    function _addPriceFeed(string memory symbol) internal {
        priceFeeds[symbol] = PriceFeed({
            price: 0,
            timestamp: 0,
            confidence: 0,
            isActive: true
        });
        emit PriceFeedAdded(symbol);
    }

    /**
     * @dev Update price for a given symbol
     * @param symbol Token symbol
     * @param price New price in wei
     * @param confidence Confidence level (0-100)
     */
    function updatePrice(
        string memory symbol,
        uint256 price,
        uint256 confidence
    ) external onlyAuthorizedNode nonReentrant validSymbol(symbol) {
        require(priceFeeds[symbol].isActive, "Price feed not active");
        require(price > 0, "Price must be positive");
        require(confidence <= 100, "Invalid confidence level");
        require(confidence >= MIN_CONFIDENCE_THRESHOLD, "Confidence too low");

        // MEV protection: check for suspicious price movements
        if (priceFeeds[symbol].price > 0) {
            uint256 priceChange = price > priceFeeds[symbol].price 
                ? price.sub(priceFeeds[symbol].price)
                : priceFeeds[symbol].price.sub(price);
            
            uint256 percentageChange = priceChange.mul(10000).div(priceFeeds[symbol].price);
            require(percentageChange <= MAX_PRICE_DEVIATION, "Price deviation too high");
        }

        priceFeeds[symbol] = PriceFeed({
            price: price,
            timestamp: block.timestamp,
            confidence: confidence,
            isActive: true
        });

        // Update node reputation
        oracleNodes[msg.sender].lastUpdate = block.timestamp;
        oracleNodes[msg.sender].reputation = oracleNodes[msg.sender].reputation.add(1);

        emit PriceUpdated(symbol, price, block.timestamp, msg.sender);
    }

    /**
     * @dev Get latest price for a symbol
     * @param symbol Token symbol
     * @return price Latest price
     * @return timestamp Last update timestamp
     * @return confidence Confidence level
     */
    function getPrice(string memory symbol) 
        external 
        view 
        validSymbol(symbol) 
        returns (uint256 price, uint256 timestamp, uint256 confidence) 
    {
        PriceFeed memory feed = priceFeeds[symbol];
        require(feed.isActive, "Price feed not active");
        require(
            block.timestamp.sub(feed.timestamp) <= PRICE_VALIDITY_PERIOD,
            "Price data stale"
        );
        
        return (feed.price, feed.timestamp, feed.confidence);
    }

    /**
     * @dev Authorize a new oracle node
     * @param node Address of the oracle node
     * @param initialReputation Initial reputation score
     */
    function authorizeNode(address node, uint256 initialReputation) 
        external 
        onlyOwner 
    {
        require(node != address(0), "Invalid node address");
        require(!oracleNodes[node].isAuthorized, "Node already authorized");

        oracleNodes[node] = OracleNode({
            nodeAddress: node,
            reputation: initialReputation,
            lastUpdate: 0,
            isAuthorized: true
        });

        authorizedNodes.push(node);
        emit NodeAuthorized(node, initialReputation);
    }

    /**
     * @dev Deauthorize an oracle node
     * @param node Address of the oracle node
     */
    function deauthorizeNode(address node) external onlyOwner {
        require(oracleNodes[node].isAuthorized, "Node not authorized");
        
        oracleNodes[node].isAuthorized = false;
        
        // Remove from authorized nodes array
        for (uint256 i = 0; i < authorizedNodes.length; i++) {
            if (authorizedNodes[i] == node) {
                authorizedNodes[i] = authorizedNodes[authorizedNodes.length - 1];
                authorizedNodes.pop();
                break;
            }
        }
        
        emit NodeDeauthorized(node);
    }

    /**
     * @dev Get the number of authorized nodes
     * @return Number of authorized oracle nodes
     */
    function getAuthorizedNodesCount() external view returns (uint256) {
        return authorizedNodes.length;
    }

    /**
     * @dev Check if price data is fresh
     * @param symbol Token symbol
     * @return True if price is fresh
     */
    function isPriceFresh(string memory symbol) external view returns (bool) {
        return block.timestamp.sub(priceFeeds[symbol].timestamp) <= PRICE_VALIDITY_PERIOD;
    }

    /**
     * @dev Emergency pause for a price feed
     * @param symbol Token symbol to pause
     */
    function pausePriceFeed(string memory symbol) external onlyOwner {
        priceFeeds[symbol].isActive = false;
    }

    /**
     * @dev Resume a paused price feed
     * @param symbol Token symbol to resume
     */
    function resumePriceFeed(string memory symbol) external onlyOwner {
        priceFeeds[symbol].isActive = true;
    }
}
