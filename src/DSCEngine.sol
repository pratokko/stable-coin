// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Evans Atoko
 *
 * The system is designed to be as minimal as possible & have the tokens maintain 1 token == $1 peg
 * This stablecoin has the properties:
 * -Exogenous Collateral
 * -Dollar pegged
 * -Algorithmic stable
 *
 * It is similar to DAI if DAI had no governance no fees, and was only backed by WETH and WBTC
 *
 * our DSC system should always be "overcollateralized". At no point , should the value of all collateral <= value of $ backed value of all the DSC
 *
 * @notice This contract is the core of the DSC system as it handles all the logic It handles all the minting and redeeming  DSC, as well as well as depositing  & withdrawing collateral
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system
 */

contract DSCEngine is ReentrancyGuard {
    /////////////////
    /////Errors   ///
    /////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    //////////////////////////
    /////State Variables   ///
    //////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /////////////////
    /////Events   ///
    /////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /////////////////
    /////modifiers///
    /////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////
    /////Functions///
    /////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLength();
        }
        // For example ETH / USD BTC / USD

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    /////External Functions  ///
    ////////////////////////////

    /**
     *
     * @param tokenCollateralAddress This is the address of the token to deposit as collateral
     * @param amountCollateral This is the amount of collateral to deposit
     * @param amountDscToMint This is the amount of decentralized stablecoin to mint
     * @notice This function will deposit collateral and mint dsc in one transaction
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @param tokenCollateralAddress The address of the token to deposit the collateral
     * @param amountCollateral the amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of stablecoin to mint
     * @notice they must have more collateral than the minimum threshold
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC, $100 ETH)
        _revertIfhealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function gethealthFactor() external view {}

    ///////////////////////////////////////////
    /////Internal & Private View Functions  ///
    ///////////////////////////////////////////

    function _getAccountInfomation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collaterallValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collaterallValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * This returns how close to liquidation a user is
     *  if user goes below 1 then they can get liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInfomation(user);

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;

        // return (collateralValueInUsd / totalDscMinted);
    }

    // 1. Check health factor ( do they have enough collateral?)
    // 2. revert if they dont have a good  health factor
    function _revertIfhealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////////
    ///// Public & External View Functions  ///
    ///////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token , get the amount they have deposited, and map it to  the price to the the USD value

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // 1 ETH = $1000
        //  The returned value from CL will be 1000 * 1e8

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000 * 1e8 * (1e10)) * 1000 * 1e18
    }
}
