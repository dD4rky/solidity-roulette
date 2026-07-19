// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title Roulette
/// @notice An American-roulette (38-pocket: 0, 00, 1-36) betting game whose spins are
///         resolved with Chainlink VRF v2.5 for provably fair randomness.
/// @dev Players fund an internal balance with {deposit}, place bets with {bet} (stake is
///      debited immediately), and trigger a spin with {roll}. When the VRF coordinator
///      calls {fulfillRandomWords} back, every pending bet across all players is settled
///      against the single winning pocket and winnings are credited to balances, which are
///      cashed out with {withdraw}. Winning payouts can exceed the deposits backing a round,
///      so the house is expected to keep a reserve of ETH in the contract (see {receive}).
contract Roulette is VRFConsumerBaseV2Plus {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lifecycle of the outstanding VRF request.
    /// @dev `Fulfilled` is value 0 so it doubles as the idle default before the first roll;
    ///      {roll} keys its "already pending" guard off `Pending`.
    enum RandomRequestStatus {
        Fulfilled,
        Pending,
        Failed
    }

    /// @notice The kind of wager a bet represents. The meaning of `Bet.number` depends on it:
    ///         - Number:  the straight-up pocket 0-37 (37 = 00), pays 35:1
    ///         - Sector:  dozen 0/1/2 (1-12 / 13-24 / 25-36), pays 2:1
    ///         - Row:     street 0-11 (three consecutive numbers), pays 11:1
    ///         - Color:   0 = Red, 1 = Black, pays 1:1
    ///         - OddEven:  0 = Even, 1 = Odd, pays 1:1
    ///         - HighLow: 0 = Low (1-18), 1 = High (19-36), pays 1:1
    enum BetType {
        Number,
        Sector,
        Row,
        Color,
        OddEven,
        HighLow
    }

    /// @notice A player's on-contract account.
    /// @param balance Withdrawable balance in wei (deposits, un-staked funds and winnings).
    /// @param bets    Bets placed in the current round, cleared once the round is settled.
    struct Player {
        uint256 balance;
        Bet[] bets;
    }

    /// @notice A single wager awaiting settlement.
    /// @param amount  Staked amount in wei, already debited from the player's balance.
    /// @param number  The selection, interpreted according to `betType` (see {BetType}).
    /// @param betType The kind of wager.
    struct Bet {
        uint256 amount;
        uint8 number;
        BetType betType;
    }

    /// @notice Per-player rolling wager total used to enforce {betLimit}.
    /// @param spent       Amount wagered within the current window.
    /// @param windowStart Timestamp the current window opened.
    struct DailyLimit {
        uint256 spent;
        uint256 windowStart;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Payout multiplier for a straight-up Number bet (35:1 winnings + returned stake).
    uint256 public constant NUMBER_PAYOUT = 36;
    /// @notice Payout multiplier for a Sector (dozen) bet (2:1 + stake).
    uint256 public constant SECTOR_PAYOUT = 3;
    /// @notice Payout multiplier for a Row (street) bet (11:1 + stake).
    uint256 public constant ROW_PAYOUT = 12;
    /// @notice Payout multiplier for an even-money Color/OddEven/HighLow bet (1:1 + stake).
    uint256 public constant EVEN_MONEY_PAYOUT = 2;

    /// @dev Bit i set => pocket i is Black; a winning Black pocket is the "1" side of a Color
    ///      bet. Bit-testing this (and the two masks below) replaces three near-identical
    ///      branches in {_calculatePayout} with one shared lookup.
    uint64 private constant BLACK_NUMBERS_MASK = (1 << 2) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 11)
        | (1 << 13) | (1 << 15) | (1 << 17) | (1 << 20) | (1 << 22) | (1 << 24) | (1 << 26) | (1 << 28) | (1 << 29)
        | (1 << 31) | (1 << 33) | (1 << 35);
    /// @dev Bit i set => pocket i is Odd (the "1" side of an OddEven bet).
    uint64 private constant ODD_NUMBERS_MASK = (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11)
        | (1 << 13) | (1 << 15) | (1 << 17) | (1 << 19) | (1 << 21) | (1 << 23) | (1 << 25) | (1 << 27) | (1 << 29)
        | (1 << 31) | (1 << 33) | (1 << 35);
    
    /// @dev Bit i set => pocket i is High (19-36, the "1" side of a HighLow bet): 18
    ///      consecutive bits starting at position 19.
    uint64 private constant HIGH_NUMBERS_MASK = ((uint64(1) << 18) - 1) << 19;

    /// @notice Duration of a bet-limit window; a player's wagered total resets once it elapses.
    uint256 public constant LIMIT_PERIOD = 1 days;

    /// @notice Maximum number of bets that may be pending settlement in a single round.
    /// @dev Bounds the {_processBets} loop so it is guaranteed to finish within
    ///      {callbackGasLimit} regardless of how many players/bets show up.
    uint256 public constant MAX_BETS_PER_ROUND = 10;

    /// @notice Number of random words requested per spin.
    uint32 public constant WORDS_COUNT = 1;

    /// @notice Maximum total a single player may wager within one {LIMIT_PERIOD} window.
    uint256 public betLimit = 1_000_000;

    /// @notice Count of bets currently pending settlement, capped by {MAX_BETS_PER_ROUND}.
    uint256 public activeBetsCount;

    /// @notice Winning pocket of the most recent settled spin (0-37, where 37 represents 00).
    uint8 public s_roulleteNumber;

    /// @notice Per-player account (balance and current-round bets).
    mapping(address => Player) public players;

    /// @notice Per-player rolling wager total for {betLimit} enforcement.
    mapping(address => DailyLimit) public dailyLimits;

    /// @notice Addresses with unresolved bets, iterated once per spin during settlement.
    /// @dev A player is "active" exactly when players[addr].bets.length > 0, so no separate
    ///      flag is stored; this array only needs to enumerate them.
    address[] public activePlayers;

    /// @notice Chainlink VRF v2.5 subscription id that funds randomness requests.
    uint256 public s_subscriptionId;

    /// @notice VRF key hash (gas lane) used for requests. Defaults to the Sepolia 500 gwei lane.
    bytes32 public keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    /// @notice Gas forwarded to {fulfillRandomWords} by the coordinator.
    /// @dev Sized with headroom over MAX_BETS_PER_ROUND * (worst-case per-bet settlement cost).
    uint32 public callbackGasLimit = 300_000;

    /// @notice Status of the outstanding VRF request; also gates concurrent {roll} calls.
    RandomRequestStatus internal s_requestStatus;

    /// @notice Id of the most recent VRF request.
    uint256 public s_requestId;

    /// @notice Raw random word delivered by the most recent fulfillment.
    uint256 public s_randomWord;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a randomness request is sent to the VRF coordinator.
    /// @param requestId Id of the VRF request.
    event RandomRequestSent(uint256 indexed requestId);

    /// @notice Emitted when the VRF coordinator fulfills a randomness request.
    /// @param requestId   Id of the fulfilled request.
    /// @param randomWords Random words returned by the coordinator.
    event RandomRequestFulfilled(uint256 indexed requestId, uint256[] randomWords);

    /// @notice Emitted when a player places a bet.
    /// @param player  Address that placed the bet.
    /// @param betType Kind of wager.
    /// @param number  Selection, interpreted per `betType`.
    /// @param amount  Staked amount in wei.
    event PlayerBet(address indexed player, BetType betType, uint8 number, uint256 amount);

    /// @notice Emitted for each bet settled during a spin (payout is 0 for a loss).
    /// @param player  Address that owned the bet.
    /// @param betType Kind of wager.
    /// @param number  Selection, interpreted per `betType`.
    /// @param amount  Staked amount in wei.
    /// @param payout  Amount credited back to the player's balance (stake included), 0 on a loss.
    event BetResolved(address indexed player, BetType betType, uint8 number, uint256 amount, uint256 payout);

    /// @notice Emitted when the owner changes the per-window bet limit.
    /// @param betLimit New limit.
    event BetLimitUpdated(uint256 betLimit);

    /// @notice Emitted when a player funds their balance.
    /// @param player Depositing address.
    /// @param amount Amount deposited in wei.
    event Deposited(address indexed player, uint256 amount);

    /// @notice Emitted when a player cashes out their balance.
    /// @param player Withdrawing address.
    /// @param amount Amount withdrawn in wei.
    event Withdrawn(address indexed player, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when {withdraw} is called with a zero balance.
    error balanceEqualZero();

    /// @notice Thrown when a bet would push the player past {betLimit} for the current window.
    /// @param spent  Already wagered in the window.
    /// @param amount Attempted wager.
    /// @param limit  The active {betLimit}.
    error betExceedsDailyLimit(uint256 spent, uint256 amount, uint256 limit);

    /// @notice Thrown when the ETH transfer in {withdraw} fails.
    error withdrawFailed();

    /// @notice Thrown when {deposit} is called with zero value.
    error zeroDeposit();

    /// @notice Thrown when a bet exceeds the player's available balance.
    /// @param requested Attempted stake.
    /// @param available Player's current balance.
    error insufficientBalance(uint256 requested, uint256 available);

    /// @notice Thrown when a bet would exceed {MAX_BETS_PER_ROUND} for the current round.
    error roundBetLimitReached();

    /// @notice Thrown when {roll} is called while a VRF request is still pending.
    error requestAlreadyPending();

    /// @notice Thrown when a fulfillment arrives for an id other than the outstanding one.
    /// @param expected The outstanding request id.
    /// @param actual   The id supplied by the fulfillment.
    error unexpectedRequestId(uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enforces the rolling per-window {betLimit} and records the wager toward it.
    /// @dev Lazily rolls the window forward when {LIMIT_PERIOD} has elapsed, then reverts with
    ///      {betExceedsDailyLimit} if the new total would exceed {betLimit}.
    /// @param amount Wager being attempted.
    modifier betLessLimit(uint256 amount) {
        DailyLimit storage dailyLimit = dailyLimits[msg.sender];

        // Reset the window once a day has passed since it opened.
        if (block.timestamp >= dailyLimit.windowStart + LIMIT_PERIOD) {
            dailyLimit.windowStart = block.timestamp;
            dailyLimit.spent = 0;
        }

        if (dailyLimit.spent + amount > betLimit) {
            revert betExceedsDailyLimit(dailyLimit.spent, amount, betLimit);
        }

        dailyLimit.spent += amount;
        _;
    }

    /// @notice Reverts with {balanceEqualZero} unless the caller has a positive balance.
    modifier balanceNotZero() {
        if (players[msg.sender].balance == 0) {
            revert balanceEqualZero();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the game bound to a VRF coordinator and subscription.
    /// @param _coordinatorAddress Address of the Chainlink VRF v2.5 coordinator.
    /// @param _subscriptionId     VRF subscription id that will pay for requests; the deployed
    ///                            contract must be added to it as a consumer before {roll} works.
    constructor(address _coordinatorAddress, uint256 _subscriptionId) VRFConsumerBaseV2Plus(_coordinatorAddress) {
        s_subscriptionId = _subscriptionId;
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Accepts ETH to top up the house payout reserve without crediting any player.
    /// @dev A winning round can owe more than the deposits backing it (a 35:1 straight-up
    ///      Number bet alone pays 36x its stake). Players must use {deposit} instead.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the per-window wager limit. Owner only.
    /// @param _betLimit New maximum a single player may wager within one {LIMIT_PERIOD}.
    function setBetLimit(uint256 _betLimit) external onlyOwner {
        betLimit = _betLimit;
        emit BetLimitUpdated(_betLimit);
    }

    /// @notice Funds the caller's internal balance, from which bets are drawn and into which
    ///         winnings are paid.
    /// @dev Reverts with {zeroDeposit} on a zero-value call.
    function deposit() external payable {
        if (msg.value == 0) {
            revert zeroDeposit();
        }

        players[msg.sender].balance += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Places a bet for the current round, debiting the stake from the caller's balance.
    /// @dev Reverts with {insufficientBalance} if the stake exceeds the balance,
    ///      {roundBetLimitReached} if the round is full, or {betExceedsDailyLimit} (via the
    ///      {betLessLimit} modifier) if the window limit would be exceeded. The stake is
    ///      returned as part of the payout only if the bet wins during settlement.
    /// @param _betType Kind of wager (see {BetType}).
    /// @param _number  Selection, interpreted per `_betType`.
    /// @param _amount  Stake in wei.
    function bet(BetType _betType, uint8 _number, uint256 _amount) external betLessLimit(_amount) {
        Player storage player = players[msg.sender];

        if (player.balance < _amount) {
            revert insufficientBalance(_amount, player.balance);
        }

        if (activeBetsCount >= MAX_BETS_PER_ROUND) {
            revert roundBetLimitReached();
        }
        activeBetsCount++;

        // Stake leaves the balance now; a winning bet is credited amount * multiplier
        // (stake included) during settlement, a losing bet is credited nothing.
        player.balance -= _amount;

        if (player.bets.length == 0) {
            activePlayers.push(msg.sender);
        }

        player.bets.push(Bet({amount: _amount, number: _number, betType: _betType}));

        emit PlayerBet(msg.sender, _betType, _number, _amount);
    }

    /// @notice Requests a random pocket from Chainlink VRF, spinning the wheel for the round.
    ///         Owner only.
    /// @dev Reverts with {requestAlreadyPending} if a prior request has not yet been fulfilled.
    ///      The resulting fulfillment settles all pending bets.
    function roll() external onlyOwner {
        if (s_requestStatus == RandomRequestStatus.Pending) {
            revert requestAlreadyPending();
        }

        _requestRandomWord();
    }

    /// @notice Cashes out the caller's entire balance to their address.
    /// @dev Follows checks-effects-interactions (balance zeroed before transfer) and uses a
    ///      low-level call, reverting with {withdrawFailed} if the recipient rejects the ETH.
    ///      Reverts with {balanceEqualZero} (via {balanceNotZero}) if there is nothing to withdraw.
    function withdraw() external balanceNotZero {
        uint256 amount = players[msg.sender].balance;
        players[msg.sender].balance = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert withdrawFailed();
        }

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Returns a player's bets pending settlement in the current round.
    /// @param player Address to query.
    /// @return The player's current-round bets.
    function getPlayerBets(address player) external view returns (Bet[] memory) {
        return players[player].bets;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice VRF callback: derives the winning pocket and settles all pending bets.
    /// @dev Invoked by the coordinator via `rawFulfillRandomWords`. Reverts with
    ///      {unexpectedRequestId} if the id does not match the outstanding request.
    /// @param _requestId   Id of the request being fulfilled.
    /// @param _randomWords Random words returned by the coordinator.
    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        if (_requestId != s_requestId) {
            revert unexpectedRequestId(s_requestId, _requestId);
        }

        s_randomWord = _randomWords[0];
        s_requestStatus = RandomRequestStatus.Fulfilled;

        s_roulleteNumber = uint8(s_randomWord % 38); // 37 = 00

        _processBets();

        emit RandomRequestFulfilled(_requestId, _randomWords);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Submits a randomness request to the VRF coordinator and marks it pending.
    function _requestRandomWord() private {
        s_requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: 3,
                callbackGasLimit: callbackGasLimit,
                numWords: WORDS_COUNT,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        );
        s_requestStatus = RandomRequestStatus.Pending;
        emit RandomRequestSent(s_requestId);
    }

    /// @notice Settles every active player's bets against {s_roulleteNumber}, crediting
    ///         winnings and clearing the round.
    /// @dev Bounded by {MAX_BETS_PER_ROUND} so it fits within {callbackGasLimit}.
    function _processBets() private {
        uint8 winningNumber = s_roulleteNumber;

        for (uint256 i = 0; i < activePlayers.length; i++) {
            address playerAddress = activePlayers[i];
            Player storage player = players[playerAddress];

            for (uint256 j = 0; j < player.bets.length; j++) {
                Bet memory playerBet = player.bets[j];
                uint256 payout = _calculatePayout(playerBet, winningNumber);

                if (payout > 0) {
                    player.balance += payout;
                }

                emit BetResolved(playerAddress, playerBet.betType, playerBet.number, playerBet.amount, payout);
            }

            delete player.bets;
        }

        delete activePlayers;
        activeBetsCount = 0;
    }

    /// @notice Computes the payout for a single bet against the winning pocket.
    /// @dev Payout includes the returned stake; a losing bet returns 0. Pockets 0 and 00 (37)
    ///      lose every bet except a straight Number bet on that exact pocket.
    /// @param playerBet     The bet to evaluate.
    /// @param winningNumber The winning pocket (0-37, where 37 = 00).
    /// @return The amount to credit the player (stake x multiplier on a win, 0 on a loss).
    function _calculatePayout(Bet memory playerBet, uint8 winningNumber) private pure returns (uint256) {
        if (playerBet.betType == BetType.Number) {
            return playerBet.number == winningNumber ? playerBet.amount * NUMBER_PAYOUT : 0;
        }

        // 0 and 00 (37) lose every bet other than a straight Number bet on 0 or 37.
        if (winningNumber == 0 || winningNumber == 37) {
            return 0;
        }

        if (playerBet.betType == BetType.Sector) {
            uint8 dozen = (winningNumber - 1) / 12; // 0 = 1-12, 1 = 13-24, 2 = 25-36
            return playerBet.number == dozen ? playerBet.amount * SECTOR_PAYOUT : 0;
        }

        if (playerBet.betType == BetType.Row) {
            uint8 row = (winningNumber - 1) / 3; // street of 3 consecutive numbers, 0-11
            return playerBet.number == row ? playerBet.amount * ROW_PAYOUT : 0;
        }

        // Color/OddEven/HighLow are all "does winningNumber's bit in this bet type's mask
        // match the side the player picked" -- number 0 = Red/Even/Low, 1 = Black/Odd/High.
        uint64 mask = _evenMoneyMask(playerBet.betType);
        bool outcome = (mask >> winningNumber) & 1 == 1;
        bool betOutcome = playerBet.number == 1;
        return outcome == betOutcome ? playerBet.amount * EVEN_MONEY_PAYOUT : 0;
    }

    /// @notice Returns the bitmask whose set bits mark the "1" side of an even-money bet.
    /// @param betType One of Color, OddEven, or HighLow.
    /// @return The corresponding winning-pocket mask (Black / Odd / High).
    function _evenMoneyMask(BetType betType) private pure returns (uint64) {
        if (betType == BetType.Color) {
            return BLACK_NUMBERS_MASK;
        }
        if (betType == BetType.OddEven) {
            return ODD_NUMBERS_MASK;
        }
        return HIGH_NUMBERS_MASK; // BetType.HighLow
    }
}
