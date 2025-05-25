// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.12;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeTransferLib, ERC20} from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


interface ILendTicket {
    /**
     * @notice Transfers a lend ticket
     * @dev can only be called by nft loan facilitator
     * @param from The current holder of the lend ticket
     * @param to Address to send the lend ticket to
     * @param loanId The lend ticket token id, which is also the loan id in the facilitator contract
     */
    function loanFacilitatorTransfer(address from, address to, uint256 loanId) external;
}
interface IERC721Mintable {
    /**
     * @notice mints an ERC721 token of tokenId to the to address
     * @dev only callable by nft loan facilitator
     * @param to The address to send the token to
     * @param tokenId The id of the token to mint
     */
    function mint(address to, uint256 tokenId) external;
}
interface INFTLoanFacilitator {
    /// @notice See loanInfo
    struct Loan {
        bool closed;
        uint16 perAnumInterestRate;
        uint32 durationSeconds;
        uint40 lastAccumulatedTimestamp;
        address collateralContractAddress;
        address loanAssetContractAddress;
        uint128 accumulatedInterest;
        uint128 loanAmount;
        uint256 collateralTokenId;
    }

    /**
     * @notice The magnitude of SCALAR
     * @dev 10^INTEREST_RATE_DECIMALS = 1 = 100%
     */
    function INTEREST_RATE_DECIMALS() external returns (uint8);

    /**
     * @notice The SCALAR for all percentages in the loan facilitator contract
     * @dev Any interest rate passed to a function should already been multiplied by SCALAR
     */
    function SCALAR() external returns (uint256);

    /**
     * @notice The percent of the loan amount that the facilitator will take as a fee, scaled by SCALAR
     * @dev Starts set to 1%. Can only be set to 0 - 5%. 
     */
    function originationFeeRate() external returns (uint256);

    /**
     * @notice The lend ticket contract associated with this loan faciliator
     * @dev Once set, cannot be modified
     */
    function lendTicketContract() external returns (address);

    /**
     * @notice The borrow ticket contract associated with this loan faciliator
     * @dev Once set, cannot be modified
     */
    function borrowTicketContract() external returns (address);

    /**
     * @notice The percent improvement required of at least one loan term when buying out current lender 
     * a loan that already has a lender, scaled by SCALAR. 
     * E.g. setting this value to 100 (10%) means, when replacing a lender, the new loan terms must have
     * at least 10% greater duration or loan amount or at least 10% lower interest rate. 
     * @dev Starts at 100 = 10%. Only owner can set. Cannot be set to 0.
     */
    function requiredImprovementRate() external returns (uint256);
    
    /**
     * @notice Emitted when the loan is created
     * @param id The id of the new loan, matches the token id of the borrow ticket minted in the same transaction
     * @param minter msg.sender
     * @param collateralTokenId The token id of the collateral NFT
     * @param collateralContract The contract address of the collateral NFT
     * @param maxInterestRate The max per anum interest rate, scaled by SCALAR
     * @param loanAssetContract The contract address of the loan asset
     * @param minLoanAmount mimimum loan amount
     * @param minDurationSeconds minimum loan duration in seconds
    */
    event CreateLoan(
        uint256 indexed id,
        address indexed minter,
        uint256 collateralTokenId,
        address collateralContract,
        uint256 maxInterestRate,
        address loanAssetContract,
        uint256 minLoanAmount,
        uint256 minDurationSeconds
        );

    /** 
     * @notice Emitted when ticket is closed
     * @param id The id of the ticket which has been closed
     */
    event Close(uint256 indexed id);

    /** 
     * @notice Emitted when the loan is underwritten or re-underwritten
     * @param id The id of the ticket which is being underwritten
     * @param lender msg.sender
     * @param interestRate The per anum interest rate, scaled by SCALAR, for the loan
     * @param loanAmount The loan amount
     * @param durationSeconds The loan duration in seconds 
     */
    event Lend(
        uint256 indexed id,
        address indexed lender,
        uint256 interestRate,
        uint256 loanAmount,
        uint256 durationSeconds
    );

    /**
     * @notice Emitted when a loan is being re-underwritten, the current loan ticket holder is being bought out
     * @param lender msg.sender
     * @param replacedLoanOwner The current loan ticket holder
     * @param interestEarned The amount of interest the loan has accrued from first lender to this buyout
     * @param replacedAmount The loan amount prior to buyout
     */    
    event BuyoutLender(
        uint256 indexed id,
        address indexed lender,
        address indexed replacedLoanOwner,
        uint256 interestEarned,
        uint256 replacedAmount
    );
    
    /**
     * @notice Emitted when loan is repaid
     * @param id The loan id
     * @param repayer msg.sender
     * @param loanOwner The current holder of the lend ticket for this loan, token id matching the loan id
     * @param interestEarned The total interest accumulated on the loan
     * @param loanAmount The loan amount
     */
    event Repay(
        uint256 indexed id,
        address indexed repayer,
        address indexed loanOwner,
        uint256 interestEarned,
        uint256 loanAmount
    );

    /**
     * @notice Emitted when loan NFT collateral is seized 
     * @param id The ticket id
     */
    event SeizeCollateral(uint256 indexed id);

     /**
      * @notice Emitted when origination fees are withdrawn
      * @dev only owner can call
      * @param asset the ERC20 asset withdrawn
      * @param amount the amount withdrawn
      * @param to the address the withdrawn amount was sent to
      */
     event WithdrawOriginationFees(address asset, uint256 amount, address to);

      /**
      * @notice Emitted when originationFeeRate is updated
      * @dev only owner can call, value is scaled by SCALAR, 100% = SCALAR
      * @param feeRate the new origination fee rate
      */
     event UpdateOriginationFeeRate(uint32 feeRate);

     /**
      * @notice Emitted when requiredImprovementRate is updated
      * @dev only owner can call, value is scaled by SCALAR, 100% = SCALAR
      * @param improvementRate the new required improvementRate
      */
     event UpdateRequiredImprovementRate(uint256 improvementRate);

    /**
     * @notice (1) transfers the collateral NFT to the loan facilitator contract 
     * (2) creates the loan, populating loanInfo in the facilitator contract,
     * and (3) mints a Borrow Ticket to mintBorrowTicketTo
     * @dev loan duration or loan amount cannot be 0, 
     * this is done to protect borrowers from accidentally passing a default value
     * and also because it creates odd lending and buyout behavior: possible to lend
     * for 0 value or 0 duration, and possible to buyout with no improvement because, for example
     * previousDurationSeconds + (previousDurationSeconds * requiredImprovementRate / SCALAR) <= durationSeconds
     * evaluates to true if previousDurationSeconds is 0 and durationSeconds is 0.
     * loanAssetContractAddress cannot be address(0), we check this because Solmate SafeTransferLib
     * does not revert with address(0) and this could cause odd behavior.
     * collateralContractAddress cannot be address(borrowTicket) or address(lendTicket).
     * @param collateralTokenId The token id of the collateral NFT 
     * @param collateralContractAddress The contract address of the collateral NFT
     * @param maxPerAnumInterest The maximum per anum interest rate for this loan, scaled by SCALAR
     * @param minLoanAmount The minimum acceptable loan amount for this loan
     * @param loanAssetContractAddress The address of the loan asset
     * @param minDurationSeconds The minimum duration for this loan
     * @param mintBorrowTicketTo An address to mint the Borrow Ticket corresponding to this loan to
     * @return id of the created loan
     */
    function createLoan(
            uint256 collateralTokenId,
            address collateralContractAddress,
            uint16 maxPerAnumInterest,
            uint128 minLoanAmount,
            address loanAssetContractAddress,
            uint32 minDurationSeconds,
            address mintBorrowTicketTo
    ) external returns (uint256 id);

    /**
     * @notice Closes the loan, sends the NFT collateral to sendCollateralTo
     * @dev Can only be called by the holder of the Borrow Ticket with tokenId
     * matching the loanId. Can only be called if loan has not be underwritten,
     * i.e. lastAccumulatedInterestTimestamp = 0
     * @param loanId The loan id
     * @param sendCollateralTo The address to send the collateral NFT to
     */
    function closeLoan(uint256 loanId, address sendCollateralTo) external;

    /**
     * @notice Lends, meeting or beating the proposed loan terms, 
     * transferring `amount` of the loan asset 
     * to the facilitator contract. If the loan has not yet been underwritten, 
     * a Lend Ticket is minted to `sendLendTicketTo`. If the loan has already been 
     * underwritten, then this is a buyout, and the Lend Ticket will be transferred
     * from the current holder to `sendLendTicketTo`. Also in the case of a buyout, interestOwed()
     * is transferred from the caller to the facilitator contract, in addition to `amount`, and
     * totalOwed() is paid to the current Lend Ticket holder.
     * @dev Loan terms must meet or beat loan terms. If a buyout, at least one loan term
     * must be improved by at least 10%. E.g. 10% longer duration, 10% lower interest, 
     * 10% higher amount
     * @param loanId The loan id
     * @param interestRate The per anum interest rate, scaled by SCALAR
     * @param amount The loan amount
     * @param durationSeconds The loan duration in seconds
     * @param sendLendTicketTo The address to send the Lend Ticket to
     */
    function lend(
            uint256 loanId,
            uint16 interestRate,
            uint128 amount,
            uint32 durationSeconds,
            address sendLendTicketTo
    ) external;

    /**
     * @notice repays and closes the loan, transferring totalOwed() to the current Lend Ticket holder
     * and transferring the collateral NFT to the Borrow Ticket holder.
     * @param loanId The loan id
     */
    function repayAndCloseLoan(uint256 loanId) external;

    /**
     * @notice Transfers the collateral NFT to `sendCollateralTo` and closes the loan.
     * @dev Can only be called by Lend Ticket holder. Can only be called 
     * if block.timestamp > loanEndSeconds()
     * @param loanId The loan id
     * @param sendCollateralTo The address to send the collateral NFT to
     */
    function seizeCollateral(uint256 loanId, address sendCollateralTo) external;

    /**
     * @notice returns the info for this loan
     * @param loanId The id of the loan
     * @return closed Whether or not the ticket is closed
     * @return perAnumInterestRate The per anum interest rate, scaled by SCALAR
     * @return durationSeconds The loan duration in seconds
     
     * @return lastAccumulatedTimestamp The timestamp (in seconds) when interest was last accumulated, 
     * i.e. the timestamp of the most recent underwriting
     * @return collateralContractAddress The contract address of the NFT collateral 
     * @return loanAssetContractAddress The contract address of the loan asset.
     * @return accumulatedInterest The amount of interest accumulated on the loan prior to the current lender
     * @return loanAmount The loan amount
     * @return collateralTokenId The token ID of the NFT collateral
     */
    function loanInfo(uint256 loanId)
        external 
        view 
        returns (
            bool closed,
            uint16 perAnumInterestRate,
            uint32 durationSeconds,
            uint40 lastAccumulatedTimestamp,
            address collateralContractAddress,
            address loanAssetContractAddress,
            uint128 accumulatedInterest,
            uint128 loanAmount,
            uint256 collateralTokenId
        );

    /**
     * @notice returns the info for this loan
     * @dev this is a convenience method for other contracts that would prefer to have the 
     * Loan object not decomposed. 
     * @param loanId The id of the loan
     * @return Loan struct corresponding to loanId
     */
    function loanInfoStruct(uint256 loanId) external view returns (Loan memory);

    /**
     * @notice returns the total amount owed for the loan, i.e. principal + interest
     * @param loanId The loan id
     */
    function totalOwed(uint256 loanId) view external returns (uint256);

    /**
     * @notice returns the interest owed on the loan, in loan asset units
     * @param loanId The loan id
     */
    function interestOwed(uint256 loanId) view external returns (uint256);

    /**
     * @notice returns the unix timestamp (seconds) of the loan end
     * @param loanId The loan id
     */
    function loanEndSeconds(uint256 loanId) view external returns (uint256);
}
contract NFTLoanFacilitator is Ownable, INFTLoanFacilitator {
    using SafeTransferLib for ERC20;

    // ==== constants ====

    /** 
     * See {INFTLoanFacilitator-INTEREST_RATE_DECIMALS}.     
     * @dev lowest non-zero APR possible = (1/10^3) = 0.001 = 0.1%
     */
    uint8 public constant override INTEREST_RATE_DECIMALS = 3;

    /// See {INFTLoanFacilitator-SCALAR}.
    uint256 public constant override SCALAR = 10 ** INTEREST_RATE_DECIMALS;

    
    // ==== state variables ====

    /// See {INFTLoanFacilitator-originationFeeRate}.
    /// @dev starts at 1%
    uint256 public override originationFeeRate = 10 ** (INTEREST_RATE_DECIMALS - 2);

    /// See {INFTLoanFacilitator-requiredImprovementRate}.
    /// @dev starts at 10%
    uint256 public override requiredImprovementRate = 10 ** (INTEREST_RATE_DECIMALS - 1);

    /// See {INFTLoanFacilitator-lendTicketContract}.
    address public override lendTicketContract;

    /// See {INFTLoanFacilitator-borrowTicketContract}.
    address public override borrowTicketContract;

    /// See {INFTLoanFacilitator-loanInfo}.
    mapping(uint256 => Loan) public loanInfo;

    /// @dev tracks loan count
    uint256 private _nonce = 1;

    
    // ==== modifiers ====

    modifier notClosed(uint256 loanId) { 
        require(!loanInfo[loanId].closed, "NFTLoanFacilitator: loan closed");
        _; 
    }


    // ==== constructor ====

    constructor(address _manager) {
        transferOwnership(_manager);
    }

    
    // ==== state changing external functions ====

    /// See {INFTLoanFacilitator-createLoan}.
    function createLoan(
        uint256 collateralTokenId,
        address collateralContractAddress,
        uint16 maxPerAnumInterest,
        uint128 minLoanAmount,
        address loanAssetContractAddress,
        uint32 minDurationSeconds,
        address mintBorrowTicketTo
    )
        external
        override
        returns (uint256 id) 
    {
        require(minDurationSeconds != 0, 'NFTLoanFacilitator: 0 duration');
        require(minLoanAmount != 0, 'NFTLoanFacilitator: 0 loan amount');
        require(collateralContractAddress != lendTicketContract,
        'NFTLoanFacilitator: cannot use tickets as collateral');
        require(collateralContractAddress != borrowTicketContract, 
        'NFTLoanFacilitator: cannot use tickets as collateral');
        
        IERC721(collateralContractAddress).transferFrom(msg.sender, address(this), collateralTokenId);

        unchecked {
            id = _nonce++;
        }

        Loan storage loan = loanInfo[id];
        loan.loanAssetContractAddress = loanAssetContractAddress;
        loan.loanAmount = minLoanAmount;
        loan.collateralTokenId = collateralTokenId;
        loan.collateralContractAddress = collateralContractAddress;
        loan.perAnumInterestRate = maxPerAnumInterest;
        loan.durationSeconds = minDurationSeconds;
        
        IERC721Mintable(borrowTicketContract).mint(mintBorrowTicketTo, id);
        emit CreateLoan(
            id,
            msg.sender,
            collateralTokenId,
            collateralContractAddress,
            maxPerAnumInterest,
            loanAssetContractAddress,
            minLoanAmount,
            minDurationSeconds
        );
    }

    /// See {INFTLoanFacilitator-closeLoan}.
    function closeLoan(uint256 loanId, address sendCollateralTo) external override notClosed(loanId) {
        require(IERC721(borrowTicketContract).ownerOf(loanId) == msg.sender,
        "NFTLoanFacilitator: borrow ticket holder only");

        Loan storage loan = loanInfo[loanId];
        require(loan.lastAccumulatedTimestamp == 0, "NFTLoanFacilitator: has lender, use repayAndCloseLoan");
        
        loan.closed = true;
        IERC721(loan.collateralContractAddress).transferFrom(address(this), sendCollateralTo, loan.collateralTokenId);
        emit Close(loanId);
    }

    /// See {INFTLoanFacilitator-lend}.
    function lend(
        uint256 loanId,
        uint16 interestRate,
        uint128 amount,
        uint32 durationSeconds,
        address sendLendTicketTo
    )
        external
        override
        notClosed(loanId)
    {
        Loan storage loan = loanInfo[loanId];
        
        if (loan.lastAccumulatedTimestamp == 0) {
            address loanAssetContractAddress = loan.loanAssetContractAddress;
            require(loanAssetContractAddress != address(0), "NFTLoanFacilitator: invalid loan");

            require(interestRate <= loan.perAnumInterestRate, 'NFTLoanFacilitator: rate too high');
            require(durationSeconds >= loan.durationSeconds, 'NFTLoanFacilitator: duration too low');
            require(amount >= loan.loanAmount, 'NFTLoanFacilitator: amount too low');
        
            loan.perAnumInterestRate = interestRate;
            loan.lastAccumulatedTimestamp = uint40(block.timestamp);
            loan.durationSeconds = durationSeconds;
            loan.loanAmount = amount;

            ERC20(loanAssetContractAddress).safeTransferFrom(msg.sender, address(this), amount);
            uint256 facilitatorTake = amount * originationFeeRate / SCALAR;
            ERC20(loanAssetContractAddress).safeTransfer(
                IERC721(borrowTicketContract).ownerOf(loanId),
                amount - facilitatorTake
            );
            IERC721Mintable(lendTicketContract).mint(sendLendTicketTo, loanId);
        } else {
            uint256 previousLoanAmount = loan.loanAmount;
            // will underflow if amount < previousAmount
            uint256 amountIncrease = amount - previousLoanAmount;

            {
                uint256 previousInterestRate = loan.perAnumInterestRate;
                uint256 previousDurationSeconds = loan.durationSeconds;

                require(interestRate <= previousInterestRate, 'NFTLoanFacilitator: rate too high');
                require(durationSeconds >= previousDurationSeconds, 'NFTLoanFacilitator: duration too low');

                require((previousLoanAmount * requiredImprovementRate / SCALAR) <= amountIncrease
                || previousDurationSeconds + (previousDurationSeconds * requiredImprovementRate / SCALAR) <= durationSeconds 
                || (previousInterestRate != 0 // do not allow rate improvement if rate already 0
                    && previousInterestRate - (previousInterestRate * requiredImprovementRate / SCALAR) >= interestRate), 
                "NFTLoanFacilitator: proposed terms must be better than existing terms");
            }

            uint256 accumulatedInterest = _interestOwed(
                previousLoanAmount,
                loan.lastAccumulatedTimestamp,
                loan.perAnumInterestRate,
                loan.accumulatedInterest
            );

            require(accumulatedInterest <= type(uint128).max,
            "NFTLoanFacilitator: accumulated interest exceeds uint128");

            loan.perAnumInterestRate = interestRate;
            loan.lastAccumulatedTimestamp = uint40(block.timestamp);
            loan.durationSeconds = durationSeconds;
            loan.loanAmount = amount;
            loan.accumulatedInterest = uint128(accumulatedInterest);

            address currentLoanOwner = IERC721(lendTicketContract).ownerOf(loanId);
            if (amountIncrease > 0) {
                address loanAssetContractAddress = loan.loanAssetContractAddress;
                ERC20(loanAssetContractAddress).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amount + accumulatedInterest
                );
                ERC20(loanAssetContractAddress).safeTransfer(
                    currentLoanOwner,
                    accumulatedInterest + previousLoanAmount
                );
                uint256 facilitatorTake = (amountIncrease * originationFeeRate / SCALAR);
                ERC20(loanAssetContractAddress).safeTransfer(
                    IERC721(borrowTicketContract).ownerOf(loanId),
                    amountIncrease - facilitatorTake
                );
            } else {
                ERC20(loan.loanAssetContractAddress).safeTransferFrom(
                    msg.sender,
                    currentLoanOwner,
                    accumulatedInterest + previousLoanAmount
                );
            }
            ILendTicket(lendTicketContract).loanFacilitatorTransfer(currentLoanOwner, sendLendTicketTo, loanId);
            
            emit BuyoutLender(loanId, msg.sender, currentLoanOwner, accumulatedInterest, previousLoanAmount);
        }

        emit Lend(loanId, msg.sender, interestRate, amount, durationSeconds);
    }

    /// See {INFTLoanFacilitator-repayAndCloseLoan}.
    function repayAndCloseLoan(uint256 loanId) external override notClosed(loanId) {
        Loan storage loan = loanInfo[loanId];

        uint256 interest = _interestOwed(
            loan.loanAmount,
            loan.lastAccumulatedTimestamp,
            loan.perAnumInterestRate,
            loan.accumulatedInterest
        );
        address lender = IERC721(lendTicketContract).ownerOf(loanId);
        loan.closed = true;
        ERC20(loan.loanAssetContractAddress).safeTransferFrom(msg.sender, lender, interest + loan.loanAmount);
        IERC721(loan.collateralContractAddress).safeTransferFrom(
            address(this),
            IERC721(borrowTicketContract).ownerOf(loanId),
            loan.collateralTokenId
        );

        emit Repay(loanId, msg.sender, lender, interest, loan.loanAmount);
        emit Close(loanId);
    }

    /// See {INFTLoanFacilitator-seizeCollateral}.
    function seizeCollateral(uint256 loanId, address sendCollateralTo) external override notClosed(loanId) {
        require(IERC721(lendTicketContract).ownerOf(loanId) == msg.sender, 
        "NFTLoanFacilitator: lend ticket holder only");

        Loan storage loan = loanInfo[loanId];
        require(block.timestamp > loan.durationSeconds + loan.lastAccumulatedTimestamp,
        "NFTLoanFacilitator: payment is not late");

        loan.closed = true;
        IERC721(loan.collateralContractAddress).safeTransferFrom(
            address(this),
            sendCollateralTo,
            loan.collateralTokenId
        );

        emit SeizeCollateral(loanId);
        emit Close(loanId);
    }

    
    // === owner state changing ===

    /**
     * @notice Sets lendTicketContract to _contract
     * @dev cannot be set if lendTicketContract is already set
     */
    function setLendTicketContract(address _contract) external onlyOwner {
        require(lendTicketContract == address(0), 'NFTLoanFacilitator: already set');

        lendTicketContract = _contract;
    }

    /**
     * @notice Sets borrowTicketContract to _contract
     * @dev cannot be set if borrowTicketContract is already set
     */
    function setBorrowTicketContract(address _contract) external onlyOwner {
        require(borrowTicketContract == address(0), 'NFTLoanFacilitator: already set');

        borrowTicketContract = _contract;
    }

    /// @notice Transfers `amount` of loan origination fees for `asset` to `to`
    function withdrawOriginationFees(address asset, uint256 amount, address to) external onlyOwner {
        ERC20(asset).safeTransfer(to, amount);

        emit WithdrawOriginationFees(asset, amount, to);
    }

    /**
     * @notice Updates originationFeeRate the faciliator keeps of each loan amount
     * @dev Cannot be set higher than 5%
     */
    function updateOriginationFeeRate(uint32 _originationFeeRate) external onlyOwner {
        require(_originationFeeRate <= 5 * (10 ** (INTEREST_RATE_DECIMALS - 2)), "NFTLoanFacilitator: max fee 5%");
        
        originationFeeRate = _originationFeeRate;

        emit UpdateOriginationFeeRate(_originationFeeRate);
    }

    /**
     * @notice updates the percent improvement required of at least one loan term when buying out lender 
     * a loan that already has a lender. E.g. setting this value to 10 means duration or amount
     * must be 10% higher or interest rate must be 10% lower. 
     * @dev Cannot be 0.
     */
    function updateRequiredImprovementRate(uint256 _improvementRate) external onlyOwner {
        require(_improvementRate > 0, 'NFTLoanFacilitator: 0 improvement rate');

        requiredImprovementRate = _improvementRate;

        emit UpdateRequiredImprovementRate(_improvementRate);
    }

    
    // ==== external view ====

    /// See {INFTLoanFacilitator-loanInfoStruct}.
    function loanInfoStruct(uint256 loanId) external view override returns (Loan memory) {
        return loanInfo[loanId];
    }

    /// See {INFTLoanFacilitator-totalOwed}.
    function totalOwed(uint256 loanId) external view override returns (uint256) {
        Loan storage loan = loanInfo[loanId];
        if (loan.closed || loan.lastAccumulatedTimestamp == 0) return 0;

        return loanInfo[loanId].loanAmount + _interestOwed(
            loan.loanAmount,
            loan.lastAccumulatedTimestamp,
            loan.perAnumInterestRate,
            loan.accumulatedInterest
        );
    }

    /// See {INFTLoanFacilitator-interestOwed}.
    function interestOwed(uint256 loanId) external view override returns (uint256) {
        Loan storage loan = loanInfo[loanId];
        if(loan.closed || loan.lastAccumulatedTimestamp == 0) return 0;

        return _interestOwed(
            loan.loanAmount,
            loan.lastAccumulatedTimestamp,
            loan.perAnumInterestRate,
            loan.accumulatedInterest
        );
    }

    /// See {INFTLoanFacilitator-loanEndSeconds}.
    function loanEndSeconds(uint256 loanId) external view override returns (uint256) {
        Loan storage loan = loanInfo[loanId];
        return loan.durationSeconds + loan.lastAccumulatedTimestamp;
    }

    
    // === private ===

    /// @dev Returns the total interest owed on loan
    function _interestOwed(
        uint256 loanAmount,
        uint256 lastAccumulatedTimestamp,
        uint256 perAnumInterestRate,
        uint256 accumulatedInterest
    ) 
        internal 
        view 
        returns (uint256) 
    {
        return loanAmount
            * (block.timestamp - lastAccumulatedTimestamp)
            * (perAnumInterestRate * 1e18 / 365 days)
            / 1e21 // SCALAR * 1e18
            + accumulatedInterest;
    }
}
