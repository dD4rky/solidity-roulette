// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Roulette} from "../src/Roulette.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract RouletteTest is Test {
    address public s_coordinatorAddress = 0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625;
    uint256 public s_subId;

    VRFCoordinatorV2_5Mock public s_vrfCoordinatorMock;
    Roulette public s_roulette;

    constructor() {
        s_vrfCoordinatorMock = new VRFCoordinatorV2_5Mock(0.002 ether, 40 gwei, 0.004 ether);

        s_coordinatorAddress = address(s_vrfCoordinatorMock);
        s_subId = s_vrfCoordinatorMock.createSubscription();

        s_roulette = new Roulette(s_coordinatorAddress, s_subId);

        s_vrfCoordinatorMock.fundSubscription(s_subId, 100 ether);
        s_vrfCoordinatorMock.fundSubscriptionWithNative{value: 100 ether}(s_subId);

        s_vrfCoordinatorMock.addConsumer(s_subId, address(s_roulette));
    }

    function testBetLimitAsOwner() public {
        s_roulette.setBetLimit(100);
        assertEq(s_roulette.betLimit(), 100);
    }

    function testBetLimitAsNonOwner() public {
        vm.prank(address(0x123));
        vm.expectRevert();
        s_roulette.setBetLimit(100);
    }

    function testDepositCreditsBalance() public {
        vm.expectEmit(true, false, false, true);
        emit Roulette.Deposited(address(this), 5 ether);
        s_roulette.deposit{value: 5 ether}();

        assertEq(s_roulette.players(address(this)), 5 ether);
    }

    function testDepositRevertsOnZeroValue() public {
        vm.expectRevert(Roulette.zeroDeposit.selector);
        s_roulette.deposit{value: 0}();
    }

    function testBet() public {
        Roulette.BetType betType = Roulette.BetType.Number;
        uint256 betAmount = 1 ether;

        s_roulette.setBetLimit(betAmount);
        s_roulette.deposit{value: betAmount}();
        s_roulette.bet(betType, 1, betAmount);

        assertEq(s_roulette.getPlayerBets(address(this)).length, 1);
        assertEq(s_roulette.players(address(this)), 0); // stake left the balance
    }

    function testBetRevertsWhenInsufficientBalance() public {
        s_roulette.setBetLimit(100);
        s_roulette.deposit{value: 10}();

        vm.expectRevert(abi.encodeWithSelector(Roulette.insufficientBalance.selector, uint256(50), uint256(10)));
        s_roulette.bet(Roulette.BetType.Number, 1, 50);
    }

    function testBetRevertsWhenOverDailyLimit() public {
        s_roulette.setBetLimit(100);
        s_roulette.deposit{value: 200}();

        s_roulette.bet(Roulette.BetType.Number, 1, 60);

        vm.expectRevert(
            abi.encodeWithSelector(Roulette.betExceedsDailyLimit.selector, uint256(60), uint256(50), uint256(100))
        );
        s_roulette.bet(Roulette.BetType.Number, 1, 50);
    }

    function testBetLimitResetsAfterOneDay() public {
        s_roulette.setBetLimit(100);
        s_roulette.deposit{value: 300}();

        s_roulette.bet(Roulette.BetType.Number, 1, 100); // fills the window

        // Still inside the same window: another bet must revert.
        vm.expectRevert();
        s_roulette.bet(Roulette.BetType.Number, 1, 1);

        // A day later the window resets and betting is allowed again.
        vm.warp(block.timestamp + 1 days);
        s_roulette.bet(Roulette.BetType.Number, 1, 100);
        assertEq(s_roulette.getPlayerBets(address(this)).length, 2);
    }

    function testBetAccumulatesWithinWindow() public {
        s_roulette.setBetLimit(100);
        s_roulette.deposit{value: 100}();

        s_roulette.bet(Roulette.BetType.Number, 1, 40);
        s_roulette.bet(Roulette.BetType.Number, 1, 40);

        (uint256 spent,) = s_roulette.dailyLimits(address(this));
        assertEq(spent, 80);
    }

    function testBetRevertsWhenRoundBetLimitReached() public {
        uint256 betAmount = 1;
        uint256 maxBets = s_roulette.MAX_BETS_PER_ROUND();
        s_roulette.setBetLimit(betAmount * (maxBets + 1));
        s_roulette.deposit{value: betAmount * (maxBets + 1)}();

        for (uint256 i = 0; i < maxBets; i++) {
            s_roulette.bet(Roulette.BetType.Number, 1, betAmount);
        }

        // Balance still covers one more bet, so this reverts on the round cap, not balance.
        vm.expectRevert(Roulette.roundBetLimitReached.selector);
        s_roulette.bet(Roulette.BetType.Number, 1, betAmount);
    }

    function testRollRevertsWhenRequestAlreadyPending() public {
        s_roulette.roll();

        vm.expectRevert(Roulette.requestAlreadyPending.selector);
        s_roulette.roll();
    }

    function testRollRequest() public {
        vm.expectEmit(true, false, false, false);
        emit Roulette.RandomRequestSent(1);

        s_roulette.roll();

        assertEq(s_roulette.s_requestId(), 1);
    }

    function testRollRandomResponse() public {
        s_roulette.roll();

        uint256 requestId = s_roulette.s_requestId();
        s_vrfCoordinatorMock.fulfillRandomWords(requestId, address(s_roulette));

        assertGe(s_roulette.s_roulleteNumber(), 0);
    }

    function testProcessBetsPaysWinnerAndClearsBets() public {
        uint256 betAmount = 1 ether;
        s_roulette.setBetLimit(betAmount * 2);
        s_roulette.deposit{value: betAmount * 2}();
        s_roulette.bet(Roulette.BetType.Number, 0, betAmount);
        s_roulette.bet(Roulette.BetType.Color, 1, betAmount); // Black, loses when 0 hits

        s_roulette.roll();
        uint256 requestId = s_roulette.s_requestId();

        uint256[] memory words = new uint256[](1);
        words[0] = 0; // winning number = 0 % 38 = 0
        s_vrfCoordinatorMock.fulfillRandomWordsWithOverride(requestId, address(s_roulette), words);

        assertEq(s_roulette.s_roulleteNumber(), 0);
        // Both stakes were deducted at bet time (balance 0); only the Number bet pays back, 36x.
        assertEq(s_roulette.players(address(this)), betAmount * s_roulette.NUMBER_PAYOUT());
        assertEq(s_roulette.getPlayerBets(address(this)).length, 0);
    }

    function testWithdrawPaysOutAndResetsBalance() public {
        address player = address(0xBEEF);
        vm.deal(player, 100 ether);

        uint256 betAmount = 1 ether;
        s_roulette.setBetLimit(betAmount * 2);

        // House reserve first: a 36x Number payout exceeds the player's own deposit.
        // vm.deal sets the contract's ETH outright, so it must precede the deposit.
        vm.deal(address(s_roulette), 40 ether);

        vm.prank(player);
        s_roulette.deposit{value: betAmount}();
        vm.prank(player);
        s_roulette.bet(Roulette.BetType.Number, 0, betAmount);

        s_roulette.roll();
        uint256 requestId = s_roulette.s_requestId();

        uint256[] memory words = new uint256[](1);
        words[0] = 0; // winning number = 0
        s_vrfCoordinatorMock.fulfillRandomWordsWithOverride(requestId, address(s_roulette), words);

        uint256 expectedPayout = betAmount * s_roulette.NUMBER_PAYOUT();
        uint256 balanceBefore = player.balance;

        vm.expectEmit(true, false, false, true);
        emit Roulette.Withdrawn(player, expectedPayout);

        vm.prank(player);
        s_roulette.withdraw();

        assertEq(player.balance, balanceBefore + expectedPayout);
        assertEq(s_roulette.players(player), 0);
    }

    function testWithdrawRevertsWhenBalanceZero() public {
        vm.expectRevert(Roulette.balanceEqualZero.selector);
        s_roulette.withdraw();
    }

    function testWithdrawRevertsWhenRecipientRejectsEth() public {
        RejectingReceiver rejecting = new RejectingReceiver(s_roulette);
        vm.deal(address(rejecting), 50 ether);

        uint256 betAmount = 1 ether;
        s_roulette.setBetLimit(betAmount * 2);

        // House reserve before the deposit (see note in testWithdrawPaysOutAndResetsBalance).
        vm.deal(address(s_roulette), 40 ether);

        rejecting.deposit(betAmount);
        rejecting.placeBet(Roulette.BetType.Number, 0, betAmount);

        s_roulette.roll();
        uint256 requestId = s_roulette.s_requestId();

        uint256[] memory words = new uint256[](1);
        words[0] = 0; // winning number = 0
        s_vrfCoordinatorMock.fulfillRandomWordsWithOverride(requestId, address(s_roulette), words);

        vm.expectRevert(Roulette.withdrawFailed.selector);
        rejecting.callWithdraw();
    }

    // Winning number used below: 15 -> dozen 1 (13-24), row 4 (13,14,15), black, odd, low (1-18).
    // Bets are split across multiple small rounds (2 bets each) rather than one big round.
    // No house top-up is needed: each stake is deducted from the player's deposited balance
    // at bet time, so the payout assertions read the net credited back after settlement.

    function testSectorAndRowBetsPayCorrectly() public {
        uint256 betAmount = 1 ether;
        s_roulette.setBetLimit(betAmount * 2);
        s_roulette.deposit{value: betAmount * 2}();

        s_roulette.bet(Roulette.BetType.Sector, 1, betAmount); // wins: 3x
        s_roulette.bet(Roulette.BetType.Row, 4, betAmount); // wins: 12x

        s_roulette.roll();
        uint256 requestId = s_roulette.s_requestId();
        uint256[] memory words = new uint256[](1);
        words[0] = 15;
        s_vrfCoordinatorMock.fulfillRandomWordsWithOverride(requestId, address(s_roulette), words);

        assertEq(s_roulette.s_roulleteNumber(), 15);
        assertEq(s_roulette.players(address(this)), betAmount * (s_roulette.SECTOR_PAYOUT() + s_roulette.ROW_PAYOUT()));
        assertEq(s_roulette.getPlayerBets(address(this)).length, 0);
    }

    function testColorAndOddEvenBetsPayCorrectly() public {
        uint256 betAmount = 1 ether;
        s_roulette.setBetLimit(betAmount * 2);
        s_roulette.deposit{value: betAmount * 2}();

        s_roulette.bet(Roulette.BetType.Color, 1, betAmount); // Black, wins: 2x
        s_roulette.bet(Roulette.BetType.OddEven, 1, betAmount); // Odd, wins: 2x

        s_roulette.roll();
        uint256 requestId = s_roulette.s_requestId();
        uint256[] memory words = new uint256[](1);
        words[0] = 15;
        s_vrfCoordinatorMock.fulfillRandomWordsWithOverride(requestId, address(s_roulette), words);

        assertEq(s_roulette.s_roulleteNumber(), 15);
        assertEq(s_roulette.players(address(this)), betAmount * s_roulette.EVEN_MONEY_PAYOUT() * 2);
        assertEq(s_roulette.getPlayerBets(address(this)).length, 0);
    }

    function testHighLowBetsWinAndLoseCorrectly() public {
        uint256 betAmount = 1 ether;
        s_roulette.setBetLimit(betAmount * 2);
        s_roulette.deposit{value: betAmount * 2}();

        s_roulette.bet(Roulette.BetType.HighLow, 0, betAmount); // Low, wins: 2x
        s_roulette.bet(Roulette.BetType.HighLow, 1, betAmount); // High, loses: 0

        s_roulette.roll();
        uint256 requestId = s_roulette.s_requestId();
        uint256[] memory words = new uint256[](1);
        words[0] = 15;
        s_vrfCoordinatorMock.fulfillRandomWordsWithOverride(requestId, address(s_roulette), words);

        assertEq(s_roulette.s_roulleteNumber(), 15);
        assertEq(s_roulette.players(address(this)), betAmount * s_roulette.EVEN_MONEY_PAYOUT());
        assertEq(s_roulette.getPlayerBets(address(this)).length, 0);
    }

    // MAX_BETS_PER_ROUND + the higher callbackGasLimit are what fix the gas-exhaustion DoS
    // that used to strand every bet once too many accumulated in one round (a full round
    // used to run the VRF callback out of gas partway through settlement). This confirms a
    // full round now settles correctly, and testBetRevertsWhenRoundBetLimitReached confirms
    // the round can never grow past what that budget was sized for.
    function testProcessBetsSettlesFullRoundWithinGasBudget() public {
        uint256 betAmount = 1 ether;
        uint256 maxBets = s_roulette.MAX_BETS_PER_ROUND();
        s_roulette.setBetLimit(betAmount * maxBets);
        s_roulette.deposit{value: betAmount * maxBets}();

        // Alternate Odd/Even so half the bets win against winningNumber = 15 (odd); winners'
        // 2x payouts are exactly covered by what all maxBets wagers contribute, no top-up needed.
        for (uint256 i = 0; i < maxBets; i++) {
            uint8 number = i % 2 == 0 ? uint8(1) : uint8(0);
            s_roulette.bet(Roulette.BetType.OddEven, number, betAmount);
        }

        s_roulette.roll();
        uint256 requestId = s_roulette.s_requestId();
        uint256[] memory words = new uint256[](1);
        words[0] = 15;
        s_vrfCoordinatorMock.fulfillRandomWordsWithOverride(requestId, address(s_roulette), words);

        assertEq(s_roulette.s_roulleteNumber(), 15);
        assertEq(s_roulette.getPlayerBets(address(this)).length, 0);

        uint256 winningBets = (maxBets + 1) / 2;
        assertEq(s_roulette.players(address(this)), betAmount * s_roulette.EVEN_MONEY_PAYOUT() * winningBets);
    }

    // 0 and 00 (37) only pay straight Number bets; every outside bet loses on them.
    function testDoubleZeroWinsStraightNumberButLosesOutsideBets() public {
        uint256 betAmount = 1 ether;
        s_roulette.setBetLimit(betAmount * 2);
        s_roulette.deposit{value: betAmount * 2}();

        s_roulette.bet(Roulette.BetType.Number, 37, betAmount); // straight bet on 00
        s_roulette.bet(Roulette.BetType.OddEven, 1, betAmount); // Odd, loses on 00

        s_roulette.roll();
        uint256 requestId = s_roulette.s_requestId();

        uint256[] memory words = new uint256[](1);
        words[0] = 37;
        s_vrfCoordinatorMock.fulfillRandomWordsWithOverride(requestId, address(s_roulette), words);

        assertEq(s_roulette.s_roulleteNumber(), 37);
        assertEq(s_roulette.players(address(this)), betAmount * s_roulette.NUMBER_PAYOUT());
    }
}

contract RejectingReceiver {
    Roulette public roulette;

    constructor(Roulette _roulette) {
        roulette = _roulette;
    }

    function deposit(uint256 value) external {
        roulette.deposit{value: value}();
    }

    function placeBet(Roulette.BetType betType, uint8 number, uint256 amount) external {
        roulette.bet(betType, number, amount);
    }

    function callWithdraw() external {
        roulette.withdraw();
    }
}
