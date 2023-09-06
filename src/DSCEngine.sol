// SPDX-License Identifiers :  MIT

// Layout of Contract:
//version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// state variables
// Events
// Modifiers
// Functions


// Layout of Functions:
// contructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view &  pure functions


pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/**
* @title DSCEngine
* @author Scoolj, Oluwajuwonlo
* 
*  The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
*  This stablecoin has the properties:
*   - Exogenous Collateral
*   - Dollar Pegged
*   - Algoritmically Stable
* 
* It is similar to DAI if DAI has no governance, no fees, and was only backed by WETH and WBTH.
*
* 
* Our DSC system should always be "overcollaterlized". At no poin , should the value of all collateral <= the $ backed value of all the DSC.
* @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
* @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.

 */
    // The system Threshold for example is 150%
    // You deposited $100 ETH Collateral ->  minted $50 worth of DSC -> means that your collateral is $75
    // if the value of your collateral goes down to $74  'UNDERCOLLATERALIZED!!!'
    // another user from the system can make money of it,
    // by returning the $50 worth of DSC you minted
    // the system automatically credit him/her with your current value of collateral which is $74
    // so, your collateral is now $0 and the user makes extra $24
    // 

 contract DSCEngine is ReentrancyGuard {
    /////////////////////
    ///  Errors  //// ///
    ///////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__mintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////
    ////  Type ////
    //////////////
    
    using OracleLib for AggregatorV3Interface;

    
     ////////////////////////
    ///  State Variables ////
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //this means a 10 bonus
    




    mapping(address token => address priceFeed) private s_priceFeeds;
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;

    address[] private s_collateralTokens;



     ///////////////////
    ///  Events   ////
    /////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

    event CollateralRedeemed(address indexed redeemedFrom,  address indexed redeemedTo, address indexed token, uint256 amount);


    /////////////////////
    /// Modifiers    ///
    ///////////////////

    modifier moreThanZero(uint256 amount){
        if(amount == 0){
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;

    }

    modifier isAllowedToken(address token){
        if(s_priceFeeds[token] == address(0)){
            revert DSCEngine__NotAllowedToken();                                     
        }
        _;
    }

      /////////////////////
    /// Functions   ///
    ///////////////////
    constructor( address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress ) {
        // USD Price Feeds
        if(_tokenAddresses.length != _priceFeedAddresses.length){
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH / USD , BTC/USD,  MKR/USD etc.
        for(uint256 i =0; i < _tokenAddresses.length;  i++){
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(_dscAddress);
       
    }


    /////////////////////////////
    /// External Functions  ////
    ////////////////////////////

    /**
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice this function will deposit your collateral and mint DSC in one transaction
     */

    function depositionCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }


    /**
    * @notice Follows CEI -Check Effect Interactions pattern
    *   @param tokenCollateralAddress  the addresss of the token to deposit as collateral
    *   @param amountCollateral The amount of collateral to deposit 
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant{
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
    }

    /**
    * @param _tokenCollateralAddress The collateral address to redeem
    * @param _amountCollateral The amount of collateral to redeem
    * @param _amountDscToBurn The amount of DSC to burn
    * This function burns DSC and redeems underlying collateral in on transaction
     */
    function redeemCollateralForDsc(address _tokenCollateralAddress, uint256 _amountCollateral, uint256 _amountDscToBurn) external {
        burnDsc(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
        // redeemCollateral already checks health factor 
    }


    // in order to redeem collateral:
    // 1.  health factor must be over 1 AFTER collateral pulled
    // DRY: Don't repeat yourself 
    // CEI:  Check, Effects, Interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
    * @notice follows CEI
    *  @param amountDscToMint The amount of decentralized stablecoin to mint
    *  @notice They must have more collateral value than the minimum threshold

     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {

        //
        _revertIfHealthFactorIsBroken(msg.sender); 
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine__mintFailed();
        }

    }

    function burnDsc(uint256 _amount) public moreThanZero(_amount) {
         _burnDsc(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I dont think this would ever hit
    }

    /**
    * @param _collateral The erc20 collateral addresss to liquidate from the user
    *  @param _user The user who has broken the health factor.  Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param _debtToCover The amount of DSC you want  to burn to improve users health factor
    * @notice you can partially liquidate a user.
    * @notice you will get a liquidation bonus for taking the users funds
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.

    * @notice A know bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
    * For example . if the price of the collateral plummeted before anyone could be liquidated.
    * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address _collateral, address _user,  uint256 _debtToCover)  external moreThanZero(_debtToCover) nonReentrant{

        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(_user);

        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }

        // We want to burn their DSC "debt"
        // And take their collateral 
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC == ?? ETH? 
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(_collateral, _debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of Eth for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury. 
        // 0.05 * 0.1 = 0.005. Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS)/LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(_user, msg.sender, _collateral, totalCollateralToRedeem);
        _burnDsc(_debtToCover, _user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(_user);

        if(endingUserHealthFactor <= startingUserHealthFactor ){
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // function getHealthFactor() external view {}

     ///////////////////////////////////////
    /// Private & Internal Functions  /////
    ///////////////////////////////////////

    /**
    * @dev Low-level internal function , do not call unless the funciton calling it is checking the health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom ) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);


    }
    
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
         
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to , tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to , amountCollateral);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        
    }

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){

        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd =  getAccountCollateralValue(user);

    }
  
    /**
    * Returns how close to liquidation a user is
    * if a user goes below 1, then they can get liquidated
    *
    */

    function _healthFactor(address user) private view returns(uint256){  // faiiling test
        // total DSC minted 
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        // 100ETH *  50 = 50,000 /100 =  500
        // $150 ETH/ 100 = (75/100) < 1 

        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);

    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns(uint256) {
        if(totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD)/ LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * 1e18)/ totalDscMinted;
    }

    // 1.  Check health factor (do they have enough collateral?)
    // 2.  Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view { 
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }

    }

    ///////////////////////////////////////
    /// Public & External View Functions //
    ///////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external pure returns (uint256){    
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address _token, uint256 _usdAmountInWei) public view returns(uint256){
        // price of ETH (token)
        // $/ETH ETH ??
        // $2000 /ETH . $1000 = 0.5ETH

        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.staleCheckLastestRoundData();
        // (, int256 price,,,) = priceFeed.staleCheckLastestRoundData();

        // ($10e18 * 1e18) /($2000e8 * 1e10)
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return(_usdAmountInWei * PRECISION)/(uint256(price) * ADDITIONAL_FEED_PRECISION); 
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value.

        for(uint256 i =0;  i < s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price ,,,) = priceFeed.staleCheckLastestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount)/PRECISION;
    }


    function getAccountInformation(address _user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
         (totalDscMinted, collateralValueInUsd) = _getAccountInformation(_user);
    }

     function getPrecision() external pure returns (uint256){
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns(uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns(uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {   // test failing
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory){
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns(address){
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns(uint256){    // test failing
        return _healthFactor(user); 
    }

    // function getRedeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) external view returns()
    function getCollateralBalanceOfUser(address user, address token) external view  returns(uint256){
        return s_collateralDeposited[user][token];
    }

 }