//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.t.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.t.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.t.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
contract DSCEngineTest is Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemTo, then it was liquidated

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;


    address public USER =  makeAddr("user");
   //  address public USER =  address(1);
    uint256 amountToMint = 100 ether;

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE =  10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed,btcUsdPriceFeed , weth, ,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);

    }


     /////////////////////////////
    /// Constructor Tests ///////
    ////////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;


    function testRevertIfTokenLengthDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////////////////
    /// Price Tests //////////////
    ////////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount =  15e18;
        // 15e18 * 2000/ETH = 30,000318;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);

    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth =0.05 ether;
        uint256 actualWeth =  dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

     ////////////////////////////////
    /// depositCollateral Tests ////   
    ////////////////////////////////

    function testRevertsIfTransferFromFails() public {
        // Arrnage - setup

        // address owner = msg.sender
        // vm.prank(owner);
        // Moc
    }

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startBroadcast(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopBroadcast();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral(){
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256  expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    // function testCanRedeemCollateral() public depositedCollateral {
    //     // vm.startPrank(USER);
    //     dsce.redeemCollateral(USER, AMOUNT_COLLATERAL);
    //     assert(true);
    //     //how do i know the user have redeemed it collateral
    // }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd ) = dsce.getAccountInformation(USER);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

     //////////////////////////////////////////
    /// depositCollateralAndMintDsc Tests ////   
    //////////////////////////////////////////

    function testRevertsIfMintedDscBreakHealthFactor() public {
        (, int256 price ,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint =  (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())/dsce.getPrecision());
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor = dsce. calculateHealthFactor( amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL ));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor));
        dsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
     }

     modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
     }


     function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
     }


       ////////////////////////////////
      ////// mintDsc tests ///////////
     ////////////////////////////////

     // This test needs it's own custom setup

     function testRevertsIfMintFails() public {
        // Arrange - Setup

        MockFailedMintDSC mockDsc = new  MockFailedMintDSC();
        tokenAddresses  = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );

        mockDsc.transferOwnership(address(mockDsce));

        /// Arrange  -USer

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__mintFailed.selector);
        mockDsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();


     }

     function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();        
     }

     function testRevertsIfMintAmountBreaksHealthFactor() public {
        (, int256 price ,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor = dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor ));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
     }


     function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(USER);

        assertEq(userBalance, amountToMint);
        
     }


     //////////////////////////////////////
     /// BurnDsc Tests ///////////////////
     ////////////////////////////////////

     function testRevertIfBurnAmountIsZero() public{
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
     }


     function testCantBurnMoreThankUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
     }

     function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance =  dsc.balanceOf(USER);
        console.log("BURN DSC: ", userBalance);
        assertEq(userBalance, 0);
     }


     //////////////////////////////////
     /// redeemCollateral Tests /////
     ////////////////////////////////

     //  this test needs it's own setup

     function testRevertsIfTransferFails() public {
        // Arrange - Setup

        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce =  new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));

        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        // Arrange - User

        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);

        //Act / ASSERT
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();

     }

     function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
     }

     function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance,AMOUNT_COLLATERAL);
        vm.stopPrank();
     }


     function testEmitCollateralRedeemWithCorrectArgs() public depositedCollateral {
      vm.expectEmit(true, true, true, true, address(dsce));
      emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
      vm.startPrank(USER);
      dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
      vm.stopPrank();
     }


     /////////////////////////////////////////////
     /// redeemCollateralForDsc Test ////////////
     ///////////////////////////////////////////


    //test fail
     function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
     }

  
     function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
     }


     ////////////////////////
     // healthFactor Tests //
     /////////////////////////

     function testProperlyReportHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collateral at all times
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor

        assertEq(healthFactor, expectedHealthFactor);

     }

     function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
         int256 ethUsdUpdatedPrice = 18e8; // 1 Eth = $18
         // Remember , we need $150 at all time if we have $1000 of debt

          MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

          uint256 userHealthFactor = dsce.getHealthFactor(USER);
          console.log("USERRRRRR: ", USER);
          console.log("HEalther factor: ", userHealthFactor);
          // $180 collateral / 200 debt = 0.9

          assert(userHealthFactor == 0.9 ether);
     }


     ////////////////////////////
     /// Liquidation Tests /////
     //////////////////////////


     // This test needs it's own setup
     function testMustImproveHealthFactorOnLiquidation() public {
      // Arrange - setup
      MockMoreDebtDSC mockDsc =  new MockMoreDebtDSC(ethUsdPriceFeed);
      tokenAddresses =  [weth];
      priceFeedAddresses =  [ethUsdPriceFeed];
      address owner = msg.sender;
      vm.prank(owner);

      DSCEngine mockDsce  =  new DSCEngine(
         tokenAddresses,
         priceFeedAddresses,
         address(mockDsc)
      );

      mockDsc.transferOwnership(address(mockDsce));

      // Arrange - USer

      vm.startPrank(USER);
      ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
      mockDsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
      vm.stopPrank();

      // Arrange - Liquidator

      collateralToCover = 1 ether;
      ERC20Mock(weth).mint(liquidator, collateralToCover);

      vm.startPrank(liquidator);
      ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
      uint256 debtToCover = 10 ether;

      mockDsce.depositionCollateralAndMintDsc(weth, collateralToCover, amountToMint);
      mockDsc.approve(address(mockDsce), debtToCover);

      //act
      int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
      MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

      // Act/Assert
      vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
      mockDsce.liquidate(weth, USER, debtToCover);
      vm.stopPrank();
   }

   function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
      ERC20Mock(weth).mint(liquidator, collateralToCover);

      vm.startPrank(liquidator);
      ERC20Mock(weth).approve(address(dsce), collateralToCover);
      dsce.depositionCollateralAndMintDsc(weth, collateralToCover, amountToMint);
      dsc.approve(address(dsce), amountToMint);

      vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
      dsce.liquidate(weth, USER, amountToMint);
      vm.stopPrank();
   }


   modifier liquidated() {
      vm.startPrank(USER);
      ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
      dsce.depositionCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
      vm.stopPrank();
      int256 ethUsdUpdatedPrice = 18e8; //  1 ETH = $18

      MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
      uint256 userHealthFactor = dsce.getHealthFactor(USER);

      ERC20Mock(weth).mint(liquidator, collateralToCover);

      vm.startPrank(liquidator);
      ERC20Mock(weth).approve(address(dsce), collateralToCover);
      dsce.depositionCollateralAndMintDsc(weth, collateralToCover, amountToMint);
      dsc.approve(address(dsce), amountToMint);
      dsce.liquidate(weth, USER, amountToMint); // we are covering their whole debt
      vm.stopPrank();
      _;
   }


   function testLiquidationPayoutIsCorrect() public liquidated {
      uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
      uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint) + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());

      uint256 hardCodedExpected = 6111111111111111110;
      assertEq(liquidatorWethBalance, hardCodedExpected);
      assertEq(liquidatorWethBalance, expectedWeth);
   }


   function testUserStillHasSomeEthAfterLiquidation() public liquidated {
      //Get how much WETH the user lost

      uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint) + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());

      uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
      uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth,  AMOUNT_COLLATERAL) - (usdAmountLiquidated);

      (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(USER);
      console.log("UserCollateral: ", userCollateralValueInUsd);
      uint256 hardCodedExpectedValue = 70000000000000000020;
      assertEq(expectedUserCollateralValueInUsd, userCollateralValueInUsd);
      assertEq(expectedUserCollateralValueInUsd, hardCodedExpectedValue);
   
   }

   function testLiquidatorTakesOnUserDebt() public liquidated {
      (uint256 liquidatorDscMinted, ) = dsce.getAccountInformation(liquidator);
      assertEq(liquidatorDscMinted, amountToMint);
   }

   function testUserhasNoMoreDebt() public liquidated {
      (uint256 userDscMinted, ) = dsce.getAccountInformation(USER);
      assertEq(userDscMinted, 0);
   }

       ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////


    function testGetCollateralTokenPriceFeed() public {
      address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
      assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
      address[]  memory collateralTokens = dsce.getCollateralTokens();
      assertEq(collateralTokens[0], weth);
    }

   function testGetMinHealthFactor() public {
     uint256 minHealthFactor = dsce.getMinHealthFactor();
     assertEq(minHealthFactor, MIN_HEALTH_FACTOR); 
   }

   function testGetLiquidationThreshold() public {
      uint256 liquidationThreshold = dsce.getLiquidationThreshold();
      assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
   }

   
   function testGetAccountCollateralValueFromInformation() public depositedCollateral {
      (, uint256 collateralValue) = dsce.getAccountInformation(USER);
      uint256 expectedCollateralValue =  dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
      assertEq(collateralValue, expectedCollateralValue);
   }

   function testGetCollateralBalanceOfUser() public {
      vm.startPrank(USER);
      ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
      dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
      vm.stopPrank();
      uint256 collateralBalance = dsce.getCollateralBalanceOfUser(USER, weth);

      assertEq(collateralBalance, AMOUNT_COLLATERAL);
   }


   function testGetAccountCollateralValue() public {

      vm.startPrank(USER);

      ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
      dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
      vm.stopPrank();
      uint256 collateralValue = dsce.getAccountCollateralValue(USER);
      uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
      assertEq(collateralValue, expectedCollateralValue);
   }


   function testGetDsc() public {
      address dscAddress = dsce.getDsc();
      assertEq(dscAddress, address(dsc));
   }








}
