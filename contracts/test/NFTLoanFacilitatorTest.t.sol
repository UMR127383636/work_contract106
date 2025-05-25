// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.12;

import {DSTest} from "./helpers/test.sol";
import {Vm}     from "./helpers/Vm.sol";

import {NFTLoanFacilitator}        from "contracts/NFTLoanFacilitator.sol";
import {NFTLoanFacilitatorFactory} from "./helpers/NFTLoanFacilitatorFactory.sol";
import {BorrowTicket} from "contracts/BorrowTicket.sol";
import {LendTicket}   from "contracts/LendTicket.sol";
import {CryptoPunks}  from "./mocks/CryptoPunks.sol";
import {DAI}          from "./mocks/DAI.sol";

/*───────────────────────────────────────────────────────────*\
|*                     FUZZ-ONLY  TESTS                      *|
\*───────────────────────────────────────────────────────────*/
contract NFTLoanFacilitatorFuzzTest is DSTest {
    Vm vm = Vm(HEVM_ADDRESS);

    NFTLoanFacilitator facilitator;
    BorrowTicket       borrowTicket;
    LendTicket         lendTicket;

    CryptoPunks punks = new CryptoPunks();
    DAI         dai   = new DAI();

    address borrower = address(1);
    address lender   = address(2);

    uint16  interestRate  = 15;
    uint128 loanAmount    = 1e20;
    uint32  loanDuration  = 1000;
    uint256 startTimestamp = 5;

    uint256 punkId;

    /*─────────────────── set-up ───────────────────*/
    function setUp() public {
        NFTLoanFacilitatorFactory f = new NFTLoanFacilitatorFactory();
        (borrowTicket, lendTicket, facilitator) = f.newFacilitator(address(this));

        vm.warp(startTimestamp);

        vm.startPrank(borrower);
        punkId = punks.mint();
        punks.approve(address(facilitator), punkId);
        vm.stopPrank();
    }

    /*────────────────── FUZZ TESTS ──────────────────*/

    function testCreateLoanSetsValuesCorrectly(
        uint16  maxRate,
        uint128 minAmount,
        uint32  minDuration,
        address mintTo
    ) public {
        vm.assume(minAmount   > 0);
        vm.assume(minDuration > 0);
        vm.assume(mintTo      != address(0));

        vm.prank(borrower);
        uint256 id = facilitator.createLoan(
            punkId,
            address(punks),
            maxRate,
            minAmount,
            address(dai),
            minDuration,
            mintTo
        );

        (
            bool   closed,
            uint16 storedRate,
            uint32 storedDur,
            uint40 ts,
            ,
            ,
            uint128 accInt,
            uint128 storedAmt,

        ) = facilitator.loanInfo(id);

        assertTrue(!closed);
        assertEq(storedRate, maxRate);
        assertEq(storedDur,  minDuration);
        assertEq(storedAmt,  minAmount);
        assertEq(ts,         0);
        assertEq(accInt,     0);
    }

    function testLendUpdatesValuesCorrectly(
        uint16  rate,
        uint128 amount,
        uint32  duration,
        address sendTo
    ) public {
        vm.assume(rate     <= interestRate);
        vm.assume(amount   >= loanAmount);
        vm.assume(duration >= loanDuration);
        vm.assume(sendTo   != address(0));
        vm.assume(amount   <  type(uint256).max / 10);

        (, uint256 id) = _setUpLoan(borrower);

        dai.mint(amount, address(this));
        dai.approve(address(facilitator), amount);

        facilitator.lend(id, rate, amount, duration, sendTo);

        (
            ,
            uint16 storedRate,
            uint32 storedDur,
            uint40 ts,
            ,
            ,
            uint128 accInt,
            uint128 storedAmt,

        ) = facilitator.loanInfo(id);

        assertEq(storedRate, rate);
        assertEq(storedDur,  duration);
        assertEq(storedAmt,  amount);
        assertEq(ts,         startTimestamp);
        assertEq(accInt,     0);
    }

    function testLendFailsIfHigherInterestRate(
        uint16 rate,
        uint32 duration,
        uint128 amount
    ) public {
        vm.assume(rate > interestRate);
        vm.assume(duration >= loanDuration);
        vm.assume(amount   >= loanAmount);

        (, uint256 id) = _setUpLoan(borrower);
        _setUpLender(lender);

        vm.startPrank(lender);
        vm.expectRevert("NFTLoanFacilitator: rate too high");
        facilitator.lend(id, rate, amount, duration, lender);
    }

    function testLendFailsIfLowerAmount(
        uint16 rate,
        uint32 duration,
        uint128 amount
    ) public {
        vm.assume(rate <= interestRate);
        vm.assume(duration >= loanDuration);
        vm.assume(amount <  loanAmount);

        (, uint256 id) = _setUpLoan(borrower);
        _setUpLender(lender);

        vm.startPrank(lender);
        vm.expectRevert("NFTLoanFacilitator: amount too low");
        facilitator.lend(id, rate, amount, duration, lender);
    }

    function testLendFailsIfLowerDuration(
        uint16 rate,
        uint32 duration,
        uint128 amount
    ) public {
        vm.assume(rate <= interestRate);
        vm.assume(duration <  loanDuration);
        vm.assume(amount   >= loanAmount);

        (, uint256 id) = _setUpLoan(borrower);
        _setUpLender(lender);

        vm.startPrank(lender);
        vm.expectRevert("NFTLoanFacilitator: duration too low");
        facilitator.lend(id, rate, amount, duration, lender);
    }

    /*────────────── Buy-out success paths ─────────────*/

    function testBuyoutSucceedsIfRateImproved(uint16 rate) public {
        vm.assume(rate <= _decreaseMin(interestRate));

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        address newLender = address(3);
        _setUpLender(newLender);

        vm.prank(newLender);
        facilitator.lend(id, rate, loanAmount, loanDuration, newLender);
    }

    function testBuyoutSucceedsIfAmountImproved(uint128 amount) public {
        vm.assume(amount >= _increaseMin(loanAmount));
        vm.assume(amount <  type(uint256).max / 10);

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        address newLender = address(3);
        _setUpLender(newLender);
        dai.mint(amount - loanAmount, newLender);

        vm.prank(newLender);
        facilitator.lend(id, interestRate, amount, loanDuration, newLender);
    }

    function testBuyoutSucceedsIfDurationImproved(uint32 duration) public {
        vm.assume(duration >= _increaseMin(loanDuration));

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        address newLender = address(3);
        _setUpLender(newLender);

        vm.prank(newLender);
        facilitator.lend(id, interestRate, loanAmount, duration, newLender);
    }

    /*────────────── Buy-out pay-out checks ─────────────*/

    function testBuyoutPaysPreviousLenderCorrectly(uint128 amount) public {
        vm.assume(amount >= loanAmount);
        vm.assume(amount <  type(uint256).max / 10);

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        vm.warp(startTimestamp + 100);
        uint256 interest = facilitator.interestOwed(id);

        dai.mint(amount + interest, address(this));
        dai.approve(address(facilitator), amount + interest);

        uint256 before = dai.balanceOf(lender);

        facilitator.lend(
            id,
            interestRate,
            amount,
            uint32(_increaseMin(loanDuration)),
            address(1)
        );

        assertEq(before + loanAmount + interest, dai.balanceOf(lender));
    }

    function testBuyoutPaysBorrowerCorrectly(uint128 amount) public {
        vm.assume(amount >= loanAmount);
        vm.assume(amount <  type(uint256).max / 10);

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        dai.mint(amount, address(this));
        dai.approve(address(facilitator), amount);

        uint256 before = dai.balanceOf(borrower);

        facilitator.lend(
            id,
            interestRate,
            amount,
            uint32(_increaseMin(loanDuration)),
            address(1)
        );

        uint256 inc = amount - loanAmount;
        uint256 fee = inc * facilitator.originationFeeRate() / facilitator.SCALAR();

        assertEq(before + (inc - fee), dai.balanceOf(borrower));
    }

    function testBuyoutPaysFacilitatorCorrectly(uint128 amount) public {
        vm.assume(amount >= loanAmount);
        vm.assume(amount <  type(uint256).max / 10);

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        address newLender = address(3);
        dai.mint(amount, newLender);
        vm.startPrank(newLender);
        dai.approve(address(facilitator), amount);

        uint256 before = dai.balanceOf(address(facilitator));

        facilitator.lend(
            id,
            interestRate,
            amount,
            uint32(_increaseMin(loanDuration)),
            address(1)
        );

        uint256 inc = amount - loanAmount;
        uint256 fee = inc * facilitator.originationFeeRate() / facilitator.SCALAR();
        assertEq(before + fee, dai.balanceOf(address(facilitator)));
    }

    /*────────────── Buy-out failure paths ─────────────*/

    function testBuyoutFailsIfLoanAmountRegressed(
        uint16 newRate,
        uint32 newDuration,
        uint128 newAmount
    ) public {
        vm.assume(newRate     <= interestRate);
        vm.assume(newDuration >= loanDuration);
        vm.assume(newAmount   <  loanAmount);

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        address newLender = address(3);
        _setUpLender(newLender);

        vm.startPrank(newLender);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        facilitator.lend(id, newRate, uint128(newAmount), newDuration, newLender);
    }

    function testBuyoutFailsIfInterestRateRegressed(
        uint16 newRate,
        uint32 newDuration,
        uint128 newAmount
    ) public {
        vm.assume(newRate     >  interestRate);
        vm.assume(newDuration >= loanDuration);
        vm.assume(newAmount   >= loanAmount);

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        address newLender = address(3);
        _setUpLender(newLender);

        vm.startPrank(newLender);
        vm.expectRevert("NFTLoanFacilitator: rate too high");
        facilitator.lend(id, newRate, uint128(newAmount), newDuration, newLender);
    }

    function testBuyoutFailsIfDurationRegressed(
        uint16 newRate,
        uint32 newDuration,
        uint128 newAmount
    ) public {
        vm.assume(newRate     <= interestRate);
        vm.assume(newDuration <  loanDuration);
        vm.assume(newAmount   >= loanAmount);

        (, uint256 id) = _setUpLoanWithLender(borrower, lender);

        address newLender = address(3);
        _setUpLender(newLender);

        vm.startPrank(newLender);
        vm.expectRevert("NFTLoanFacilitator: duration too low");
        facilitator.lend(id, newRate, uint128(newAmount), newDuration, newLender);
    }

    /*────────────────── helpers ──────────────────*/

    function _setUpLender(address who) internal {
        vm.startPrank(who);
        dai.mint(loanAmount, who);
        dai.approve(address(facilitator), type(uint256).max);
        vm.stopPrank();
    }

    function _setUpLoan(address who) internal returns (uint256 tokenId, uint256 loanId) {
        vm.startPrank(who);
        tokenId = punks.mint();
        punks.approve(address(facilitator), tokenId);
        loanId = facilitator.createLoan(
            tokenId,
            address(punks),
            interestRate,
            loanAmount,
            address(dai),
            loanDuration,
            who
        );
        vm.stopPrank();
    }

    function _setUpLoanWithLender(address b, address l)
        internal
        returns (uint256 tokenId, uint256 loanId)
    {
        (tokenId, loanId) = _setUpLoan(b);
        _setUpLender(l);
        vm.startPrank(l);
        facilitator.lend(loanId, interestRate, loanAmount, loanDuration, l);
        vm.stopPrank();
    }

    function _increaseMin(uint256 x) internal view returns (uint256) {
        return x + (x * facilitator.requiredImprovementRate()) / facilitator.SCALAR();
    }

    function _decreaseMin(uint256 x) internal view returns (uint256) {
        return x - (x * facilitator.requiredImprovementRate()) / facilitator.SCALAR();
    }
}
