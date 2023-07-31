// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

    //////////////////////////
    /////State Variables   ///
    //////////////////////////

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

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
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    /////External Functions  ///
    ////////////////////////////

    function depositCollateralAndMintDsc() external {}

    /*
     * @param tokenCollateralAddress The address of the token to deposit the collateral
     * @param amountCollateral the amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
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

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function gethealthFactor() external view {}
}
